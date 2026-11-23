import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import pty
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

from verification_inputs import artifact_digest, source_digest


@dataclass
class Check:
    id: str
    argv: tuple
    timeout: float = 300
    silence: float = 120
    lane: str = ""
    needs: tuple = ()
    screen: bool = False
    cache: bool = True
    artifact: Path | None = None
    commands: tuple = ()
    any_env: tuple = ()
    paths: tuple = ()
    dirs: tuple = ()
    login: str = ""


ENV_ALLOWLIST = frozenset({
    "NODE",
    "TOOLCHAINS",
    "DEVELOPER_DIR",
    "KEYSCRIBE_APP",
    "KEYSCRIBE_APP_OUTPUT",
    "KEYSCRIBE_VARIANT",
    "KEYSCRIBE_SIGN_ID",
    "CODESIGN_IDENTITY",
    "KEYSCRIBE_DEV_SIGN_IDENTITY",
    "CLAUDE_BIN",
    "PI_BIN",
    "OMP_BIN",
    "CODEX_BIN",
    "BB_APP",
})


HARNESS_FILTERS = frozenset({"ONLY", "TARGETS", "REPEAT", "FAIL_FAST", "AGENT"})


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def environment_digest(env):
    stable = {
        key: value
        for key, value in env.items()
        if key in ENV_ALLOWLIST or key.startswith("ULTIMATE_")
    }
    return hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest()


def load_connector_checks(root):
    table = Path(root) / "scripts/connector_checks.tsv"
    if not table.is_file():
        table = Path(__file__).resolve().parent / "connector_checks.tsv"
    checks = []
    for raw in table.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        verify_id, preflight_id, label, command, timeout, skip_on_exit2 = line.split("\t")
        parts = shlex.split(command)
        if parts and parts[0] == "python3":
            parts[0] = sys.executable
        checks.append({
            "id": verify_id,
            "preflight_id": preflight_id,
            "label": label,
            "argv": tuple(parts),
            "timeout": float(timeout),
            "skip_on_exit2": skip_on_exit2 == "1",
        })
    return checks


LIVE_PREREQUISITES = {
    "pi": {"commands": (("pi", "PI_BIN"),), "paths": (("Pi login folder", "PI_LOGIN_HOME", "~/.pi/agent", ""),)},
    "bb": {"paths": (("bb.app", "BB_APP", "/Applications/bb.app", ""),)},
    "ultimate": {"commands": (("ultimate", "ULTIMATE_BIN"),)},
    "claude": {"login": "claude", "commands": (("claude", "CLAUDE_BIN"),)},
    "omp": {"commands": (("omp", "OMP_BIN"),), "paths": (("omp login folder", "OMP_LOGIN_HOME", "~/.omp/agent", ""),)},
    "codex": {"login": "codex", "commands": (("codex", "CODEX_BIN"),)},
}


def verification_plan(root, env, profile):
    make = shutil.which("make", path=env.get("PATH")) or "make"
    node = env.get("NODE") or shutil.which("node", path=env.get("PATH")) or "node"
    ultimate_node = env.get("ULTIMATE_NODE") or node
    connector_checks = [Check(item["id"], item["argv"], timeout=item["timeout"]) for item in load_connector_checks(root)]
    tools = [check for check in connector_checks if check.id == "tools"]
    plan = [*tools, Check("swift", (make, "test"), lane="swift"), *(check for check in connector_checks if check.id != "tools")]
    if profile == "full":
        app = root / ".verification/artifacts/KeyScribeDev.app"
        plan.append(Check("build", ("./make-app.sh",), timeout=720, silence=180, lane="swift", artifact=app,
                          needs=tuple(check.id for check in plan)))
        for agent, reqs in LIVE_PREREQUISITES.items():
            plan.append(Check(f"live-{agent}", (ultimate_node if agent == "ultimate" else node, "Tests/AgentConformance/run.ts", "--agent", agent),
                              timeout=1200, silence=240, lane="screen", needs=("build",), screen=True, cache=False, **reqs))
        plan.extend([
            Check("ultimate-live", (ultimate_node, "Tests/UltimateConnector/e2e/live.ts"),
                  timeout=600, silence=180, lane="screen", needs=("build",), cache=False,
                  dirs=(("ULTIMATE_CLONE", "an installed Ultimate checkout"),)),
            Check("ultimate-page", (ultimate_node, "Tests/AgentConformance/ultimate-page.ts"),
                  timeout=1800, silence=240, lane="screen", needs=("build",), screen=True, cache=False,
                  dirs=(("ULTIMATE_CLONE", "an installed Ultimate checkout"),),
                  commands=(("ultimate", "ULTIMATE_BIN"),)),
        ])
    return plan


def select_checks(plan, requested):
    by_id = {check.id: check for check in plan}
    selected = set(requested or by_id)
    unknown = selected - by_id.keys()
    if unknown:
        raise ValueError(f"unknown checks: {', '.join(sorted(unknown))}")
    pending = list(selected)
    while pending:
        for dependency in by_id[pending.pop()].needs:
            if dependency not in selected:
                selected.add(dependency)
                pending.append(dependency)
    return [check for check in plan if check.id in selected]


def process_snapshot(folder):
    try:
        answer = subprocess.run(["ps", "-axo", "pid,ppid,pgid,etime,%cpu,stat,comm"], capture_output=True, timeout=5)
        (folder / "processes.txt").write_bytes(answer.stdout + answer.stderr)
    except (OSError, subprocess.TimeoutExpired) as error:
        (folder / "processes.txt").write_text(str(error))


WRAPPER_PROCS = {"make", "sh", "bash", "zsh", "timeout", "env"}
FRAME_FILTER = re.compile(
    r"(KeyScribe|Testing\.|XCTest|swiftpm|Ultimate|AgentHub|AgentTake|Dictation|node|claude|codex|herdr|\bbb\b)"
)
SWIFT_STARTED = re.compile(r"◇ Test (.+?) started\.")
SWIFT_ENDED = re.compile(r"[✔✘] Test (.+?) (?:passed|failed)")
SWIFT_DURATION = re.compile(r"[✔✘] (?:Test|Suite) .+? after ([0-9]+\.[0-9]+) seconds")
SWIFT_COMPILE_ERROR = re.compile(r"^.+?:\d+:\d+: error: ")
MIN_NODE_VERSION = (22, 18, 0)


def sample_targets(pgid, root_pid, ps_output=None):
    if ps_output is None:
        try:
            answer = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,comm="], capture_output=True, text=True, timeout=5)
            ps_output = answer.stdout
        except (OSError, subprocess.TimeoutExpired):
            return [root_pid]
    members = []
    for line in ps_output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        try:
            pid, ppid, group = int(fields[0]), int(fields[1]), int(fields[2])
        except ValueError:
            continue
        if group == pgid:
            members.append((pid, ppid, Path(fields[3]).name))
    if not members:
        return [root_pid]
    parents = {ppid for _, ppid, _ in members}
    leaves = [item for item in members if item[0] not in parents] or members
    useful = [item for item in leaves if item[2] not in WRAPPER_PROCS] or leaves
    return [pid for pid, _, _ in sorted(useful, key=lambda item: item[0], reverse=True)[:2]]


def extract_sample_frames(sample_text):
    kept = []
    for line in sample_text.splitlines():
        if FRAME_FILTER.search(line) and (not kept or kept[-1] != line):
            kept.append(line)
            if len(kept) >= 80:
                break
    return "\n".join(kept)


def parse_swift_test_log(text):
    started = set()
    finished = set()
    failures = []
    durations = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = SWIFT_STARTED.search(line)
        if m:
            started.add(m.group(1))
        m = SWIFT_ENDED.search(line)
        if m:
            finished.add(m.group(1))
        if "✘ " in line or SWIFT_COMPILE_ERROR.match(line):
            failures.append(line)
        m = SWIFT_DURATION.search(line)
        if m:
            durations.append({"seconds": float(m.group(1)), "line": line})
    durations.sort(key=lambda item: item["seconds"], reverse=True)
    return {
        "failures": failures[:50],
        "unfinished": sorted(started - finished),
        "slowest": durations[:10],
    }


def format_swift_triage(triage):
    sections = []
    if triage["failures"]:
        sections.append("Swift failures:\n" + "\n".join("  " + item for item in triage["failures"][:25]))
    if triage["unfinished"]:
        sections.append("Unfinished (potentially hung) tests:\n" + "\n".join("  " + item for item in triage["unfinished"][:25]))
    if triage["slowest"]:
        sections.append("Slowest:\n" + "\n".join("  " + item["line"] for item in triage["slowest"][:5]))
    return "\n\n".join(sections)


def parse_node_version(text):
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    return tuple(int(part) for part in m.groups()) if m else None


def resolve_node(env, home):
    candidates = []
    if env.get("NODE"):
        candidates.append(env["NODE"])
    on_path = shutil.which("node", path=env.get("PATH"))
    if on_path:
        candidates.append(on_path)
    candidates.extend(["/opt/homebrew/bin/node", "/usr/local/bin/node"])
    nvm_root = home / ".nvm/versions/node"
    if nvm_root.is_dir():
        candidates.extend(str(p) for p in sorted(nvm_root.glob("v*/bin/node"), reverse=True))
    seen = set()
    for candidate in candidates:
        if not candidate or candidate in seen or not os.access(candidate, os.X_OK):
            continue
        seen.add(candidate)
        try:
            out = subprocess.run([candidate, "--version"], capture_output=True, text=True, timeout=5)
            version = parse_node_version(out.stdout)
            if version and version >= MIN_NODE_VERSION:
                return candidate
        except (OSError, subprocess.TimeoutExpired):
            continue
    return None


def resolve_agent_env(root, env, home=None):
    resolved = dict(env)
    home = Path(home) if home is not None else Path.home()
    if not resolved.get("NODE"):
        node = resolve_node(resolved, home)
        if node:
            resolved["NODE"] = node
    if not resolved.get("ULTIMATE_BIN"):
        found = shutil.which("ultimate", path=resolved.get("PATH"))
        if found:
            resolved["ULTIMATE_BIN"] = found
    return resolved


def resolve_screen_notice(env):
    configured = (env.get("KEYSCRIBE_SCREEN_NOTICE_CMD") or "").strip()
    if not configured:
        return None
    if os.access(configured, os.X_OK) and os.path.isfile(configured):
        return configured
    return shutil.which(configured, path=env.get("PATH"))


def check_prerequisites(check, env, home=None):
    problems = []
    home = Path(home) if home is not None else Path.home()
    path = env.get("PATH", "")
    if check.screen and (env.get("KEYSCRIBE_SCREEN_NOTICE_CMD") or "").strip() and not resolve_screen_notice(env):
        problems.append(f"KEYSCRIBE_SCREEN_NOTICE_CMD not found: {env['KEYSCRIBE_SCREEN_NOTICE_CMD']}")
    for vars_group in check.any_env:
        if not any(env.get(var) for var in vars_group):
            problems.append("set " + " or ".join(vars_group))
    for label, var, default_path, suffix in check.paths:
        base = Path(env[var]) if env.get(var) else (home / default_path[2:] if default_path.startswith("~/") else Path(default_path))
        target = base / suffix if suffix else base
        if not target.exists():
            problems.append(f"{label} missing at {target} (or set {var})")
    for var, description in check.dirs:
        if not env.get(var) or not Path(env[var]).is_dir():
            problems.append(f"set {var} to {description}")
    for cmd_name, var in check.commands:
        if not ((env.get(var) and os.access(env[var], os.X_OK)) or shutil.which(cmd_name, path=path)):
            problems.append(f"{cmd_name} CLI not found (or set {var})")
    if check.login:
        problems.extend(login_problems(check.login, env, home))
    return problems


LOGIN_CHECK = Path(__file__).resolve().parents[1] / "Tests/AgentConformance/login-check.ts"


def login_problems(agent, env, home):
    node = env.get("NODE") or resolve_node(env, home)
    if not node:
        return [f"node {'.'.join(map(str, MIN_NODE_VERSION))} or later not found, so the {agent} login cannot be checked (set NODE)"]
    try:
        answer = subprocess.run([node, str(LOGIN_CHECK), agent], capture_output=True, text=True, timeout=30,
                                env={**env, "HOME": str(home)})
    except (OSError, subprocess.TimeoutExpired) as error:
        return [f"could not check the {agent} login: {error}"]
    if answer.returncode == 0:
        return []
    return [(answer.stdout + answer.stderr).strip() or f"the {agent} login check exited with {answer.returncode}"]


def stop_group(process):
    for sig in [signal.SIGTERM, signal.SIGKILL]:
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        except PermissionError:
            if process.poll() is None:
                try:
                    process.send_signal(sig)
                except ProcessLookupError:
                    break
        if sig == signal.SIGTERM:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    try:
                        os.killpg(process.pid, 0)
                    except (ProcessLookupError, PermissionError):
                        break
                else:
                    try:
                        os.killpg(process.pid, 0)
                    except ProcessLookupError:
                        break
                    except PermissionError:
                        pass
                time.sleep(0.05)
            else:
                continue
            break
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def other_builds(root):
    answer = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, timeout=5, check=True)
    found = []
    for line in answer.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or Path(fields[1]).name not in {"swift-test", "swift-build", "swift-package", "xcodebuild"}:
            continue
        pid = fields[0]
        if sys.platform != "darwin":
            continue
        cwd = subprocess.run(["/usr/sbin/lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"], capture_output=True, text=True, timeout=5)
        if any(line.startswith("n") and Path(line[1:]).resolve().is_relative_to(root.resolve()) for line in cwd.stdout.splitlines()):
            found.append(pid)
    return found


def execute(check, root, run_folder, env, force=False, stop=None, provenance=None):
    root, run_folder = Path(root), Path(run_folder)
    folder = run_folder / check.id
    folder.mkdir(parents=True, exist_ok=True)
    log = folder / "output.log"
    start = time.monotonic()
    before = source_digest(root)
    signature = hashlib.sha256(json.dumps({
        "source": before, "environment": environment_digest(env), "argv": check.argv,
        "provenance": provenance or {}, "timeout": check.timeout, "silence": check.silence,
    }, sort_keys=True).encode()).hexdigest()
    cache_file = root / ".verification/cache" / f"{check.id}.json"
    result = {"id": check.id, "status": "failed", "source": before, "signature": signature,
              "argv": check.argv, "log": str(log), "started_at": datetime.now(timezone.utc).isoformat()}
    if check.cache and not force and cache_file.exists():
        try:
            cached = json.loads(cache_file.read_text())
            artifact = artifact_digest(check.artifact) if check.artifact else None
            previous = json.loads(Path(cached["result"]).read_text())
            if (cached["signature"] == signature and cached.get("artifact") == artifact
                    and previous["status"] == "passed" and previous["signature"] == signature and Path(previous["log"]).is_file()):
                result.update(status="cached", previous_result=cached["result"], seconds=0)
                write_json(folder / "result.json", result)
                print(f"CACHED {check.id}", flush=True)
                return result
        except (OSError, ValueError, KeyError):
            pass
    print(f"START  {check.id} (limit {check.timeout:g}s)", flush=True)
    screen = None
    process = None
    master = None
    slave = None
    screen_until = None
    try:
        if stop and stop.is_set():
            raise RuntimeError("verification interrupted")
        missing = check_prerequisites(check, env)
        if missing:
            raise RuntimeError("missing prerequisites: " + "; ".join(missing))
        if check.lane == "swift":
            busy = other_builds(root)
            if busy:
                raise RuntimeError(f"another build is active in this checkout (PID {', '.join(busy)}); no process was stopped")
        if check.screen:
            screen_bin = resolve_screen_notice(env)
            if screen_bin:
                minutes = 15 if check.id == "ultimate-page" else 5
                subprocess.run([screen_bin, "on", f"verifying {check.id}", str(minutes)], check=True, timeout=15)
                screen = screen_bin
                screen_until = time.monotonic() + minutes * 60
        master, slave = pty.openpty()
        process = subprocess.Popen(check.argv, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                   stdout=slave, stderr=subprocess.STDOUT, start_new_session=True)
        os.close(slave)
        slave = None
        os.set_blocking(master, False)
        last_output = last_progress = time.monotonic()
        parent_ended = None
        selector = selectors.DefaultSelector()
        selector.register(master, selectors.EVENT_READ)
        with log.open("wb") as output, selector:
            while True:
                now = time.monotonic()
                if stop and stop.is_set():
                    raise RuntimeError("verification interrupted")
                if now - start >= check.timeout:
                    raise RuntimeError("check deadline exceeded")
                if now - last_output >= check.silence:
                    raise RuntimeError("no output before silence deadline")
                if screen and screen_until and now >= screen_until:
                    minutes = max(1, math.ceil((check.timeout - (now - start)) / 60))
                    subprocess.run([screen, "on", f"verifying {check.id}", str(minutes)], check=True, timeout=15)
                    screen_until = time.monotonic() + minutes * 60
                if now - last_progress >= 30:
                    print(f"RUN    {check.id} {now - start:.0f}s; last output {now - last_output:.0f}s ago", flush=True)
                    last_progress = now
                readable = selector.select(0.05)
                ended = False
                if readable:
                    try:
                        block = os.read(master, 65536)
                    except OSError:
                        block = b""
                    if block:
                        output.write(block)
                        output.flush()
                        last_output = time.monotonic()
                    else:
                        ended = True
                code = process.poll()
                if code is not None:
                    parent_ended = parent_ended or now
                    if ended or not readable:
                        break
                    if now - parent_ended > 2:
                        raise RuntimeError("a descendant kept output open after the command ended")
        result["exit_code"] = process.wait(timeout=5)
        if result["exit_code"] == 0:
            result["status"] = "passed"
        else:
            result["problem"] = f"command exited {result['exit_code']}"
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        result["problem"] = str(error)
    finally:
        if process:
            if result["status"] != "passed":
                process_snapshot(folder)
                if sys.platform == "darwin" and process.poll() is None:
                    samples = []
                    for target_pid in sample_targets(process.pid, process.pid):
                        sample_file = folder / f"sample-{target_pid}.txt"
                        try:
                            subprocess.run(["/usr/bin/sample", str(target_pid), "1", "-file", str(sample_file)],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                            if sample_file.exists():
                                samples.append(f"=== PID {target_pid} ===\n" + sample_file.read_text(errors="replace"))
                                sample_file.unlink(missing_ok=True)
                        except (OSError, subprocess.TimeoutExpired):
                            pass
                    if samples:
                        combined = "\n\n".join(samples)
                        (folder / "sample.txt").write_text(combined)
                        frames = extract_sample_frames(combined)
                        if frames:
                            (folder / "sample-frames.txt").write_text(frames + "\n")
            try:
                stop_group(process)
            except (OSError, subprocess.SubprocessError) as error:
                result.update(status="failed", problem=f"could not stop the job's process group: {error}")
        for descriptor in [master, slave]:
            if descriptor is not None:
                os.close(descriptor)
        if screen:
            try:
                subprocess.run([screen, "off"], check=True, timeout=15)
            except (OSError, subprocess.SubprocessError) as error:
                result.update(status="failed", problem=f"could not release screen notice command: {error}")
    result["seconds"] = round(time.monotonic() - start, 2)
    after = source_digest(root)
    if after != before:
        result.update(status="changed", problem="source changed while the check was running", source_after=after)
    if result["status"] == "passed" and check.artifact:
        if not check.artifact.exists():
            result.update(status="failed", problem="build produced no artifact")
        else:
            result["artifact"] = artifact_digest(check.artifact)
    if result["status"] != "passed":
        if not (folder / "processes.txt").exists():
            process_snapshot(folder)
        triage_summary = ""
        if check.id == "swift" and log.exists():
            triage = parse_swift_test_log(log.read_text(errors="replace"))
            write_json(folder / "swift-triage.json", triage)
            triage_summary = format_swift_triage(triage)
        excerpt = log.read_bytes()[-12000:].decode(errors="replace") if log.exists() else ""
        sections = [result.get("problem", "failed")]
        if triage_summary:
            sections.append(triage_summary)
        if excerpt:
            sections.append(excerpt)
        (folder / "failure.txt").write_text("\n\n".join(sections))
        result["bundle"] = str(folder)
        print(f"FAIL   {check.id}: {result.get('problem')}; bundle {folder}", flush=True)
        if triage_summary:
            print(triage_summary, flush=True)
        print(excerpt[-3000:], flush=True)
    else:
        print(f"PASS   {check.id} ({result['seconds']:g}s)", flush=True)
    write_json(folder / "result.json", result)
    if result["status"] == "passed" and check.cache:
        write_json(cache_file, {"signature": signature, "artifact": result.get("artifact"), "result": str(folder / "result.json")})
    return result


def tool_provenance(env, root):
    facts = {}
    for name, argv in [("swift", ["xcrun", "swift", "--version"]), ("node", [env.get("NODE", "node"), "--version"]),
                       ("xcode", ["xcodebuild", "-version"]), ("python", [sys.executable, "--version"]),
                       ("commit", ["git", "-C", str(root), "rev-parse", "HEAD"]),
                       ("version", ["git", "-C", str(root), "describe", "--tags", "--always", "--dirty"]),
                       ("build-number", ["git", "-C", str(root), "rev-list", "--count", "HEAD"])]:
        try:
            answer = subprocess.run(argv, capture_output=True, text=True, timeout=15, env=env)
            facts[name] = {"exit_code": answer.returncode, "version": (answer.stdout + answer.stderr).strip()[:1000]}
        except (OSError, subprocess.TimeoutExpired) as error:
            facts[name] = {"problem": str(error)}
    return facts


def run_plan(plan, root, run_folder, env, profile, required, jobs=2, force=False):
    stop = threading.Event()
    previous = {}
    for sig in [signal.SIGTERM, signal.SIGINT]:
        previous[sig] = signal.signal(sig, lambda *_: stop.set())
    started_source = source_digest(root)
    provenance = tool_provenance(env, root)
    results = {}
    pending = list(plan)
    running = {}
    receipt_path = run_folder / "receipt.json"

    def receipt():
        value = {"schema_version": 1, "profile": profile, "source": started_source, "tools": provenance,
                 "required": required, "selected": [check.id for check in plan],
                 "results": [results[check.id] for check in plan if check.id in results]}
        value["complete"] = len(results) == len(plan) and all(r["status"] in {"passed", "cached"} for r in results.values())
        value["full_gate"] = profile == "full" and set(value["selected"]) == set(required) and value["complete"]
        write_json(receipt_path, value)
        return value

    receipt()
    try:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            while pending or running:
                for check in pending[:]:
                    if stop.is_set():
                        results[check.id] = {"id": check.id, "status": "interrupted"}
                        pending.remove(check)
                        continue
                    if any(dependency in results and results[dependency]["status"] not in {"passed", "cached"} for dependency in check.needs):
                        results[check.id] = {"id": check.id, "status": "blocked", "problem": "a required check failed"}
                        pending.remove(check)
                        print(f"BLOCK  {check.id}: a required check failed", flush=True)
                        continue
                    occupied = {item.lane for item in running.values() if item.lane}
                    if len(running) >= jobs or (check.lane and check.lane in occupied) or not all(dependency in results for dependency in check.needs):
                        continue
                    check_env = {key: value for key, value in env.items() if key not in HARNESS_FILTERS}
                    check_env["KEYSCRIBE_VERIFICATION_ARTIFACTS"] = str(run_folder / check.id / "artifacts")
                    future = pool.submit(execute, check, root, run_folder, check_env, force, stop, provenance)
                    running[future] = check
                    pending.remove(check)
                for future, check in list(running.items()):
                    if future.done():
                        try:
                            results[check.id] = future.result()
                        except Exception as error:
                            results[check.id] = {"id": check.id, "status": "failed", "problem": str(error)}
                        del running[future]
                receipt()
                time.sleep(0.1)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    value = receipt()
    current_source = source_digest(root)
    current_provenance = tool_provenance(env, root)
    if current_source != started_source or current_provenance != provenance:
        value.update(complete=False, full_gate=False, source_after=current_source, tools_after=current_provenance,
                     problem="source or tools changed during verification")
        write_json(receipt_path, value)
    print(f"{'PASS' if value['complete'] else 'FAIL'} {'full agent gate' if value['full_gate'] else 'selected checks'}; receipt {receipt_path}", flush=True)
    return 0 if value["complete"] else 1


def main():
    parser = argparse.ArgumentParser(description="Run agent verification with bounded jobs, failure bundles and exact-input receipts.")
    parser.add_argument("--profile", choices=["unit", "full"], default="full")
    parser.add_argument("--only", help="comma-separated check IDs; dependencies are included; a subset is never a full gate")
    parser.add_argument("--jobs", type=int, choices=range(1, 5), default=2)
    parser.add_argument("--force", action="store_true", help="rerun even unchanged deterministic checks; live checks always rerun")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--preflight", action="store_true", help="check tools, logins and env for selected checks without running them")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    xcode = subprocess.run(["/usr/bin/xcrun", "--find", "swift"], capture_output=True, text=True, timeout=15)
    if xcode.returncode:
        parser.error("the Xcode Swift toolchain is required")
    env["PATH"] = str(Path(xcode.stdout.strip()).parent) + os.pathsep + env.get("PATH", "")
    env = resolve_agent_env(root, env)
    app = root / ".verification/artifacts/KeyScribeDev.app"
    env["KEYSCRIBE_APP_OUTPUT"] = str(app)
    env["KEYSCRIBE_APP"] = str(app / "Contents/MacOS/KeyScribe")
    plan = verification_plan(root, env, args.profile)
    if args.list:
        for check in plan:
            print(f"{check.id:22} {shlex.join(check.argv)}")
        return 0
    try:
        selected = select_checks(plan, args.only.split(",") if args.only else None)
    except ValueError as error:
        parser.error(str(error))
    if args.preflight:
        missing_any = False
        for check in selected:
            problems = check_prerequisites(check, env)
            if problems:
                missing_any = True
                print(f"MISS   {check.id:22} {'; '.join(problems)}")
            else:
                print(f"READY  {check.id}")
        return 1 if missing_any else 0
    state = root / ".verification"
    state.mkdir(exist_ok=True)
    with (state / "lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("another verification run owns this checkout; no new jobs were started")
        run_folder = state / "runs" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
        run_folder.mkdir(parents=True)
        print(f"Verification results: {run_folder}", flush=True)
        return run_plan(selected, root, run_folder, env, args.profile, [check.id for check in plan], args.jobs, args.force)


if __name__ == "__main__":
    sys.exit(main())
