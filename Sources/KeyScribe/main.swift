import AppKit
import Foundation
import KeyScribeKit
import Synchronization

// `--help` / `-h`: print the CLI surface and exit. Run with no arguments to launch the menu-bar app;
// the flags below are dev/admin tools meant to be run from a terminal.
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    KeyScribe — privacy-first, on-device voice dictation for macOS.

    Usage: KeyScribe [flags]
      Run with no flags to launch the menu-bar app. The flags below are for
      development and administration; run the binary directly from a terminal:
        KeyScribe.app/Contents/MacOS/KeyScribe [flags]

    Flags:
      -h, --help              Show this help and exit.
      --reset <target>        Clear local state and exit. <target> is one of:
                                onboarding   Clear the first-run flag.
                                modes        Re-seed the starter modes (discards edits to defaults).
                                config       Wipe config/modes/fragments (keeps models) + first-run flag.
                                permissions  Remove TCC grants (Mic/Accessibility/Automation) so macOS re-prompts.
                                all          Wipe the whole support dir + first-run flag (shared models kept).
                                eraseAll     Like all, plus erase the variant's BYOK Keychain keys (TCC grants kept).
      --benchmark <dir>       Run the STT benchmark over recordings in <dir> and exit.
        --engines <a,b,...>     Limit the benchmark run to these engine ids.
        --raw                   Emit raw per-clip benchmark output.
        --fuzzy                 Apply the post-STT fuzzy corrector (dict = clip bias terms) before scoring.
      --commands-check <dir>  Exercise every spoken command (scratch that, verbatim, insert new
                              line/paragraph/tab, insert clipboard contents, whole-utterance
                              replacements) across every installed engine on the recordings in <dir>
                              (manifest.json), then exit. Honors --engines. Informational by default.
        --baseline <file>       Gate against a per-engine known-good baseline: if <file> is absent it is
                                established from this run (exit 0); if present, exit non-zero when any
                                engine cleans fewer clips than its baseline (a command-pipeline
                                regression) or the clip count changed (re-baseline). Ground truth, not
                                an absolute pass-rate — the clips are transcription-sensitive.
      --samples-parity <dir>  Verify the in-memory samples transcription path matches the WAV path for
                              every installed sample-capable engine over the *.wav files in <dir> (P2-1).
                              Exits non-zero on any mismatch. Honors --engines.
      --list-engines          Print each shipped catalog engine and whether it is installed
                              (installed / missing / system), then exit — coverage for the release gate.
      --capture-probe         Drive the real capture path (record → drain → teardown) and score the
                              result for dropped/corrupted audio you cannot hear. Feed a pure tone into
                              the input (e.g. via a loopback/Aggregate device); reports SINAD, glitches,
                              ring-drop and CoreAudio-overload counts. Needs Microphone permission.
        --seconds <n>           Record for n seconds (default 5).
        --tone <hz>             Expected input tone in Hz (default 440).
      --keep-capture <dir>    Save a copy of each committed capture WAV to <dir> for offline inspection
                              (off unless set). Rides `open --args`, so it survives a LaunchServices
                              launch (which Microphone TCC needs) where an env var would not. Equivalent
                              env var: KEYSCRIBE_KEEP_CAPTURE=<dir>.
      --config-dir <path>     Use <path> for config/modes/history instead of Application Support
                              (downloaded models stay shared). Pair with --first-run to test
                              onboarding without touching your real configuration.
      --first-run             Replay the full onboarding wizard, ignoring the completion flag.
      --setup-permissions     Present the permissions-only setup flow.
    """)
    exit(0)
}

// Dev flag: `--config-dir <path>` points config/modes/history at a throwaway directory (downloaded
// models stay shared). Parsed first so every path below — including --reset — honors it. Pair with
// --first-run to replay onboarding against a clean sandbox without touching the real configuration.
if let i = CommandLine.arguments.firstIndex(of: "--config-dir"), i + 1 < CommandLine.arguments.count {
    KeyScribePaths.configDirOverride = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
}

// Dev flag: `--keep-capture <dir>` mirrors the KEYSCRIBE_KEEP_CAPTURE env var. It exists because a
// LaunchServices launch (`open ...`) — required for microphone TCC to attribute to the app rather than
// the launching terminal — starts with a clean environment, so a shell env var never reaches the app.
// A flag rides `open --args`, so `open KeyScribe.app --args --keep-capture <dir>` both keeps Mic working
// and retains capture WAVs. Feeds the same env the read path already uses (CaptureArchive reads it live).
if let i = CommandLine.arguments.firstIndex(of: "--keep-capture"), i + 1 < CommandLine.arguments.count {
    setenv("KEYSCRIBE_KEEP_CAPTURE", CommandLine.arguments[i + 1], 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--reset") {
    let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
    guard let target = ResetTarget(rawValue: arg) else {
        FileHandle.standardError.write(Data("""
        Usage: KeyScribe --reset <target>
          onboarding   Clear the first-run flag (replays the wizard only if a TCC permission is missing).
          modes        Re-seed the starter modes (discards edits to default modes).
          config       Wipe config/modes/fragments but keep downloaded models, and clear the first-run flag.
          permissions  Remove the app's TCC grants (Microphone, Accessibility, Automation) so macOS re-prompts.
          all          Wipe the whole support dir and clear the first-run flag (shared models are kept).
          eraseAll     Like all, plus erase the variant's BYOK Keychain keys (TCC grants kept).\n
        """.utf8))
        exit(2)
    }
    let actions = ResetTool(supportDir: KeyScribePaths.supportDir, defaults: .standard).run(target)
    for line in actions { print(line) }
    if target != .modes && target != .permissions {
        let granted = Permissions.microphoneStatus() == .granted
            && Permissions.accessibilityStatus() == .granted
        if granted {
            print("Note: TCC permissions are all granted, so the first-run wizard will be skipped. "
                + "To replay it, revoke a permission first: tccutil reset Accessibility com.keyscribe.app")
        }
    }
    exit(0)
}

// Dev tool: `--reload-stress <dir>` reproduces the Frugal-memory "No speech detected" — cold-reload a
// model N times and transcribe a known non-silent clip, failing if any reload returns empty.
if let i = CommandLine.arguments.firstIndex(of: "--reload-stress"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var only: Set<String>?
    if let e = CommandLine.arguments.firstIndex(of: "--engines"), e + 1 < CommandLine.arguments.count {
        only = Set(CommandLine.arguments[e + 1].split(separator: ",").map(String.init))
    }
    var iterations = 12
    if let n = CommandLine.arguments.firstIndex(of: "--iterations"), n + 1 < CommandLine.arguments.count {
        iterations = Int(CommandLine.arguments[n + 1]) ?? iterations
    }
    var bias: [String] = []
    if let b = CommandLine.arguments.firstIndex(of: "--bias"), b + 1 < CommandLine.arguments.count {
        bias = CommandLine.arguments[b + 1].split(separator: ",").map(String.init)
    }
    let done = DispatchSemaphore(value: 0)
    let ok = Atomic<Bool>(false)
    Task.detached {
        let passed = await ReloadStressRunner.run(dir: dir, only: only, iterations: iterations, biasTerms: bias)
        ok.store(passed, ordering: .relaxed)
        done.signal()
    }
    done.wait()
    exit(ok.load(ordering: .relaxed) ? 0 : 1)
}

// Diagnostic: print every shipped catalog engine and whether it is installed — so a release gate can
// report which engines it will actually exercise vs. which are missing (and therefore untested).
if CommandLine.arguments.contains("--list-engines") {
    let installed = ModelInstallStore.installedIds()
    for e in SpeechModelCatalog.all {
        let state = e.systemManaged ? "system" : (installed.contains(e.id) ? "installed" : "missing")
        print("\(e.id)\t\(state)")
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--benchmark"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var only: Set<String>?
    if let e = CommandLine.arguments.firstIndex(of: "--engines"), e + 1 < CommandLine.arguments.count {
        only = Set(CommandLine.arguments[e + 1].split(separator: ",").map(String.init))
    }
    let raw = CommandLine.arguments.contains("--raw")
    let fuzzy = CommandLine.arguments.contains("--fuzzy")
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await BenchmarkRunner.run(dir: dir, only: only, raw: raw, fuzzy: fuzzy)
        done.signal()
    }
    done.wait()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--commands-check"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var only: Set<String>?
    if let e = CommandLine.arguments.firstIndex(of: "--engines"), e + 1 < CommandLine.arguments.count {
        only = Set(CommandLine.arguments[e + 1].split(separator: ",").map(String.init))
    }
    var baselineURL: URL?
    if let b = CommandLine.arguments.firstIndex(of: "--baseline"), b + 1 < CommandLine.arguments.count {
        baselineURL = URL(fileURLWithPath: CommandLine.arguments[b + 1])
    }
    let done = DispatchSemaphore(value: 0)
    let ok = Atomic<Bool>(true)
    Task.detached {
        let report = await CommandCheckRunner.run(dir: dir, only: only)
        // No --baseline: informational only (exit 0). With --baseline: gate. If the file is absent,
        // establish it from this run (a known-good baseline) and pass; otherwise diff and fail on any
        // per-engine drop or a stale (corpus-changed) baseline.
        if let url = baselineURL {
            if let data = try? Data(contentsOf: url),
               let baseline = try? JSONDecoder().decode(CommandCheckBaseline.self, from: data) {
                let diff = report.diff(against: baseline)
                if diff.passed {
                    print("\nPASS — every engine held its baseline (\(diff.ranCount) ran).")
                } else if diff.ranCount == 0 {
                    print("\nFAIL — no engine could run the checks (models/corpus missing).")
                } else {
                    for r in diff.regressions {
                        print("\nFAIL — \(r.id) regressed: \(r.current)/\(r.total) clean, baseline was \(r.baseline).")
                    }
                    if !diff.stale.isEmpty {
                        print("\nFAIL — baseline stale for \(diff.stale.joined(separator: ", ")) (clip count changed). Re-baseline: delete \(url.lastPathComponent) and re-run.")
                    }
                }
                ok.store(diff.passed, ordering: .relaxed)
            } else {
                let baseline = CommandCheckBaseline.from(report)
                if let data = try? JSONEncoder().encode(baseline) {
                    try? data.write(to: url)
                    print("\nBASELINE ESTABLISHED → \(url.path) (\(baseline.engines.count) engines). Re-run to gate against it.")
                }
                ok.store(!baseline.engines.isEmpty, ordering: .relaxed)
            }
        }
        done.signal()
    }
    done.wait()
    exit(ok.load(ordering: .relaxed) ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--samples-parity"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var only: Set<String>?
    if let e = CommandLine.arguments.firstIndex(of: "--engines"), e + 1 < CommandLine.arguments.count {
        only = Set(CommandLine.arguments[e + 1].split(separator: ",").map(String.init))
    }
    let done = DispatchSemaphore(value: 0)
    let ok = Atomic<Bool>(false)
    Task.detached {
        let passed = await SamplesParityRunner.run(dir: dir, only: only)
        ok.store(passed, ordering: .relaxed)
        done.signal()
    }
    done.wait()
    exit(ok.load(ordering: .relaxed) ? 0 : 1)
}

if CommandLine.arguments.contains("--capture-probe") {
    var seconds = 5.0
    if let s = CommandLine.arguments.firstIndex(of: "--seconds"), s + 1 < CommandLine.arguments.count {
        seconds = Double(CommandLine.arguments[s + 1]) ?? seconds
    }
    var tone = 440.0
    if let t = CommandLine.arguments.firstIndex(of: "--tone"), t + 1 < CommandLine.arguments.count {
        tone = Double(CommandLine.arguments[t + 1]) ?? tone
    }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await CaptureProbeRunner.run(seconds: seconds, toneHz: tone)
        done.signal()
    }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.mainMenu = EditMenu.make()
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
