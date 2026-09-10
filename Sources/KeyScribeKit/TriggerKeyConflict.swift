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
        let claims = parsed.map { claimedEarlier($0.1, for: mode, in: earlier) }
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
        _ descriptor: KeyDescriptor, for mode: Mode, in earlier: [Mode]
    ) -> TriggerKeyConflict? {
        // Replays `HotkeyConflicts.shadowed`, and must keep replaying it: only bindings that actually
        // claimed can make a later one unreachable, so a mode that lost is skipped rather than treated as a
        // claimant. Diverge here and the warning blames a mode that was never registered.
        var claimed: [(mode: Mode, key: String, descriptor: KeyDescriptor, contesters: [Mode])] = []
        for other in earlier {
            for trigger in other.triggerKeys {
                guard let otherDescriptor = try? KeyDescriptor(parsing: trigger.key) else { continue }
                // A binding is dropped outright only by a claimant that outranks it EVERYWHERE it runs.
                // `shadowed` is computed per-app over the claimable set, so one that loses inside a scoped
                // claimant's apps is still the first registrant everywhere that claimant is absent — and it
                // is that binding, not the scoped winner, that can leave a later mode dead.
                let contesters = claimed.filter { $0.descriptor.collides(with: otherDescriptor) }
                if contesters.contains(where: { shadowsWhereverItRuns(claimant: $0.mode, other) }) {
                    continue
                }
                claimed.append((other, trigger.key, otherDescriptor, contesters.map(\.mode)))
            }
        }
        // Registration is context-aware (`ModeResolver.canClaimKey`), so a claimant only shadows this
        // mode where BOTH are registered. A claimant scoped to apps this mode also reaches shadows it
        // everywhere it runs; a narrower claimant leaves it working outside those apps, and calling that
        // "never fires" lights the menu-bar error badge for a mode that fires fine.
        // A RETAINED loser claims only where the winner that beat it is absent, so it can only be the reason
        // this mode never fires when no contester reaches into this mode's apps at all. Judge it by its
        // declared scope instead and a mode that owns its key perfectly well — because the contester takes
        // the colliding one out of its way there — is reported dead.
        for claim in claimed
        where claim.descriptor.collides(with: descriptor)
            && claim.descriptor.canonical != descriptor.canonical
            && shadowsWhereverItRuns(claimant: claim.mode, mode)
            && claim.contesters.allSatisfy({ !bundleScopesIntersect($0, mode) }) {
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

    /// True when `claimant` is registered everywhere `mode` is — the condition for it to shadow `mode`
    /// out of existence rather than merely out of a few apps.
    ///
    /// Deliberately NOT `canContend`: that answers "can two registered modes contend for one press" and
    /// returns false for one-constrained/one-not, but an unconstrained mode is claimable EVERYWHERE and
    /// so does still shadow a scoped one inside its apps. The question here is reachability of the
    /// registration, not of the routing.
    static func shadowsWhereverItRuns(claimant: Mode, _ mode: Mode) -> Bool {
        // nil = claimable everywhere: unconstrained, or scoped only on a URL/window title, which cannot
        // gate registration and so leaves the key claimed in every app.
        guard let claimantScope = bundleScope(claimant) else { return true }
        guard let modeScope = bundleScope(mode) else { return false }
        return modeScope.allSatisfy { target in
            claimantScope.contains { $0.covers(target) }
        }
    }

    /// Whether the two modes can ever be registered in the same app at once. Unscoped on either side means
    /// yes — that mode is claimable everywhere.
    static func bundleScopesIntersect(_ a: Mode, _ b: Mode) -> Bool {
        guard let left = bundleScope(a), let right = bundleScope(b) else { return true }
        return left.contains { l in right.contains { l.intersects($0) } }
    }

    enum BundleMatcher: Equatable {
        case exact(String)
        case prefix(String)

        // Overlap in either direction, unlike `covers` — two scopes share an app whenever one reaches into
        // the other, no matter which is the broader.
        func intersects(_ other: BundleMatcher) -> Bool {
            covers(other) || other.covers(self)
        }

        // Reachability, not string equality: `com.google.` covers `com.google.Chrome`, and a prefix is
        // only covered by a shorter prefix (an exact id can never cover the infinitely many a prefix does).
        func covers(_ other: BundleMatcher) -> Bool {
            switch (self, other) {
            case let (.exact(a), .exact(b)): return a.lowercased() == b.lowercased()
            case let (.prefix(a), .exact(b)): return b.lowercased().hasPrefix(a.lowercased())
            case let (.prefix(a), .prefix(b)): return b.lowercased().hasPrefix(a.lowercased())
            case (.exact, .prefix): return false
            }
        }
    }

    /// The apps a mode's key stays registered in, or nil for "everywhere". Mirrors
    /// `ModeResolver.canClaimKey`: a single constraint without a bundle field keeps the key claimed
    /// globally, so the whole mode is unscoped.
    static func bundleScope(_ mode: Mode) -> [BundleMatcher]? {
        guard !mode.constraints.isEmpty else { return nil }
        var matchers: [BundleMatcher] = []
        for constraint in mode.constraints {
            // bundle_id FIRST: a constraint ANDs its fields, so carrying both narrows to the exact id.
            // Reading the prefix would widen the scope to every sibling bundle the mode can never run in.
            if let bundleId = constraint.bundleId {
                matchers.append(.exact(bundleId))
            } else if let prefix = constraint.bundlePrefix {
                matchers.append(.prefix(prefix))
            } else {
                return nil
            }
        }
        return matchers
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
