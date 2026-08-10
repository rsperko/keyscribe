public struct TriggerKeyConflict: Equatable, Sendable {
    public let modeId: String
    public let modeName: String
    public let key: String
}

public enum TriggerKeyConflicts {
    // A shared trigger key is a real conflict only when two modes could *contend* for the same press. With
    // constraint-aware routing (ModeResolver.resolvePhaseA) a constrained and an unconstrained mode never
    // collide (the constrained one wins in its app, the other everywhere else). So warn only when
    // `canContend` holds.
    public static func conflict(for mode: Mode, in modes: [Mode]) -> TriggerKeyConflict? {
        for editedTrigger in mode.triggerKeys {
            guard let descriptor = try? KeyDescriptor(parsing: editedTrigger.key) else { continue }
            for other in modes where other.id != mode.id && other.enabled {
                for trigger in other.triggerKeys {
                    guard let otherDescriptor = try? KeyDescriptor(parsing: trigger.key),
                          otherDescriptor.collides(with: descriptor),
                          canContend(mode, other) else { continue }
                    return TriggerKeyConflict(modeId: other.id, modeName: other.name, key: trigger.key)
                }
            }
        }
        return nil
    }

    // True when no routing context cleanly separates the two modes. Both unconstrained → collide everywhere.
    // One constrained, one not → never. Both constrained → contend only on a shared app bundle, or both gate
    // on a URL (patterns can't be proven disjoint here, so warn conservatively).
    static func canContend(_ a: Mode, _ b: Mode) -> Bool {
        if a.constraints.isEmpty && b.constraints.isEmpty { return true }
        if a.constraints.isEmpty || b.constraints.isEmpty { return false }
        let aBundles = Set(a.constraints.compactMap(\.bundleId))
        let bBundles = Set(b.constraints.compactMap(\.bundleId))
        if !aBundles.isDisjoint(with: bBundles) { return true }
        let aHasURL = a.constraints.contains { $0.urlPattern != nil }
        let bHasURL = b.constraints.contains { $0.urlPattern != nil }
        return aHasURL && bHasURL
    }
}

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
