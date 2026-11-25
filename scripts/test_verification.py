import contextlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from check_diff import check_diff_lines, check_file_lines, check_stray_scratch, check_untracked_files
from verification_inputs import artifact_digest, source_digest
from verify_agents import (
    Check,
    check_prerequisites,
    environment_digest,
    execute,
    extract_sample_frames,
    load_connector_checks,
    parse_swift_test_log,
    resolve_agent_env,
    resolve_node,
    run_plan,
    sample_targets,
    select_checks,
    verification_plan,
)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, timeout=10)
        (self.root / ".gitignore").write_text(".verification/\n")
        (self.root / "source.txt").write_text("original")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True, timeout=10)

    def command(self, body, **options):
        return Check("fixture", (sys.executable, "-u", "-c", body), timeout=5, silence=2, **options)

    def run_check(self, check, folder="run", **options):
        with contextlib.redirect_stdout(io.StringIO()):
            return execute(check, self.root, self.root / ".verification" / folder, os.environ.copy(), **options)

    def test_edits_to_the_same_dirty_path_invalidate_the_source_key(self):
        source = self.root / "source.txt"
        source.write_text("first edit")
        before = source_digest(self.root)
        status = subprocess.check_output(["git", "-C", str(self.root), "status", "--porcelain"], timeout=10)
        source.write_text("other edit")
        self.assertEqual(status, subprocess.check_output(["git", "-C", str(self.root), "status", "--porcelain"], timeout=10))
        self.assertNotEqual(before, source_digest(self.root))

    def test_untracked_edits_deletions_and_executable_mode_invalidate_the_key(self):
        before = source_digest(self.root)
        added = self.root / "new.txt"
        added.write_text("one")
        one = source_digest(self.root)
        added.write_text("two")
        two = source_digest(self.root)
        added.chmod(0o755)
        executable = source_digest(self.root)
        (self.root / "source.txt").unlink()
        self.assertEqual(len({before, one, two, executable, source_digest(self.root)}), 5)

    def test_ignored_results_do_not_invalidate_the_key(self):
        before = source_digest(self.root)
        output = self.root / ".verification"
        output.mkdir()
        (output / "receipt.json").write_text("result")
        self.assertEqual(before, source_digest(self.root))

    def test_symlinks_hash_what_they_reach_and_dangling_or_cyclic_links_do_not_crash(self):
        external = self.root / ".verification" / "outside.txt"
        external.parent.mkdir()
        external.write_text("one")
        link = self.root / "linked.txt"
        link.symlink_to(external)
        before = source_digest(self.root)
        external.write_text("two")
        self.assertNotEqual(before, source_digest(self.root))
        folder = self.root / ".verification" / "folder"
        folder.mkdir()
        (folder / "inner.txt").write_text("one")
        (folder / "loop").symlink_to(folder)
        (self.root / "linked-folder").symlink_to(folder)
        with_folder = source_digest(self.root)
        (folder / "inner.txt").write_text("two")
        self.assertNotEqual(with_folder, source_digest(self.root))
        (self.root / "linked-folder").unlink()
        external.write_text("one")
        link.unlink()
        link.symlink_to("dangling/does-not-exist")
        dangling = source_digest(self.root)
        self.assertNotEqual(before, dangling)
        self.assertEqual(dangling, source_digest(self.root))
        self.assertTrue(artifact_digest(link))

    def test_artifact_contents_matter_even_with_the_same_size_and_mtime(self):
        artifact = self.root / "app"
        artifact.write_bytes(b"first")
        before = artifact_digest(artifact)
        stat = artifact.stat()
        artifact.write_bytes(b"other")
        os.utime(artifact, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        self.assertNotEqual(before, artifact_digest(artifact))

    def test_failure_receipt_preserves_the_error_and_exit_code(self):
        result = self.run_check(self.command("print('fixture failure', flush=True); raise SystemExit(7)"))
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["exit_code"], 7)
        self.assertIn("fixture failure", Path(result["log"]).read_text())
        bundle = Path(result["bundle"])
        self.assertIn("fixture failure", (bundle / "failure.txt").read_text())
        self.assertEqual(json.loads((bundle / "result.json").read_text())["exit_code"], 7)

    def test_a_silent_process_is_bounded_and_diagnosed(self):
        check = self.command("import time; time.sleep(30)")
        check.silence = 0.15
        result = self.run_check(check)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["problem"], "no output before silence deadline")
        self.assertTrue((Path(result["bundle"]) / "processes.txt").exists())

    def test_a_writing_process_still_has_an_absolute_deadline(self):
        check = self.command("import time\nwhile True: print('working', flush=True); time.sleep(.02)")
        check.timeout = 0.2
        result = self.run_check(check)
        self.assertEqual(result["problem"], "check deadline exceeded")

    def test_a_changed_source_cannot_publish_a_passing_receipt(self):
        result = self.run_check(self.command("from pathlib import Path; Path('source.txt').write_text('changed')"))
        self.assertEqual(result["status"], "changed")

    def test_cache_reuse_ignores_unrelated_env_vars_and_invalidates_on_allowlisted_env(self):
        check = self.command("print('passed')")
        first = self.run_check(check, "first")
        second = self.run_check(check, "second")
        self.assertEqual(first["status"], "passed")
        self.assertEqual(second["status"], "cached")
        unrelated_env = dict(os.environ, TERM_SESSION_ID="new-session", SHLVL="9", SSH_AUTH_SOCK="/tmp/other", RANDOM_TOKEN="xyz")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(execute(check, self.root, self.root / ".verification/unrelated", unrelated_env)["status"], "cached")
        (self.root / "source.txt").write_text("changed")
        self.assertEqual(self.run_check(check, "third")["status"], "passed")
        changed = self.command("print('new command')")
        self.assertEqual(self.run_check(changed, "fourth")["status"], "passed")
        allowlisted_env = dict(os.environ, TOOLCHAINS="com.apple.dt.toolchain.Metal.custom")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(execute(changed, self.root, self.root / ".verification/fifth", allowlisted_env)["status"], "passed")
        self.assertEqual(
            environment_digest({"NODE": "/usr/bin/node", "TERM_SESSION_ID": "a"}),
            environment_digest({"NODE": "/usr/bin/node", "TERM_SESSION_ID": "b"}),
        )
        self.assertNotEqual(
            environment_digest({"ULTIMATE_CLONE": "/a"}),
            environment_digest({"ULTIMATE_CLONE": "/b"}),
        )

    def test_live_checks_are_never_reused(self):
        check = self.command("print('live')", cache=False)
        self.assertEqual(self.run_check(check, "first")["status"], "passed")
        self.assertEqual(self.run_check(check, "second")["status"], "passed")

    def test_a_cache_entry_without_its_original_evidence_is_not_reused(self):
        check = self.command("print('passed')")
        first = self.run_check(check, "first")
        Path(first["log"]).unlink()
        self.assertEqual(self.run_check(check, "second")["status"], "passed")

    def test_changed_artifacts_invalidate_a_build_receipt(self):
        artifact = self.root / ".verification/artifact"
        check = self.command("from pathlib import Path; Path('.verification/artifact').write_text('build')", artifact=artifact)
        self.assertEqual(self.run_check(check, "first")["status"], "passed")
        self.assertEqual(self.run_check(check, "second")["status"], "cached")
        artifact.write_text("other")
        self.assertEqual(self.run_check(check, "third")["status"], "passed")

    def test_selection_includes_dependencies_and_rejects_unknown_checks(self):
        plan = [Check("build", ("true",)), Check("live", ("true",), needs=("build",))]
        self.assertEqual([c.id for c in select_checks(plan, ["live"])], ["build", "live"])
        with self.assertRaisesRegex(ValueError, "unknown"):
            select_checks(plan, ["typo"])

    def test_the_tools_row_runs_first_wherever_the_table_lists_it(self):
        table = (Path(__file__).resolve().parent / "connector_checks.tsv").read_text().splitlines()
        moved = [row for row in table if not row.startswith("tools\t")] + [row for row in table if row.startswith("tools\t")]
        (self.root / "scripts").mkdir()
        (self.root / "scripts/connector_checks.tsv").write_text("\n".join(moved) + "\n")
        plan = verification_plan(self.root, os.environ.copy(), "unit")
        self.assertEqual([c.id for c in plan[:2]], ["tools", "swift"])

    def test_every_connector_command_reads_the_same_in_preflight_and_the_runner(self):
        table = (Path(__file__).resolve().parent / "connector_checks.tsv").read_text().splitlines()
        for row in table:
            if not row.strip() or row.startswith("#"):
                continue
            command = row.split("\t")[3]
            self.assertEqual(shlex.split(command), command.split(), command)
            self.assertFalse(set(command) & set("'\"\\$`*?~;&|<>(){}"), command)

    def test_the_full_plan_requires_every_connector_and_live_agent(self):
        plan = verification_plan(self.root, os.environ.copy(), "full")
        ids = {c.id for c in plan}
        self.assertTrue({"swift", "tools", "claude-connector", "pi-connector", "omp-connector", "bb-plugin", "codex-connector", "ultimate-connector"} <= ids)
        self.assertTrue({f"live-{agent}" for agent in ["claude", "pi", "omp", "bb", "codex", "ultimate"]} <= ids)
        self.assertTrue({"build", "ultimate-live", "ultimate-page", "ultimate-page-smoke"} <= ids)
        for check in plan:
            if check.id.startswith("live-") or check.id in {"ultimate-live", "ultimate-page", "ultimate-page-smoke"}:
                self.assertFalse(check.cache)
        smoke = next(c for c in plan if c.id == "ultimate-page-smoke")
        self.assertFalse(smoke.screen)

    def test_the_unit_plan_never_takes_over_the_screen_or_calls_a_live_agent(self):
        plan = verification_plan(self.root, os.environ.copy(), "unit")
        self.assertFalse(any(c.screen or c.id.startswith("live-") or c.id.startswith("ultimate-l") or c.id == "ultimate-page" for c in plan))

    def run_plan(self, checks, required=None, **options):
        folder = self.root / ".verification/plan"
        with contextlib.redirect_stdout(io.StringIO()), patch("verify_agents.tool_provenance", return_value={}):
            code = run_plan(checks, self.root, folder, os.environ.copy(), "full", required or [c.id for c in checks], **options)
        return code, json.loads((folder / "receipt.json").read_text())

    def test_a_partial_run_cannot_publish_a_full_gate(self):
        code, receipt = self.run_plan([self.command("print('passed')")], required=["fixture", "another"])
        self.assertEqual(code, 0)
        self.assertTrue(receipt["complete"])
        self.assertFalse(receipt["full_gate"])

    def test_a_harness_filter_in_the_caller_environment_never_narrows_a_check(self):
        seen = {}

        def work(check, root, folder, env, *_):
            seen.update(env)
            return {"id": check.id, "status": "passed"}

        narrowed = dict(os.environ, ONLY="Tab", TARGETS="main", REPEAT="3", FAIL_FAST="1", AGENT="codex", REPLY_WAIT="45")
        with contextlib.redirect_stdout(io.StringIO()), patch("verify_agents.tool_provenance", return_value={}), \
                patch("verify_agents.execute", side_effect=work):
            run_plan([Check("fixture", ("true",))], self.root, self.root / ".verification/plan", narrowed, "full", ["fixture"])
        self.assertFalse({"ONLY", "TARGETS", "REPEAT", "FAIL_FAST", "AGENT"} & seen.keys())
        self.assertEqual(seen["REPLY_WAIT"], "45")

    def test_the_ultimate_connector_tests_refuse_a_checkout_that_is_not_installed(self):
        script = Path(__file__).resolve().parent / "test-ultimate-connector.sh"
        clone = self.root / "clone"
        (clone / "scripts").mkdir(parents=True)
        (clone / "scripts/check-extension.ts").write_text("include: ['ext/*/web.solid.tsx', 'ext/*/server.ts']\n")
        answer = subprocess.run(["bash", str(script)], capture_output=True, text=True, timeout=60,
                                env=dict(os.environ, ULTIMATE_CLONE=str(clone), NODE=str(self.root / "no-node")))
        self.assertEqual(answer.returncode, 1, answer.stdout + answer.stderr)
        self.assertIn("not an installed Ultimate checkout", answer.stderr)
        self.assertNotIn("ℹ tests", answer.stdout)

    def test_a_failed_prerequisite_blocks_the_expensive_check(self):
        failed = Check("first", (sys.executable, "-c", "raise SystemExit(7)"))
        expensive = Check("later", (sys.executable, "-c", "raise RuntimeError('must not start')"), needs=("first",))
        code, receipt = self.run_plan([failed, expensive])
        self.assertEqual(code, 1)
        self.assertEqual([r["status"] for r in receipt["results"]], ["failed", "blocked"])

    def test_independent_jobs_share_the_worker_limit(self):
        barrier = threading.Barrier(2, timeout=2)

        def work(check, *_):
            barrier.wait()
            return {"id": check.id, "status": "passed"}

        with patch("verify_agents.execute", side_effect=work):
            code, receipt = self.run_plan([Check("first", ("true",)), Check("second", ("true",))], jobs=2)
        self.assertEqual(code, 0)
        self.assertTrue(receipt["full_gate"])

    def test_swift_jobs_never_overlap_even_with_multiple_workers(self):
        sequence = []

        def work(check, *_):
            sequence.append((check.id, "start"))
            time.sleep(0.05)
            sequence.append((check.id, "end"))
            return {"id": check.id, "status": "passed"}

        with patch("verify_agents.execute", side_effect=work):
            self.run_plan([Check("first", ("true",), lane="swift"), Check("second", ("true",), lane="swift")], jobs=2)
        self.assertEqual(sequence, [("first", "start"), ("first", "end"), ("second", "start"), ("second", "end")])

    def test_sample_targets_prefers_hung_descendant_over_wrapper_parent(self):
        ps_table = "\n".join([
            "100 1 100 /usr/bin/make",
            "101 100 100 /bin/sh",
            "102 101 100 /Applications/Xcode.app/usr/bin/swift-test",
            "103 102 100 /tmp/KeyScribePackageTests.xctest/swiftpm-testing-helper",
            "200 1 200 /usr/bin/other",
        ])
        self.assertEqual(sample_targets(100, 100, ps_output=ps_table), [103])
        self.assertEqual(sample_targets(999, 999, ps_output=ps_table), [999])

    def test_extract_sample_frames_keeps_only_relevant_stack_lines(self):
        raw = "\n".join([
            "Call graph:",
            "    2500 Thread_1234",
            "      2500 start  (in dyld)",
            "        2500 KeyScribeApp.AgentHub.rescan()  (in KeyScribeAppTests)",
            "          2500 Testing.Runner.run()  (in Testing)",
            "            2500 __psynch_cvwait  (in libsystem_kernel.dylib)",
        ])
        frames = extract_sample_frames(raw)
        self.assertIn("KeyScribeApp.AgentHub.rescan()", frames)
        self.assertIn("Testing.Runner.run()", frames)
        self.assertNotIn("dyld", frames)
        self.assertNotIn("__psynch_cvwait", frames)

    def test_swift_test_log_parser_surfaces_early_failures_hung_tests_and_slowest(self):
        filler = "\n".join(f"✔ Test filler{i}() passed after 0.001 seconds." for i in range(400))
        log = "\n".join([
            "◇ Test earlyFailure() started.",
            "✘ Test earlyFailure() recorded an issue at FooTests.swift:12:5: Expectation failed",
            "✘ Test earlyFailure() failed after 1.250 seconds with 1 issue.",
            "◇ Test slowPass() started.",
            "✔ Test slowPass() passed after 14.500 seconds.",
            "◇ Test hungTest() started.",
            filler,
            "Sources/KeyScribe/Foo.swift:9:1: error: cannot find 'bar' in scope",
        ])
        triage = parse_swift_test_log(log)
        self.assertTrue(any("earlyFailure()" in item for item in triage["failures"]))
        self.assertTrue(any("cannot find 'bar'" in item for item in triage["failures"]))
        self.assertEqual(triage["unfinished"], ["hungTest()"])
        self.assertEqual(triage["slowest"][0]["seconds"], 14.5)

    def test_swift_check_failure_writes_triage_even_when_failure_is_far_above_tail(self):
        body = (
            "print('◇ Test buriedFail() started.')\n"
            "print('✘ Test buriedFail() failed after 0.500 seconds with 1 issue.')\n"
            "print('◇ Test neverEnded() started.')\n"
            "for i in range(400): print(f'✔ Test filler{i}() passed after 0.001 seconds.')\n"
            "raise SystemExit(1)\n"
        )
        check = Check("swift", (sys.executable, "-u", "-c", body), timeout=5, silence=2)
        result = self.run_check(check)
        self.assertEqual(result["status"], "failed")
        bundle = Path(result["bundle"])
        triage = json.loads((bundle / "swift-triage.json").read_text())
        self.assertEqual(triage["unfinished"], ["neverEnded()"])
        self.assertTrue(any("buriedFail()" in item for item in triage["failures"]))
        failure_text = (bundle / "failure.txt").read_text()
        self.assertIn("buriedFail()", failure_text)
        self.assertIn("neverEnded()", failure_text)

    def test_resolve_agent_env_does_not_inject_personal_paths_or_tmp_binaries(self):
        resolved = resolve_agent_env(self.root, {"PATH": "/usr/bin:/bin"}, home=self.root / "empty-home")
        self.assertNotIn("ULTIMATE_CLONE", resolved)
        self.assertNotIn("ULTIMATE_BIN", resolved)
        explicit = resolve_agent_env(self.root, {"PATH": "/usr/bin:/bin", "ULTIMATE_CLONE": "/custom"}, home=self.root / "empty-home")
        self.assertEqual(explicit.get("ULTIMATE_CLONE"), "/custom")

    def test_screen_notice_is_optional_and_prerequisites_fail_before_calling_it(self):
        fake_bin = self.root / ".verification" / "bin"
        fake_bin.mkdir(parents=True)
        marker = self.root / ".verification" / "notice-ran"
        stub = fake_bin / "my-notice"
        stub.write_text(f"#!/bin/sh\necho \"$@\" >> '{marker}'\n")
        stub.chmod(0o755)

        plain_screen = Check("screen-ok", (sys.executable, "-c", "print('ok')"), screen=True, cache=False)
        self.assertEqual(check_prerequisites(plain_screen, {"PATH": "/usr/bin:/bin"}), [])
        self.assertTrue(check_prerequisites(plain_screen, {"PATH": "/usr/bin:/bin", "KEYSCRIBE_SCREEN_NOTICE_CMD": "missing-cmd"}))

        node = resolve_node(dict(os.environ), Path.home())
        self.assertIsNotNone(node, "the login check needs node 22.18 or later (set NODE)")
        env = {"PATH": f"{fake_bin}:/usr/bin:/bin", "KEYSCRIBE_SCREEN_NOTICE_CMD": str(stub), "NODE": node}
        claude = Check(
            "live-claude",
            ("true",),
            screen=True,
            cache=False,
            login="claude",
            commands=(("claude", "CLAUDE_BIN"),),
        )
        problems = check_prerequisites(claude, env, home=self.root / "no-home")
        self.assertTrue(any("CLAUDE_CODE_OAUTH_TOKEN" in p or "ANTHROPIC_API_KEY" in p for p in problems))
        helper_home = self.root / "helper-home"
        (helper_home / ".claude").mkdir(parents=True)
        (helper_home / ".claude/settings.json").write_text('{"apiKeyHelper": "~/bin/key"}')
        self.assertEqual(check_prerequisites(claude, {**env, "CLAUDE_BIN": str(stub)}, home=helper_home), [])
        with contextlib.redirect_stdout(io.StringIO()):
            result = execute(claude, self.root, self.root / ".verification/prereq", env)
        self.assertEqual(result["status"], "failed")
        self.assertIn("prerequisites", result["problem"])
        self.assertFalse(marker.exists())

        with contextlib.redirect_stdout(io.StringIO()):
            ok_result = execute(plain_screen, self.root, self.root / ".verification/notice-ok", env)
        self.assertEqual(ok_result["status"], "passed")
        lines = marker.read_text().splitlines()
        self.assertTrue(lines[0].startswith("on verifying screen-ok"))
        self.assertEqual(lines[-1], "off")

    def test_connector_checks_table_matches_plan_and_makefile_timeout_covers_full_gate(self):
        repo_root = Path(__file__).resolve().parent.parent
        table_ids = [row["id"] for row in load_connector_checks(repo_root)]
        plan = verification_plan(repo_root, os.environ.copy(), "full")
        plan_ids = {check.id for check in plan}
        self.assertTrue(set(table_ids) <= plan_ids)
        serial_budget = sum(c.timeout for c in plan if c.lane == "screen") + next(c.timeout for c in plan if c.id == "build")
        makefile = (repo_root / "Makefile").read_text()
        match = re.search(r"verify-agents:.*\n\ttimeout[^\n]*\s+(\d+)\s+python3", makefile)
        self.assertIsNotNone(match)
        self.assertGreaterEqual(int(match.group(1)), serial_budget)

    def test_check_diff_handles_untracked_files_multiline_strings_multiplication_and_scratch_prefixes(self):
        diff = "\n".join([
            "diff --git a/Sources/KeyScribe/Foo.swift b/Sources/KeyScribe/Foo.swift",
            "+++ b/Sources/KeyScribe/Foo.swift",
            "@@ -1,0 +1,6 @@",
            "+let url = \"https://example.com/a\"",
            "+let total = a",
            "+    * factor",
            "+    // stray comment",
            "+/* block",
            "+ * body */",
            "diff --git a/README.md b/README.md",
            "+++ b/README.md",
            "@@ -1,0 +1,1 @@",
            "+" + "Generated with " + "Cla" + "ude Code",
        ])
        issues = check_diff_lines(diff)
        self.assertTrue(any("Foo.swift:4:" in issue and "comment" in issue for issue in issues))
        self.assertTrue(any("Foo.swift:5:" in issue and "comment" in issue for issue in issues))
        self.assertTrue(any("Foo.swift:6:" in issue and "comment" in issue for issue in issues))
        self.assertFalse(any("factor" in issue for issue in issues))
        self.assertFalse(any("https://" in issue for issue in issues))
        self.assertTrue(any("README.md:1:" in issue and "AI" in issue for issue in issues))

        swift_multiline = 'let doc = """\n// inside string\n/* also inside */\n"""\nlet ok = 1\n'
        self.assertEqual(check_file_lines("Sources/KeyScribe/Doc.swift", swift_multiline), [])
        ts_template = "const s = `\n// inside template\n* star\n`\n"
        self.assertEqual(check_file_lines("Tests/AgentConformance/T.ts", ts_template), [])
        py_multiline = 'doc = """\n# inside python docstring\n"""\n# real comment\n'
        py_issues = check_file_lines("Tests/Tool.py", py_multiline)
        self.assertEqual(len(py_issues), 1)
        self.assertIn("Tests/Tool.py:4:", py_issues[0])

        untracked = self.root / "Sources/KeyScribe/NewFile.swift"
        untracked.parent.mkdir(parents=True)
        untracked.write_text("// untracked comment\nlet x = 1\n")
        untracked_issues = check_untracked_files(self.root)
        self.assertEqual(len(untracked_issues), 1)
        self.assertIn("NewFile.swift:1:", untracked_issues[0])

        prefix_file = self.root / "Tests/AgentConformance/lib/scratch-prefixes.json"
        prefix_file.parent.mkdir(parents=True)
        prefix_file.write_text(json.dumps({"instance": "custom-pfx-"}))
        fake_tmp = self.root / "tmp"
        (fake_tmp / "custom-pfx-123").mkdir(parents=True)
        stray = check_stray_scratch(self.root, temp_root=fake_tmp)
        self.assertEqual(len(stray), 1)
        self.assertIn("custom-pfx-123", stray[0])

    def test_swift_raw_strings_hide_comment_markers_and_a_comment_after_one_is_still_found(self):
        raw = 'let a = #"{"url":"https://example.com"}"#\nlet b = ##"say "#" then // too"##\nlet c = #"""\n"quoted" // inside\n"""#\nlet d = #"x"# // real\n'
        issues = check_file_lines("Tests/KeyScribeKitTests/Raw.swift", raw)
        self.assertEqual(len(issues), 1, issues)
        self.assertIn("Raw.swift:6:", issues[0])

    def test_check_diff_allows_naming_a_supported_agent_and_flags_attribution(self):
        self.assertEqual(check_file_lines("FAQ.md", "In " + "Cla" + "ude Code, run /reload-plugins."), [])
        self.assertEqual(check_file_lines("docs/a.md", "The " + "Co" + "dex connector reads its history."), [])
        flagged = check_file_lines("docs/a.md", "Co-Authored-By: " + "Cla" + "ude <noreply@example.com>")
        self.assertEqual(len(flagged), 1)
        self.assertIn("AI", flagged[0])

    def test_scratch_kept_on_purpose_is_not_stray(self):
        prefix_file = self.root / "Tests/AgentConformance/lib/scratch-prefixes.json"
        prefix_file.parent.mkdir(parents=True)
        prefix_file.write_text(json.dumps({"instance": "custom-pfx-", "agent": "agent-pfx-", "keptMarker": ".kept"}))
        fake_tmp = self.root / "tmp"
        (fake_tmp / "custom-pfx-kept").mkdir(parents=True)
        (fake_tmp / "custom-pfx-kept" / ".kept").write_text("")
        (fake_tmp / "agent-pfx-leaked").mkdir(parents=True)
        stray = check_stray_scratch(self.root, temp_root=fake_tmp)
        self.assertEqual(len(stray), 1)
        self.assertIn("agent-pfx-leaked", stray[0])


if __name__ == "__main__":
    unittest.main()
