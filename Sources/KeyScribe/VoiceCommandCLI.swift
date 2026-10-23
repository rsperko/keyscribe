import Foundation
import KeyScribeKit

@MainActor
enum VoiceCommandCLI {
    static func run(transcript: String, dryRun: Bool) async -> Int32 {
        let system = LiveVoiceCommandSystem.shared
        let runner = VoiceCommandRunner(system: system)
        let commands = VoiceCommandStore.loadOrDefault(supportDir: KeyScribePaths.supportDir)
        let config = ConfigCache(supportDir: KeyScribePaths.supportDir)
        config.voiceCommandsEnabled = true
        let readAs = config.resolved.voiceCommandText(heard: transcript)
        let resolution = await runner.resolve(readAs, places: commands.places, scripts: commands.scripts)
        print("heard:      \(transcript)")
        if readAs != transcript { print("read as:    \(readAs)") }
        print("resolution: \(describe(resolution, system: system))")
        guard case .action = resolution else { return 1 }
        if dryRun { return 0 }
        switch await runner.run(resolution, origin: nil) {
        case .done(let summary, let command):
            print("ran:        \(summary)")
            print("command:    \(command)")
            return 0
        case .started(let summary, let command):
            print("started:    \(summary) (still running)")
            print("command:    \(command)")
            return 0
        case .failed(let message, _, _, _):
            print("failed:     \(message)")
            return 1
        case .needsChoice, .abandoned:
            return 1
        }
    }

    private static func describe(_ resolution: VoiceCommandResolution, system: LiveVoiceCommandSystem) -> String {
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
        case .browserNotAllowed(let browser): return "not allowed to control \(browser)"
        case .scriptNeedsText(let name): return "\(name) needs words after its name"
        case .takesNoText(let name): return VoiceCommandRunner.takesNoTextMessage(name)
        case .scriptNotFound(let target): return "no script or shortcut matches \u{201C}\(target)\u{201D}"
        case .action(let action):
            return "\(action.summary(appName: system.appName(forBundleId:))) — \(action.detail(appName: system.appName(forBundleId:)))"
        }
    }
}
