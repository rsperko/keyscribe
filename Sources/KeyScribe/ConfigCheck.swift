import Foundation
import KeyScribeKit

@MainActor
enum ConfigCheck {
    nonisolated static let flag = "--check-config"

    static func run(supportDir: URL = KeyScribePaths.supportDir, output: (String) -> Void = { print($0) }) -> Int32 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: supportDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            output("No configuration folder at \(supportDir.path)")
            return 1
        }
        let config = ConfigCache(supportDir: supportDir, readOnly: true)
        var problems: [String] = []
        switch SettingsStore.load(supportDir: supportDir) {
        case .loaded(let settings):
            config.voiceCommandsEnabled = settings.features.isEnabled(.voiceCommands)
            config.agentsEnabled = settings.features.isEnabled(.agents)
            config.answersEnabled = settings.features.isEnabled(.askAboutSelection)
        case .failed(let error):
            problems.append(line(.unreadable(SettingsStore.fileName, error: error, recovery: .defaults)))
        case .absent:
            break
        }
        problems += (config.fileFailures + config.fileWarnings).map(line)
        let registered = VoiceCommandTriggers.guarded(config.modes)
        let stored = Dictionary(config.storedModes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for mode in config.modes {
            let file = "modes/\(ModeStore.fileName(for: mode.id))"
            for field in mode.invalidRoutingPatternFields {
                problems.append("\(file) — \(field) is not a valid pattern, so it never matches")
            }
            guard mode.enabled else { continue }
            if mode.runsVoiceCommands, let original = stored[mode.id] {
                for trigger in original.triggerKeys where !mode.triggerKeys.contains(trigger) {
                    problems.append("\(file) — shortcut \(trigger.key) is also another mode's, so it never starts Voice Commands")
                }
            }
            if mode.lacksConnection(in: config.connections), let rewrite = mode.aiRewrite {
                problems.append(rewrite.connection.isEmpty
                    ? "\(file) — [ai_rewrite] names no connection"
                    : "\(file) — [ai_rewrite] connection \"\(rewrite.connection)\" is not in \(ConnectionStore.fileName)")
            }
            if let conflict = TriggerKeyConflicts.conflict(for: mode, in: registered), let effect = effect(of: conflict.kind) {
                problems.append("\(file) — shortcut \(conflict.triggerKey) \(effect) \"\(conflict.modeName)\" (\(conflict.key))")
            }
        }
        guard !problems.isEmpty else {
            output("OK")
            return 0
        }
        problems.forEach(output)
        return 1
    }

    private static func effect(of kind: TriggerKeyConflict.Kind) -> String? {
        switch kind {
        case .collision: "is also used, in an overlapping context, by"
        case .actionCollision: "starts recording in one mode and stops it in another:"
        case .unreachable, .triggerUnreachable: "never fires: the same press is already claimed by"
        case .masking, .maskedBy: nil
        }
    }

    private static func line(_ issue: ConfigFileIssue) -> String {
        issue.line(naming: issue.relativePath)
    }
}
