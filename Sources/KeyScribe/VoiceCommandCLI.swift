import Foundation
import KeyScribeKit

@MainActor
enum VoiceCommandCLI {
    // Preview only: any program on the machine can start this binary, so it must never be a way to make
    // the app open apps or run the user's scripts. Only the person's own shortcut runs a command.
    static func run(
        transcript: String, supportDir: URL = KeyScribePaths.supportDir,
        system: any VoiceCommandSystem = LiveVoiceCommandSystem.shared
    ) async -> Int32 {
        let findsInApps: Bool
        if case .loaded(let settings) = SettingsStore.load(supportDir: supportDir) {
            findsInApps = settings.features.isEnabled(.findInApps)
        } else {
            findsInApps = false
        }
        let runner = VoiceCommandRunner(system: system, findsInApps: { findsInApps }, isPreview: true)
        let commands = VoiceCommandStore.loadOrDefault(supportDir: supportDir)
        let config = ConfigCache(supportDir: supportDir)
        config.voiceCommandsEnabled = true
        let readAs = config.resolved.voiceCommandText(heard: transcript)
        let resolution = await runner.resolve(readAs, places: commands.places, scripts: commands.scripts)
        print("heard:      \(transcript)")
        if readAs != transcript { print("read as:    \(readAs)") }
        print("resolution: \(describe(resolution, system: system))")
        guard case .action = resolution else { return 1 }
        return 0
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
            return "spoken, this asks \u{201C}\(choice.title)\u{201D} and you answer with a number. To preview one match, give more of the name:\(rows.joined())"
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
