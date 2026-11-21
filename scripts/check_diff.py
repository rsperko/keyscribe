import argparse
import fcntl
import glob
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tokenize

CODE_EXTENSIONS = {".swift", ".ts", ".tsx", ".js", ".mjs", ".py"}
HUNK_HEADER = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
AI_TOOLS = ("claude", "anthropic", "openai", "gemini", "codex", "copilot", "cursor")
AI_ATTRIBUTION = re.compile(
    "|".join([
        r"generated with " + AI_TOOLS[0],
        r"co-authored-by:.*\b(" + "|".join(AI_TOOLS) + r")\b",
    ]),
    re.IGNORECASE,
)


def parse_added_lines(diff_text):
    added = {}
    current_file = None
    line_no = 0
    for raw in diff_text.splitlines():
        if raw.startswith("+++ b/"):
            current_file = raw[6:]
            added.setdefault(current_file, {})
            continue
        if raw.startswith("+++ "):
            current_file = None
            continue
        header = HUNK_HEADER.match(raw)
        if header and current_file is not None:
            line_no = int(header.group(1))
            continue
        if current_file is None:
            continue
        if raw.startswith("+"):
            added[current_file][line_no] = raw[1:]
            line_no += 1
        elif not raw.startswith("-") and not raw.startswith("\\"):
            line_no += 1
    return added


def python_comment_lines(text):
    lines = set()
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.COMMENT:
                if tok.start[0] == 1 and tok.string.startswith("#!"):
                    continue
                lines.add(tok.start[0])
    except (tokenize.TokenError, IndentationError):
        pass
    return lines


def brace_lang_comment_lines(text, is_swift):
    comment_lines = set()
    block_depth = 0
    in_triple = False
    in_template = False
    for line_no, line in enumerate(text.splitlines(), start=1):
        i = 0
        n = len(line)
        in_single = False
        in_double = False
        if block_depth > 0 and line.strip():
            comment_lines.add(line_no)
        while i < n:
            if block_depth > 0:
                if is_swift and line.startswith("/*", i):
                    block_depth += 1
                    i += 2
                elif line.startswith("*/", i):
                    block_depth -= 1
                    i += 2
                else:
                    i += 1
                continue
            if in_triple:
                if line.startswith('"""', i):
                    in_triple = False
                    i += 3
                elif line[i] == "\\":
                    i += 2
                else:
                    i += 1
                continue
            if in_template:
                if line[i] == "\\":
                    i += 2
                elif line[i] == "`":
                    in_template = False
                    i += 1
                else:
                    i += 1
                continue
            if in_double:
                if line[i] == "\\":
                    i += 2
                elif line[i] == '"':
                    in_double = False
                    i += 1
                else:
                    i += 1
                continue
            if in_single:
                if line[i] == "\\":
                    i += 2
                elif line[i] == "'":
                    in_single = False
                    i += 1
                else:
                    i += 1
                continue
            if line.startswith("//", i):
                comment_lines.add(line_no)
                break
            if line.startswith("/*", i):
                comment_lines.add(line_no)
                block_depth += 1
                i += 2
                continue
            if is_swift and line.startswith('"""', i):
                in_triple = True
                i += 3
                continue
            if not is_swift and line[i] == "`":
                in_template = True
                i += 1
                continue
            if line[i] == '"':
                in_double = True
                i += 1
                continue
            if not is_swift and line[i] == "'":
                in_single = True
                i += 1
                continue
            i += 1
    return comment_lines


def check_file_lines(relpath, text, added_lines=None):
    issues = []
    lines = text.splitlines()
    target = set(added_lines) if added_lines is not None else set(range(1, len(lines) + 1))
    path = Path(relpath)
    check_comments = bool(path.parts and path.parts[0] in {"Sources", "Tests"} and path.suffix in CODE_EXTENSIONS)
    comments = set()
    if check_comments:
        comments = python_comment_lines(text) if path.suffix == ".py" else brace_lang_comment_lines(text, path.suffix == ".swift")
    for line_no in sorted(target):
        if line_no < 1 or line_no > len(lines):
            continue
        line = lines[line_no - 1]
        if AI_ATTRIBUTION.search(line):
            issues.append(f"{relpath}:{line_no}: prohibited AI attribution: {line.strip()[:100]}")
        if check_comments and line_no in comments:
            issues.append(f"{relpath}:{line_no}: added code comment: {line.strip()[:100]}")
    return issues


def check_diff_lines(diff_text, root=None):
    issues = []
    for relpath, line_map in parse_added_lines(diff_text).items():
        if not line_map:
            continue
        disk_path = Path(root) / relpath if root is not None else None
        if disk_path is not None and disk_path.is_file():
            raw = disk_path.read_bytes()
            if b"\x00" in raw:
                continue
            issues.extend(check_file_lines(relpath, raw.decode("utf-8", errors="replace"), line_map.keys()))
        else:
            synthetic = "\n".join(line_map[number] for number in sorted(line_map))
            issues.extend(check_file_lines(relpath, synthetic))
    return issues


def check_untracked_files(root):
    raw_names = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z"],
        timeout=30,
    )
    issues = []
    for entry in sorted(set(raw_names.split(b"\x00")) - {b""}):
        relpath = os.fsdecode(entry)
        disk_path = Path(root) / relpath
        if not disk_path.is_file() or disk_path.is_symlink():
            continue
        raw = disk_path.read_bytes()
        if b"\x00" in raw:
            continue
        issues.extend(check_file_lines(relpath, raw.decode("utf-8", errors="replace")))
    return issues


def load_scratch_config(root):
    config = Path(root) / "Tests/AgentConformance/lib/scratch-prefixes.json"
    data = json.loads(config.read_text()) if config.is_file() else {}
    prefixes = [data[key] for key in ("instance", "agent") if isinstance(data.get(key), str) and data[key]]
    return prefixes, data.get("keptMarker")


def check_stray_scratch(root, temp_root=None):
    lock_path = Path(root) / ".verification" / "lock"
    if lock_path.exists():
        try:
            with lock_path.open("r+") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(handle, fcntl.LOCK_UN)
        except BlockingIOError:
            return []
        except OSError:
            pass
    base = Path(temp_root) if temp_root is not None else Path(os.path.realpath("/tmp"))
    prefixes, marker = load_scratch_config(root)
    stray = []
    for prefix in prefixes:
        stray.extend(path for path in glob.glob(str(base / f"{prefix}*"))
                     if not (marker and (Path(path) / marker).exists()))
    return [f"stray conformance scratch dir: {path}" for path in sorted(set(stray))]


def main():
    parser = argparse.ArgumentParser(description="Check uncommitted diff and untracked files for repo hygiene issues.")
    parser.add_argument("--base", help="git ref to diff against (default: working tree vs HEAD plus untracked files)")
    parser.add_argument("--check-scratch", action="store_true", help="also flag stray conformance scratch dirs")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    argv = ["git", "-C", str(root), "diff", "-U0"] + ([args.base] if args.base else ["HEAD"])
    diff_text = subprocess.check_output(argv, text=True, timeout=30)
    issues = check_diff_lines(diff_text, root=root)
    if not args.base:
        issues += check_untracked_files(root)
    if args.check_scratch:
        issues += check_stray_scratch(root)
    if issues:
        for issue in issues:
            print(issue, file=sys.stderr)
        return 1
    print("check-diff: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
