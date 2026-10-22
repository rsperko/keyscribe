import Foundation

public struct ShortcutMove: Equatable, Sendable {
    public struct Loss: Equatable, Sendable {
        public let before: Mode
        public let after: Mode
        public let removed: [Mode.TriggerKey]
    }

    public let destination: Mode
    public let claimedKey: String
    public let losses: [Loss]

    public var writes: [Mode] { [destination] + losses.map(\.after) }
}

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

    public static func move(_ destination: Mode, claiming keys: [Mode.TriggerKey]? = nil, in modes: [Mode]) -> ShortcutMove? {
        guard destination.enabled else { return nil }
        let claiming = keys ?? destination.triggerKeys
        let claimed = claiming.compactMap { try? KeyDescriptor(parsing: $0.key) }
        let losses: [ShortcutMove.Loss] = modes.compactMap { other in
            guard other.id != destination.id, other.enabled, other.runsVoiceCommands || destination.runsVoiceCommands else { return nil }
            let removed = other.triggerKeys.filter { trigger in
                (try? KeyDescriptor(parsing: trigger.key)).map { key in claimed.contains { $0.collides(with: key) } } ?? false
            }
            guard !removed.isEmpty else { return nil }
            var after = other
            after.triggerKeys.removeAll { removed.contains($0) }
            return ShortcutMove.Loss(before: other, after: after, removed: removed)
        }
        guard !losses.isEmpty,
              let claimedKey = claiming.first(where: { trigger in losses.contains { shares(trigger.key, with: $0.before) } })?.key
        else { return nil }
        return ShortcutMove(destination: destination, claimedKey: claimedKey, losses: losses)
    }

    public static func isShutOut(_ modes: [Mode]) -> Bool {
        guard let commands = modes.first(where: { $0.runsVoiceCommands && $0.enabled }), !commands.triggerKeys.isEmpty else { return false }
        return guarded(modes).first { $0.id == commands.id }?.triggerKeys.isEmpty == true
    }

    private static func shares(_ key: String, with other: Mode) -> Bool {
        guard let descriptor = try? KeyDescriptor(parsing: key) else { return false }
        return other.triggerKeys.contains { trigger in
            (try? KeyDescriptor(parsing: trigger.key)).map(descriptor.collides) ?? false
        }
    }
}
