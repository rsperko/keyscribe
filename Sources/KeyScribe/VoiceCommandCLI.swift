import Foundation
import KeyScribeKit

@MainActor
enum VoiceCommandCLI {
    static func run(
        transcript: String, dryRun: Bool, supportDir: URL = KeyScribePaths.supportDir,
        system: any VoiceCommandSystem = LiveVoiceCommandSystem.shared
    ) async -> Int32 {
        if !dryRun, let refusal = refusal(supportDir: supportDir) {
            print("not run:    \(refusal)")
            return 1
        }
        let findsInApps: Bool
        if case .loaded(let settings) = SettingsStore.load(supportDir: supportDir) {
            findsInApps = settings.features.isEnabled(.findInApps)
        } else {
            findsInApps = false
        }
        let runner = VoiceCommandRunner(system: system, findsInApps: { findsInApps }, isPreview: dryRun)
        let commands = VoiceCommandStore.loadOrDefault(supportDir: supportDir)
        let config = ConfigCache(supportDir: supportDir)
        config.voiceCommandsEnabled = true
        let readAs = config.resolved.voiceCommandText(heard: transcript)
        let resolution = await runner.resolve(readAs, places: commands.places, scripts: commands.scripts)
        print("heard:      \(transcript)")
        if readAs != transcript { print("read as:    \(readAs)") }
        print("resolution: \(describe(resolution, system: system))")
        guard case .action = resolution else { return 1 }
        if dryRun { return 0 }
        switch await runner.run(resolution, origin: nil) {
        case .done(let summary, let command, let report):
            print("ran:        \(summary)")
            print("command:    \(command)")
            if let report { print("reported:   \(report.text)") }
            return 0
        case .started(let summary, let command):
            print("started:    \(summary) (still running)")
            print("command:    \(command)")
            return 0
        case .failed(let message, _, _, _):
            print("failed:     \(message)")
            return 1
        case .needsChoice(let pending):
            let rows = pending.rows.map { "\n  \($0.number). \($0.name)" }.joined()
            print("asks:       \(pending.choice.title)\(rows)")
            return 1
        case .abandoned:
            return 1
        }
    }

    static func refusal(supportDir: URL) -> String? {
        let hint = "Add --dry-run to check a phrase without running it."
        switch SettingsStore.load(supportDir: supportDir) {
        case .loaded(let settings) where settings.features.isEnabled(.voiceCommands):
            return nil
        case .failed(let error):
            return "\(SettingsStore.fileName) has an error (\(error.summary)), so Voice Commands stays off. \(hint)"
        case .loaded, .absent:
            return "Voice Commands is turned off in Settings. \(hint)"
        }
    }

    private static func describe(_ resolution: VoiceCommandResolution, system: any VoiceCommandSystem) -> String {
        switch resolution {
        case .notACommand: return "not a command"
        case .noMatch(let target): return VoiceCommandRunner.noMatchMessage(target)
        case .noTabMatch(let target, let browser):
            return VoiceCommandRunner.noTabMatchMessage(target, browser: browser.map { system.appName(forBundleId: $0) ?? $0 })
        case .needsWindows, .windowsIncomplete: return VoiceCommandRunner.windowsIncompleteMessage
        case .windowsNeedAccessibility: return VoiceCommandRunner.windowsNeedAccessibilityMessage
        case .ambiguous(let choice):
            guard choice.isOffered else { return choice.tooManyMessage }
            let rows = choice.candidates.enumerated().map { index, candidate in
                "\n  \(index + 1). \(candidate.name) \u{00B7} \(candidate.detail(appName: system.appName(forBundleId:), among: choice.candidates))"
            }
            return "spoken, this asks \u{201C}\(choice.title)\u{201D} and you answer with a number; the command line cannot answer, so give more of the name to run one directly:\(rows.joined())"
        case .unavailable(let name): return VoiceCommandRunner.unavailableMessage(name)
        case .needsTabs: return "needs browser tabs"
        case .needsSidebar(let app): return "needs \(system.appName(forBundleId: app) ?? app)\u{2019}s sidebar"
        case .sidebarUnreadable(let app, let problem):
            return "could not read \(system.appName(forBundleId: app) ?? app)\u{2019}s sidebar (\(problem))"
        case .noSidebarMatch(let target, let app):
            return VoiceCommandRunner.noSidebarMatchMessage(target, app: system.appName(forBundleId: app) ?? app)
        case .browserNotAllowed(let browser): return "not allowed to control \(browser)"
        case .scriptNeedsText(let name): return "\(name) needs words after its name"
        case .takesNoText(let name): return VoiceCommandRunner.takesNoTextMessage(name)
        case .scriptNotFound(let target): return "no script or shortcut matches \u{201C}\(target)\u{201D}"
        case .action(let action):
            return "\(action.summary(appName: system.appName(forBundleId:))) — \(action.detail(appName: system.appName(forBundleId:)))"
        }
    }
}
