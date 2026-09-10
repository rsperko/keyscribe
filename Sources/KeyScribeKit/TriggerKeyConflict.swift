public struct TriggerKeyConflict: Equatable, Sendable {
    // `collision` — the same physical press reaches both modes, and context routing separates them.
    // `unreachable` — the same press, but written differently, so shadowing drops this one entirely.
    // `masking` — this mode's set is a strict subset of the other's, so holding the other trigger passes
    // through this one on the way in.
    public enum Kind: Equatable, Sendable { case collision, unreachable, masking }

    public let modeId: String
    public let modeName: String
    public let key: String
    public let kind: Kind

    public init(modeId: String, modeName: String, key: String, kind: Kind = .collision) {
        self.modeId = modeId
        self.modeName = modeName
        self.key = key
        self.kind = kind
    }
}

public enum TriggerKeyConflicts {
    // A shared trigger key is a real conflict only when two modes could *contend* for the same press. With
    // constraint-aware routing (ModeResolver.resolvePhaseA) a constrained and an unconstrained mode never
    // collide (the constrained one wins in its app, the other everywhere else). So warn only when
    // `canContend` holds.
    public static func conflict(for mode: Mode, in modes: [Mode]) -> TriggerKeyConflict? {
        var masking: TriggerKeyConflict?
        // Registration order, because shadowing is ordered — see `claimedEarlier`. A mode absent from the
        // list (an unsaved one being edited) would register last, so everything counts as earlier.
        let position = modes.firstIndex { $0.id == mode.id } ?? modes.count
        let earlier = modes.prefix(position).filter(\.enabled)
        // `.unreachable` is a claim about the MODE — the Modes list says "Shortcut never fires" and the
        // menu-bar badge lights — so it holds only when EVERY trigger was already claimed. Returning on the
        // first claimed one flagged a mode that still fires perfectly well through another trigger, which
        // is the same winner/loser mislabeling the ordered rule exists to prevent. It also settles the
        // within-mode case: two triggers on one mode that claim the same press leave the mode reachable
        // through the first, so runtime drops the second and nothing here is a mode-level failure.
        let parsed = mode.triggerKeys.compactMap { trigger in
            (try? KeyDescriptor(parsing: trigger.key)).map { (trigger, $0) }
        }
        let claims = parsed.map { claimedEarlier($0.1, in: earlier) }
        if !claims.isEmpty, claims.allSatisfy({ $0 != nil }), let first = claims.first ?? nil {
            return first
        }
        for editedTrigger in mode.triggerKeys {
            guard let descriptor = try? KeyDescriptor(parsing: editedTrigger.key) else { continue }
            for other in modes where other.id != mode.id && other.enabled {
                for trigger in other.triggerKeys {
                    guard let otherDescriptor = try? KeyDescriptor(parsing: trigger.key) else { continue }
                    guard canContend(mode, other) else { continue }
                    if otherDescriptor.collides(with: descriptor) {
                        return TriggerKeyConflict(
                            modeId: other.id, modeName: other.name, key: trigger.key, kind: .collision)
                    }
                    // An outright collision is the louder problem, so keep looking and only fall back to a
                    // masking warning once nothing shares the press outright.
                    if masking == nil, masks(descriptor, otherDescriptor) {
                        masking = TriggerKeyConflict(
                            modeId: other.id, modeName: other.name, key: trigger.key, kind: .masking)
                    }
                }
            }
        }
        return masking
    }

    /// The earlier mode that already claims this press under a DIFFERENT spelling, which is what makes
    /// this one unreachable: `HotkeyConflicts.shadowed` keeps the first registrant and drops every later
    /// binding that collides, and Phase A then routes by the survivor's trigger string, which never matches
    /// this one. Strictly earlier — asking symmetrically told the mode that actually fires it was dead.
    /// A shared spelling is not reported here: the surviving binding's string still routes to both modes.
    private static func claimedEarlier(
        _ descriptor: KeyDescriptor, in earlier: [Mode]
    ) -> TriggerKeyConflict? {
        // Replays `HotkeyConflicts.shadowed`, and must keep replaying it: only bindings that actually
        // claimed can make a later one unreachable, so a mode that lost is skipped rather than treated as a
        // claimant. Diverge here and the warning blames a mode that was never registered.
        var claimed: [(mode: Mode, key: String, descriptor: KeyDescriptor)] = []
        for other in earlier {
            for trigger in other.triggerKeys {
                guard let otherDescriptor = try? KeyDescriptor(parsing: trigger.key),
                      !claimed.contains(where: { $0.descriptor.collides(with: otherDescriptor) })
                else { continue }
                claimed.append((other, trigger.key, otherDescriptor))
            }
        }
        for claim in claimed
        where claim.descriptor.collides(with: descriptor)
            && claim.descriptor.canonical != descriptor.canonical {
            return TriggerKeyConflict(
                modeId: claim.mode.id, modeName: claim.mode.name, key: claim.key, kind: .unreachable)
        }
        return nil
    }

    /// Any enabled mode whose trigger is dropped by shadowing and cannot be routed back to. Unlike the
    /// per-row warning this is a whole-config question, so the Modes pane and the menu-bar badge can point
    /// at a mode that will never fire even while it is not the one being edited.
    public static func hasUnreachableTrigger(in modes: [Mode]) -> Bool {
        modes.contains { mode in
            mode.enabled && conflict(for: mode, in: modes)?.kind == .unreachable
        }
    }

    private static func masks(_ descriptor: KeyDescriptor, _ other: KeyDescriptor) -> Bool {
        guard case .modifiers(let set) = descriptor, case .modifiers(let otherSet) = other else { return false }
        return set.isMasked(by: otherSet)
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
            // Only a SUCCESSFUL claim becomes a future claimant. Collision stopped being transitive once a
            // sideless member could stand in for either key — right_command ~ command ~ left_command, while
            // right_command and left_command cannot both engage — so a binding that lost, and is therefore
            // never registered, must not claim the press away from a later one that would have worked.
            if claimed.contains(where: { $0.collides(with: descriptor) }) {
                shadowed.insert(registrant.id)
            } else {
                claimed.append(descriptor)
            }
        }
        return shadowed
    }
}
