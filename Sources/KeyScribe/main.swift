import AppKit
import Foundation

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
                              (manifest.json), then exit. Honors --engines.
      --capture-probe         Drive the real capture path (record → drain → teardown) and score the
                              result for dropped/corrupted audio you cannot hear. Feed a pure tone into
                              the input (e.g. via a loopback/Aggregate device); reports SINAD, glitches,
                              ring-drop and CoreAudio-overload counts. Needs Microphone permission.
        --seconds <n>           Record for n seconds (default 5).
        --tone <hz>             Expected input tone in Hz (default 440).
      KEYSCRIBE_KEEP_CAPTURE=<dir>  Env var: save a copy of each committed capture WAV to <dir> for
                              offline inspection (off unless set).
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

// Headless dev mode: `KeyScribe --reset <onboarding|modes|config|all>` clears local state and exits.
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

// Headless dev mode: `KeyScribe --benchmark <dir>` runs the STT benchmark and exits without launching
// the menu-bar app. Anything else is a normal app launch.
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

// Headless dev mode: `KeyScribe --commands-check <dir>` exercises every spoken command across every
// installed engine on recorded audio, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--commands-check"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var only: Set<String>?
    if let e = CommandLine.arguments.firstIndex(of: "--engines"), e + 1 < CommandLine.arguments.count {
        only = Set(CommandLine.arguments[e + 1].split(separator: ",").map(String.init))
    }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await CommandCheckRunner.run(dir: dir, only: only)
        done.signal()
    }
    done.wait()
    exit(0)
}

// Headless dev mode: `KeyScribe --capture-probe` drives the real capture path and scores the recording for
// dropped/corrupted audio (feed a pure tone into the input via a loopback device), then exits.
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
