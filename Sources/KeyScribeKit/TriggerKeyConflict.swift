public struct TriggerKeyConflict: Equatable, Sendable {
    public let modeId: String
    public let modeName: String
    public let key: String
}

public enum TriggerKeyConflicts {
    // A shared trigger key is only a real conflict when two modes could *contend* for the same press —
    // i.e. some app/URL context selects either with no clear winner. With constraint-aware key routing
    // (ModeResolver.resolvePhaseA) a constrained mode and an unconstrained one never collide: the
    // constrained one wins in its app, the other wins everywhere else, and both stay reachable. So the
    // warning fires only when `canContend` holds, matching what routing actually does.
    public static func conflict(for mode: Mode, in modes: [Mode]) -> TriggerKeyConflict? {
        guard let key = mode.triggerKeys.first?.key,
              let descriptor = try? KeyDescriptor(parsing: key) else { return nil }
        for other in modes where other.id != mode.id && other.enabled {
            for trigger in other.triggerKeys {
                guard let otherDescriptor = try? KeyDescriptor(parsing: trigger.key),
                      otherDescriptor.collides(with: descriptor),
                      canContend(mode, other) else { continue }
                return TriggerKeyConflict(modeId: other.id, modeName: other.name, key: trigger.key)
            }
        }
        return nil
    }

    // True when no app/URL context cleanly separates the two modes. Both unconstrained → they collide
    // everywhere. One unconstrained, one constrained → never (each is reachable). Both constrained →
    // they contend only if a shared app bundle, or both gate on a URL (whose patterns can't be proven
    // disjoint here, so we warn conservatively).
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
