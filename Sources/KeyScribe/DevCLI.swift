import Foundation
import KeyScribeKit
import Synchronization

// The development / administration CLI surface. Lives in the library (not the executable) so a
// downstream host that supplies its own entry point inherits every flag through one call.
public enum DevCLI {
    // Handles any dev/admin flag present in the process arguments and exits; returns only when the
    // invocation is a plain menu-bar app launch.
    public static func handleFlags(codingAgents: CodingAgentIntegrations = .builtIn) {
        // `--help` / `-h`: print the CLI surface and exit. No arguments launches the menu-bar app.
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
              --alias-discovery <path> Measure the History phrase finder that suggests replacements for a dictionary
                                      word, then exit. <path> is a recordings dir (manifest.json; each clip is
                                      transcribed by every installed engine) or a JSONL of {heard, reference,
                                      terms} transcripts. Each clip's terms are the dictionary; the reference
                                      text labels which Heard phrases were misses. Reports occurrence and form
                                      recall, wrong suggestions per 100 negatives, and top-three precision.
                --engines <a,b,...>     Limit a recordings run to these engine ids.
                --threshold <x>         Score cutoff (default \(AliasDiscovery.defaultThreshold)).
                --cohort <a,b,...>      Limit a JSONL run to rows whose `cohort` is listed.
              --rewrite-eval <dir>    Run the LLM rewrite-prompt eval over the text cases in <dir>/cases.json
                                      against a saved BYOK connection, score each output with the corpus's
                                      deterministic checks, and print a baseline-vs-variant report split by
                                      scenario tag. Writes attempts to <dir>/results/ (gitignored). Headless:
                                      network only, no mic/insertion. Exits non-zero on transport errors.
                --connection <id>       Saved connection to call (required when more than one is saved).
                --variants <a,b,...>    Limit to these prompt variants (default: all, including baseline).
                --repeat <n>            Attempts per case × variant (default 1).
                --raw                   Emit each model output as RAW <variant> <case> <verdict> <text>.
              --warmup-probe          Per installed engine: load time, then the bundled warm-up clip transcribed
                                      three times, so the first-after-load cost the warm-up clip pays is visible.
                                      Honors --engines. Run the built app, which bundles the clip.
              --vad-probe <dir>       Run the no-speech VAD gate over the recordings in <dir> (manifest.json)
                                      and exit: per clip verdict (speech/noSpeech), max probability, and gate
                                      latency, plus the minimum take-level max probability over speech clips
                                      (the safety margin above the gate threshold). Downloads the VAD model if
                                      missing. Headless: no mic/insertion. Add --chunks to dump each clip's
                                      per-chunk probability vector plus how many chunks clear the threshold and
                                      the longest consecutive run — the inputs a duration-aware rule is tuned on.
                                      A clip the model did not score is marked model=false.
                --rate <hz>             Hand the gate audio at this capture rate, as an engine recording at it would
                                        (default 16000).
                --wav-only              Hand the gate no samples, as a WAV-only engine does.
                --cold                  Skip the model prewarm, so the first clip pays the load.
                --deadline <s>          Override the gate's time limit, to time a clip past it.
              --voice-sweep <file>    Synthesize each line of <file> with the installed natural voice, write every take
                                      as a WAV plus results.jsonl (length, level, rejected-audio checks, stage timings,
                                      and each take's similarity to the line's first take), then exit. Plays nothing.
                                      For comparing repeat takes and compute routes; similarity only points at takes
                                      to listen to. Keep private text out of committed files.
                --out <dir>             Where to write the takes (default: a new folder in the temporary directory).
                --takes <n>             Takes per line (default 2).
                --route <r>             default, gpu or cpu: where the noise and tail stages run (default: this OS's).
                --voice <id>            Speaker (default: the recommended one).
                --stop-first            Before each line, start it and cancel after --stop-after ms, then go at once.
                --stop-after <ms>       Default 150.
                --overlap               Make each line's takes at the same time on one loaded voice.
              --samples-parity <dir>  Verify the in-memory samples transcription path matches the WAV path for
                                      every installed sample-capable engine over the *.wav files in <dir> (P2-1).
                                      Exits non-zero on any mismatch. Honors --engines.
              --diagnose              Print a redaction-safe snapshot of this install (version, permissions,
                                      speech engine, each mode's delivery settings, and the most recent
                                      dictation outcomes) and exit. Paste it into a bug report. Contains no
                                      transcript text, clipboard contents, or API keys.
                --dictations <n>        How many recent dictation outcomes to include (default 10, 0 for none).
              --voice-command <text>  Resolve <text> as a spoken voice command ("switch to ghostty", "go back")
                                      against this Mac's running and installed apps, open browser tabs, and
                                      the saved commands, print what it resolved to, and exit. Never opens an
                                      app or runs a script or shortcut: only your shortcut runs commands.
                                      Also lists any rule or file it read that is ignored, and why. Exits
                                      non-zero when it does not resolve.
              --windows-probe         List every regular app's Accessibility windows (subrole, id, minimized,
                                      whether a document is reported, title) with per-app read latency, then
                                      exit. Read-only; prints window titles to this terminal only.
                --focus <pid>:cg:<id>   Instead, bring that one window forward the way a voice command does.
              --front-probe           Print the terminal pane in front (app, tty, multiplexers, the processes on
                                      that pane) and how long the read took, then exit. Read-only; may ask for
                                      Automation access to the front terminal.
                --after <s>             Wait this long before the first read.
                --samples <n>           Read n times, a second apart (default 1).
              --route-probe <pid>     Print how Open would reach the coding agent running as <pid> (its process
                                      chain, each multiplexer and terminal step) and the places it reads, then
                                      exit. Runs each route's planning and place reads (the built-in ones only
                                      list), never a step of the plan, a terminal's place script, or a place
                                      source with its own reader. Exits 1 when <pid> is not running.
                --read-places           Also read the agent's place the way the app does: through every place
                                        source and the terminal's place script. May ask for Automation access.
                --agent <id>            The agent id a place source matches by: the id the agent's connector sends
                                        in its hello, which for the built-in agents is their command name
                                        (default: the process name).
                --session <id>          The agent's own conversation id, for a place source that matches by it.
              --list-engines          Print each shipped catalog engine and whether it is installed
                                      (installed / missing / system), then exit — coverage for the release gate.
              --mlx-smoke             Run a tiny MLX computation on the GPU, then exit 0. A missing or unloadable
                                      shader library terminates the process instead — the build and release gate.
              --capture-probe         Drive the real capture path (record → drain → teardown) and score the
                                      result for dropped/corrupted audio you cannot hear. Feed a pure tone into
                                      the input (e.g. via a loopback/Aggregate device); reports SINAD, glitches,
                                      ring-drop and CoreAudio-overload counts. Needs Microphone permission.
              --hud-preview <state>  Render a stable HUD fixture for visual review without starting dictation.
                                      States: ready, recording, loading-model, transcribing, rewriting,
                                      redacted-rewrite, rewriting-with-local-transcript, inserted, copied,
                                      no-speech, failed, rewrite-fallback, rewrite-fallback-reasoning,
                                      rewrite-fallback-copied, reasoning-notice, microphone-error,
                                      accessibility-error (HUDPreview.names lists every fixture).
              --hud-appearance <a>   With --hud-preview: render under system, opposite, light, or dark.
                --seconds <n>           Record for n seconds (default 5).
                --tone <hz>             Expected input tone in Hz (default 440).
              --mem-probe             Measure each installed engine's in-memory footprint (phys_footprint) on the
                                      real load/transcribe paths, reporting per-phase deltas. No mic/network. Run
                                      one engine at a time for clean absolute numbers. Honors --engines.
                --clip <wav>            Transcribe this recording instead of a synthesized tone (more representative
                                        working set).
                --seconds <n>           Length of the synthesized probe tone (default 5).
              --keep-capture <dir>    Save a copy of each committed capture WAV to <dir> for offline inspection
                                      (off unless set). Rides `open --args`, so it survives a LaunchServices
                                      launch (which Microphone TCC needs) where an env var would not. Equivalent
                                      env var: KEYSCRIBE_KEEP_CAPTURE=<dir>.
              --apple-model <model>   Run the Apple Speech entry on a specific Apple model: speech or dictation.
                                      For measuring the Apple Dictation fallback on a Mac that would otherwise
                                      use Apple Speech; applies to the app and to --benchmark/--commands-check.
                                      A model this Mac or language cannot run still falls back. Equivalent env
                                      var: KEYSCRIBE_APPLE_MODEL=<model>.
              --config-dir <path>     Use <path> for config/modes/history instead of Application Support
                                      (downloaded models stay shared). Pair with --first-run to test
                                      onboarding without touching your real configuration.
              --first-run             Replay the full onboarding wizard, ignoring the completion flag.
              --setup-permissions     Present the permissions-only setup flow.
              --resume-onboarding     Resume the full onboarding wizard after the permission relaunch
                                      (set automatically by that relaunch; not meant to be run by hand).
              --open-settings         Open the Settings window on launch (used by the UI test suite to land
                                      in a known state instead of driving the status-bar menu).
            """)
            exit(0)
        }

        // `--config-dir <path>` points config/modes/history at a throwaway directory (models stay shared). Parsed
        // first so every path below — including --reset — honors it.
        if let i = CommandLine.arguments.firstIndex(of: "--config-dir"), i + 1 < CommandLine.arguments.count {
            KeyScribePaths.configDirOverride = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        }

        // `--keep-capture <dir>` mirrors the KEYSCRIBE_KEEP_CAPTURE env var. A LaunchServices launch (`open ...`,
        // required so microphone TCC attributes to the app not the terminal) starts with a clean environment, so a
        // shell env var never reaches the app; a flag rides `open --args`. Sets the same env the read path uses.
        if let i = CommandLine.arguments.firstIndex(of: "--keep-capture"), i + 1 < CommandLine.arguments.count {
            setenv("KEYSCRIBE_KEEP_CAPTURE", CommandLine.arguments[i + 1], 1)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--apple-model") {
            let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
            guard let model = AppleSpeechModel(argument: arg) else {
                FileHandle.standardError.write(Data("""
                Usage: KeyScribe --apple-model <model>
                  speech     Apple Speech (the default wherever this Mac and language support it).
                  dictation  Apple Dictation, the compatibility-mode fallback.\n
                """.utf8))
                exit(2)
            }
            setenv(AppleSpeechModel.overrideEnvironmentKey, model.rawValue, 1)
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

        // Every CLI runner below downloads weights without ever reaching AppDelegate, so the exclusion is applied
        // here — after --reset, which would delete the dir again.
        KeyScribePaths.ensureModelsDir()

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

        // Lets a release gate confirm which shipped catalog engines it will actually exercise vs. which are
        // missing (untested).
        if CommandLine.arguments.contains("--diagnose") {
            var limit = DiagnosticsCollector.defaultDictationLimit
            if let i = CommandLine.arguments.firstIndex(of: "--dictations"), i + 1 < CommandLine.arguments.count,
                let parsed = Int(CommandLine.arguments[i + 1]), parsed >= 0 {
                limit = parsed
            }
            print(DiagnosticsCollector.collect(dictationLimit: limit).render(), terminator: "")
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--voice-command"), i + 1 < CommandLine.arguments.count {
            let transcript = CommandLine.arguments[i + 1]
            Task { @MainActor in
                exit(await VoiceCommandCLI.run(transcript: transcript))
            }
            dispatchMain()
        }

        let resolvedSurfaces = {
            do { return try codingAgents.surfaces.resolve() } catch {
                print("coding agent integrations do not resolve: \(error)")
                exit(1)
            }
        }

        if let i = CommandLine.arguments.firstIndex(of: "--route-probe") {
            let given = { (flag: String) -> String?? in
                switch RouteProbe.option(flag, in: CommandLine.arguments) {
                case .absent: .some(nil)
                case .value(let value): .some(value)
                case .missing: nil
                }
            }
            guard i + 1 < CommandLine.arguments.count, let pid = RouteProbe.pid(CommandLine.arguments[i + 1]),
                  let session = given("--session"), let agentName = given("--agent")
            else {
                FileHandle.standardError.write(Data("Usage: \(Branding.appName) --route-probe <pid> [--read-places [--agent <kind>] [--session <id>]]\n".utf8))
                exit(2)
            }
            let surfaces = resolvedSurfaces()
            let facts = SystemTerminalFacts(environmentKeys: surfaces.environmentKeys)
            guard let lines = RouteProbe.report(agent: pid, facts: facts, surfaces: surfaces) else {
                FileHandle.standardError.write(Data("No process \(pid) is running.\n".utf8))
                exit(1)
            }
            guard CommandLine.arguments.contains("--read-places") else {
                for line in lines { print(line) }
                exit(0)
            }
            let agent = agentName ?? facts.process(pid)?.name ?? ""
            let sources = codingAgents.placeSources
            Task { @MainActor in
                let reader = AgentRuntime.places(surfaces: surfaces, sources: sources.map { $0() })
                for line in lines where line != RouteProbe.skipped { print(line) }
                for line in await PlaceProbe.lines(pid: pid, agent: agent, session: session ?? "", reader: reader) { print(line) }
                exit(0)
            }
            dispatchMain()
        }

        if CommandLine.arguments.contains("--front-probe") {
            let args = CommandLine.arguments
            let value = { (flag: String) in args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } }
            let surfaces = resolvedSurfaces()
            Task { @MainActor in
                exit(await FrontProbe.run(after: value("--after") ?? 0, samples: Int(value("--samples") ?? 1), surfaces: surfaces))
            }
            dispatchMain()
        }

        if CommandLine.arguments.contains("--windows-probe") {
            let args = CommandLine.arguments
            let focus: String? = args.firstIndex(of: "--focus").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            Task { @MainActor in
                if let focus { exit(await WindowsProbe.focus(focus)) }
                exit(WindowsProbe.list())
            }
            dispatchMain()
        }

        if CommandLine.arguments.contains("--list-engines") {
            let installed = ModelInstallStore.installedIds()
            for e in SpeechModelCatalog.all {
                let state = e.systemManaged ? "system" : (installed.contains(e.id) ? "installed" : "missing")
                print("\(e.id)\t\(state)")
            }
            exit(0)
        }

        if CommandLine.arguments.contains("--mlx-smoke") {
            exit(MLXSmoke.run())
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

        if let i = CommandLine.arguments.firstIndex(of: "--rewrite-eval"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            var variants = RewriteEvalVariants.all.map(\.id)
            if let v = CommandLine.arguments.firstIndex(of: "--variants"), v + 1 < CommandLine.arguments.count {
                variants = CommandLine.arguments[v + 1].split(separator: ",").map(String.init)
            }
            var connectionId: String?
            if let c = CommandLine.arguments.firstIndex(of: "--connection"), c + 1 < CommandLine.arguments.count {
                connectionId = CommandLine.arguments[c + 1]
            }
            var repeats = 1
            if let r = CommandLine.arguments.firstIndex(of: "--repeat"), r + 1 < CommandLine.arguments.count {
                repeats = max(1, Int(CommandLine.arguments[r + 1]) ?? 1)
            }
            let raw = CommandLine.arguments.contains("--raw")
            let done = DispatchSemaphore(value: 0)
            let ok = Atomic<Bool>(false)
            Task.detached {
                let passed = await RewriteEvalRunner.run(
                    dir: dir, variantIds: variants, connectionId: connectionId, repeats: repeats, raw: raw)
                ok.store(passed, ordering: .relaxed)
                done.signal()
            }
            done.wait()
            exit(ok.load(ordering: .relaxed) ? 0 : 1)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--alias-discovery"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
                return args[j + 1]
            }
            let path = URL(fileURLWithPath: args[i + 1])
            let only = value("--engines").map { Set($0.split(separator: ",").map(String.init)) }
            let cohorts = value("--cohort").map { Set($0.split(separator: ",").map(String.init)) }
            let threshold = value("--threshold").flatMap(Double.init) ?? AliasDiscovery.defaultThreshold
            let done = DispatchSemaphore(value: 0)
            let ok = Atomic<Bool>(false)
            Task.detached {
                let passed = await AliasDiscoveryRunner.run(path: path, only: only, cohorts: cohorts, threshold: threshold)
                ok.store(passed, ordering: .relaxed)
                done.signal()
            }
            done.wait()
            exit(ok.load(ordering: .relaxed) ? 0 : 1)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--voice-sweep"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            }
            guard let text = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else {
                print("Could not read \(args[i + 1]).")
                exit(1)
            }
            var options = VoiceSweep.Options(
                lines: text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                output: value("--out").map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("voice-sweep-\(UUID().uuidString.prefix(8))"))
            options.takes = value("--takes").flatMap { Int($0) } ?? options.takes
            options.route = value("--route") ?? options.route
            options.voice = value("--voice") ?? options.voice
            options.stopFirst = args.contains("--stop-first")
            options.stopAfter = value("--stop-after").flatMap { Int($0) }.map { .milliseconds($0) } ?? options.stopAfter
            options.overlap = args.contains("--overlap")
            DependencyLogging.configure()
            let done = DispatchSemaphore(value: 0)
            let ok = Atomic<Bool>(true)
            let sweep = options
            Task.detached {
                ok.store(await VoiceSweep.run(sweep), ordering: .relaxed)
                done.signal()
            }
            done.wait()
            exit(ok.load(ordering: .relaxed) ? 0 : 1)
        }

        if CommandLine.arguments.contains("--warmup-probe") {
            let args = CommandLine.arguments
            let only = args.firstIndex(of: "--engines").flatMap { $0 + 1 < args.count ? Set(args[$0 + 1].split(separator: ",").map(String.init)) : nil }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await WarmupProbeRunner.run(only: only)
                done.signal()
            }
            done.wait()
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--vad-probe"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let args = CommandLine.arguments
            let chunks = args.contains("--chunks")
            let wavOnly = args.contains("--wav-only")
            let cold = args.contains("--cold")
            func value(_ flag: String) -> String? {
                args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            }
            let sampleRate = value("--rate").flatMap { Int($0) } ?? 16000
            let deadline = value("--deadline").flatMap { Double($0) }
            let done = DispatchSemaphore(value: 0)
            let ok = Atomic<Bool>(true)
            Task.detached {
                ok.store(await VadProbeRunner.run(
                    dir: dir, chunks: chunks, sampleRate: sampleRate, wavOnly: wavOnly, cold: cold,
                    deadline: deadline), ordering: .relaxed)
                done.signal()
            }
            done.wait()
            exit(ok.load(ordering: .relaxed) ? 0 : 1)
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
                // No --baseline: informational (exit 0). With --baseline: gate — absent file establishes it from
                // this run and passes; present file diffs and fails on any per-engine drop or a stale baseline.
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

        if CommandLine.arguments.contains("--mem-probe") {
            var only: Set<String>?
            if let e = CommandLine.arguments.firstIndex(of: "--engines"), e + 1 < CommandLine.arguments.count {
                only = Set(CommandLine.arguments[e + 1].split(separator: ",").map(String.init))
            }
            var clip: URL?
            if let c = CommandLine.arguments.firstIndex(of: "--clip"), c + 1 < CommandLine.arguments.count {
                clip = URL(fileURLWithPath: CommandLine.arguments[c + 1])
            }
            var seconds = 5.0
            if let s = CommandLine.arguments.firstIndex(of: "--seconds"), s + 1 < CommandLine.arguments.count {
                seconds = Double(CommandLine.arguments[s + 1]) ?? seconds
            }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await MemProbeRunner.run(only: only, clip: clip, seconds: seconds)
                done.signal()
            }
            done.wait()
            exit(0)
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
    }
}
