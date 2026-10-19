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
        let readAs = config.resolved.voiceCommandText(heard: transcript, scripts: commands.scripts)
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
        case .failed(let message, _):
            print("failed:     \(message)")
            return 1
        case .abandoned:
            return 1
        }
    }

    private static func describe(_ resolution: VoiceCommandResolution, system: LiveVoiceCommandSystem) -> String {
        switch resolution {
        case .notACommand: return "not a command"
        case .noMatch(let target): return "no match for \u{201C}\(target)\u{201D}"
        case .ambiguous(let names): return "ambiguous: \(names.joined(separator: ", "))"
        case .needsTabs: return "needs browser tabs"
        case .browserNotAllowed(let browser): return "not allowed to control \(browser)"
        case .scriptNeedsText(let name): return "\(name) needs words after its name"
        case .action(let action):
            return "\(action.summary(appName: system.appName(forBundleId:))) — \(action.detail(appName: system.appName(forBundleId:)))"
        }
    }
}
