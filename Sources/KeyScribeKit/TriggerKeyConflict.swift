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

// App-wide hotkey precedence across the two global shortcuts (Add to Dictionary / Add Replacement) and
// every Mode trigger key. No design-time rejection or constraint analysis — runtime is "first match in
// precedence order wins." `shadowed` reports the registrants a higher-precedence one already claimed, so
// the same call both suppresses the losers at dispatch and drives the red-dot breadcrumb to them.
public enum HotkeyConflicts {
    public struct Registrant: Equatable, Sendable {
        public let id: String
        public let key: String
        public let enabled: Bool
        public init(id: String, key: String, enabled: Bool = true) {
            self.id = id
            self.key = key
            self.enabled = enabled
        }
    }

    // `ordered` is highest-precedence first (Modes in routing order, then Add Dictionary, then Add
    // Replacement). An enabled registrant is shadowed when its chord collides with an earlier enabled one.
    public static func shadowed(_ ordered: [Registrant]) -> Set<String> {
        var shadowed: Set<String> = []
        var claimed: [KeyDescriptor] = []
        for registrant in ordered where registrant.enabled && !registrant.key.isEmpty {
            guard let descriptor = try? KeyDescriptor(parsing: registrant.key) else { continue }
            if claimed.contains(where: { $0.collides(with: descriptor) }) {
                shadowed.insert(registrant.id)
            }
            claimed.append(descriptor)
        }
        return shadowed
    }
}
