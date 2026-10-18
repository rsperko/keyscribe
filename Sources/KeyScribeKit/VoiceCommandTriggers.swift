import Foundation

public enum VoiceCommandTriggers {
    public static func clash(for mode: Mode, in modes: [Mode]) -> Mode? {
        guard mode.enabled else { return nil }
        let others = modes.filter { $0.id != mode.id && $0.enabled && ($0.runsVoiceCommands || mode.runsVoiceCommands) }
        return others.first { other in
            mode.triggerKeys.contains { shares($0.key, with: other) }
        }
    }

    public static func guarded(_ modes: [Mode]) -> [Mode] {
        modes.map { mode in
            guard mode.runsVoiceCommands, mode.enabled else { return mode }
            let others = modes.filter { $0.id != mode.id && $0.enabled }
            var guardedMode = mode
            guardedMode.triggerKeys.removeAll { trigger in others.contains { shares(trigger.key, with: $0) } }
            return guardedMode
        }
    }

    private static func shares(_ key: String, with other: Mode) -> Bool {
        guard let descriptor = try? KeyDescriptor(parsing: key) else { return false }
        return other.triggerKeys.contains { trigger in
            (try? KeyDescriptor(parsing: trigger.key)).map(descriptor.collides) ?? false
        }
    }
}
