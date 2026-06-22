public struct TriggerKeyConflict: Equatable, Sendable {
    public let modeId: String
    public let modeName: String
    public let key: String
}

public enum TriggerKeyConflicts {
    public static func conflict(
        for descriptor: KeyDescriptor, excludingModeId: String, in modes: [Mode]
    ) -> TriggerKeyConflict? {
        for mode in modes where mode.id != excludingModeId && mode.enabled {
            for trigger in mode.triggerKeys {
                guard let other = try? KeyDescriptor(parsing: trigger.key) else { continue }
                if other.collides(with: descriptor) {
                    return TriggerKeyConflict(modeId: mode.id, modeName: mode.name, key: trigger.key)
                }
            }
        }
        return nil
    }
}
