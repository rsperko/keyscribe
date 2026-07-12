public struct TriggerKeyConflict: Equatable, Sendable {
    public let modeId: String
    public let modeName: String
    public let key: String
}

// A modifier-only trigger that will double-fire because a rival binding's modifiers subsume it.
public struct TriggerOverlap: Equatable, Sendable {
    public let triggerKey: String
    public let rivalLabel: String
    public init(triggerKey: String, rivalLabel: String) {
        self.triggerKey = triggerKey
        self.rivalLabel = rivalLabel
    }
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

    // A rival binding that could double-fire a modifier-only trigger: another mode's trigger key or a
    // global action shortcut, paired with a human label for the warning ("the Message mode's shortcut").
    public struct RivalBinding: Equatable, Sendable {
        public let key: String
        public let label: String
        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    // A configured global action shortcut considered as a potential rival, tagged with the id used in the
    // shadow set so inactive ones can be filtered out of the warning.
    public struct ActionShortcut: Equatable, Sendable {
        public let id: String
        public let key: String
        public let label: String
        public init(id: String, key: String, label: String) {
            self.id = id
            self.key = key
            self.label = label
        }
    }

    // Keep only action shortcuts that can actually fire — a registerable chord that is not shadowed — so the
    // warning never names a shortcut that will not fire. Mirrors the runtime registration filter
    // (AppDelegate.actionBindings). A shadowed global is shadowed by an earlier mode registrant (modes
    // ordered before globals) that already surfaces as a rival, so dropping it re-attributes the warning to
    // the active binding rather than losing it.
    public static func liveActionRivals(_ shortcuts: [ActionShortcut], shadowed: Set<String>) -> [RivalBinding] {
        shortcuts.compactMap { shortcut in
            guard !shortcut.key.isEmpty, !shadowed.contains(shortcut.id),
                  let descriptor = try? KeyDescriptor(parsing: shortcut.key),
                  case .chord = descriptor else { return nil }
            return RivalBinding(key: shortcut.key, label: shortcut.label)
        }
    }

    // Only the Hyper trigger can genuinely double-fire with a chord that subsumes it. The right-side
    // modifier triggers (right-Option / right-Command / right-Control) are disambiguated at runtime by
    // the "chord wins" rule (HotkeyMonitor: a bare modifier-only trigger is suppressed while any foreign
    // chord modifier is also held, and a bare start is aborted if one joins), so an overlapping chord
    // no longer double-fires them — warning there would be noise on a common, legitimate setup
    // (e.g. right-Option dictation next to a Hyper action shortcut). Hyper is the maximal modifier set,
    // so nothing outranks it: pressing ⌃⌥⇧⌘X fires a Hyper-triggered mode alongside the chord with no
    // "bare vs chord" distinction to exploit — that lone case still warrants the warning.
    // Returns the first rival whose modifier set is a superset of Hyper's; exact duplicates and the
    // right-side keys are left to `conflict`/`shadowed`/the runtime.
    public static func modifierOverlap(triggerKey: String, with rivals: [RivalBinding]) -> TriggerOverlap? {
        guard let trigger = try? KeyDescriptor(parsing: triggerKey), case .named(.hyper) = trigger else { return nil }
        let mods = trigger.requiredModifierMask
        for rival in rivals {
            guard let descriptor = try? KeyDescriptor(parsing: rival.key),
                  !descriptor.collides(with: trigger),
                  descriptor.requiredModifierMask.isSuperset(of: mods) else { continue }
            return TriggerOverlap(triggerKey: triggerKey, rivalLabel: rival.label)
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
