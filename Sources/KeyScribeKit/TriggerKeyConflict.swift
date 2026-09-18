public struct TriggerKeyConflict: Equatable, Sendable {
    // Collision shares a press; unreachable loses registration for every trigger, triggerUnreachable for
    // one while another still fires; masking is a strict modifier subset.
    public enum Kind: Equatable, Sendable { case collision, unreachable, triggerUnreachable, masking }

    public let modeId: String
    public let modeName: String
    public let key: String
    public let kind: Kind
    public let triggerKey: String

    public init(modeId: String, modeName: String, key: String, kind: Kind = .collision, triggerKey: String) {
        self.modeId = modeId
        self.modeName = modeName
        self.key = key
        self.kind = kind
        self.triggerKey = triggerKey
    }
}

public enum TriggerKeyConflicts {
    // Routing separates constrained and unconstrained modes, so only warn when they can contend.
    public static func conflict(for mode: Mode, in modes: [Mode]) -> TriggerKeyConflict? {
        var masking: TriggerKeyConflict?
        // An unsaved mode registers last.
        let position = modes.firstIndex { $0.id == mode.id } ?? modes.count
        let earlier = modes.prefix(position).filter(\.enabled)
        // A mode is unreachable only if every trigger is claimed; one surviving trigger suffices.
        let parsed = mode.triggerKeys.compactMap { trigger in
            (try? KeyDescriptor(parsing: trigger.key)).map { (trigger, $0) }
        }
        let claims = parsed.map { claimedEarlier($0.1, key: $0.0.key, for: mode, in: earlier) }
        if !claims.isEmpty, claims.allSatisfy({ $0 != nil }), let first = claims.first ?? nil {
            return first
        }
        if let dead = claims.lazy.compactMap({ $0 }).first {
            return TriggerKeyConflict(
                modeId: dead.modeId, modeName: dead.modeName, key: dead.key, kind: .triggerUnreachable,
                triggerKey: dead.triggerKey)
        }
        for editedTrigger in mode.triggerKeys {
            guard let descriptor = try? KeyDescriptor(parsing: editedTrigger.key) else { continue }
            for other in modes where other.id != mode.id && other.enabled {
                for trigger in other.triggerKeys {
                    guard let otherDescriptor = try? KeyDescriptor(parsing: trigger.key) else { continue }
                    guard canContend(mode, other) else { continue }
                    if otherDescriptor.collides(with: descriptor) {
                        return TriggerKeyConflict(
                            modeId: other.id, modeName: other.name, key: trigger.key, kind: .collision,
                            triggerKey: editedTrigger.key)
                    }
                    // Prefer a collision warning over masking.
                    if masking == nil, masks(descriptor, otherDescriptor) {
                        masking = TriggerKeyConflict(
                            modeId: other.id, modeName: other.name, key: trigger.key, kind: .masking,
                            triggerKey: editedTrigger.key)
                    }
                }
            }
        }
        return masking
    }

    /// An earlier claimant with a different spelling makes this trigger unreachable; the same spelling
    /// still routes to both modes.
    private static func claimedEarlier(
        _ descriptor: KeyDescriptor, key: String, for mode: Mode, in earlier: [Mode]
    ) -> TriggerKeyConflict? {
        // Replay ordered registration: a dropped binding cannot claim a later press.
        var claimed: [(mode: Mode, key: String, descriptor: KeyDescriptor, contesters: [Mode])] = []
        for other in earlier {
            for trigger in other.triggerKeys {
                guard let otherDescriptor = try? KeyDescriptor(parsing: trigger.key) else { continue }
                // A scoped winner cannot drop a binding that still registers outside its apps.
                let contesters = claimed.filter { $0.descriptor.collides(with: otherDescriptor) }
                if contesters.contains(where: { shadowsWhereverItRuns(claimant: $0.mode, other) }) {
                    continue
                }
                claimed.append((other, trigger.key, otherDescriptor, contesters.map(\.mode)))
            }
        }
        // A retained loser claims only where its winner is absent. A narrower claimant must not make a
        // working mode appear unreachable.
        for claim in claimed
        where claim.descriptor.collides(with: descriptor)
            && claim.descriptor.canonical != descriptor.canonical
            && shadowsWhereverItRuns(claimant: claim.mode, mode)
            && claim.contesters.allSatisfy({ !bundleScopesIntersect($0, mode) }) {
            return TriggerKeyConflict(
                modeId: claim.mode.id, modeName: claim.mode.name, key: claim.key, kind: .unreachable,
                triggerKey: key)
        }
        return nil
    }

    public struct ParsedTrigger: Equatable, Sendable {
        public let index: Int
        public let descriptor: KeyDescriptor
        public let sameAs: KeyDescriptor?

        public init(index: Int, descriptor: KeyDescriptor, sameAs: KeyDescriptor?) {
            self.index = index
            self.descriptor = descriptor
            self.sameAs = sameAs
        }
    }

    /// Mirrors intra-mode shadowing at registration: only a bound entry can make a later one redundant.
    public static func parsedTriggers(in mode: Mode) -> [ParsedTrigger] {
        var bound: [KeyDescriptor] = []
        var parsed: [ParsedTrigger] = []
        for (index, trigger) in mode.triggerKeys.enumerated() {
            guard let descriptor = try? KeyDescriptor(parsing: trigger.key) else { continue }
            let sameAs = bound.first { $0.collides(with: descriptor) }
            if sameAs == nil { bound.append(descriptor) }
            parsed.append(ParsedTrigger(index: index, descriptor: descriptor, sameAs: sameAs))
        }
        return parsed
    }

    public static func liveTriggers(in mode: Mode) -> [ParsedTrigger] {
        parsedTriggers(in: mode).filter { $0.sameAs == nil }
    }

    public static func redundantTriggers(in mode: Mode) -> [ParsedTrigger] {
        parsedTriggers(in: mode).filter { $0.sameAs != nil }
    }

    /// Whether any enabled mode has an unreachable trigger.
    public static func hasUnreachableTrigger(in modes: [Mode]) -> Bool {
        modes.contains { mode in
            mode.enabled && conflict(for: mode, in: modes)?.kind == .unreachable
        }
    }

    private static func masks(_ descriptor: KeyDescriptor, _ other: KeyDescriptor) -> Bool {
        guard case .modifiers(let set) = descriptor, case .modifiers(let otherSet) = other else { return false }
        return set.isMasked(by: otherSet)
    }

    /// Registration reachability differs from `canContend`: a global claimant can shadow a scoped mode.
    static func shadowsWhereverItRuns(claimant: Mode, _ mode: Mode) -> Bool {
        // URL and window constraints cannot gate registration, so nil means every app.
        guard let claimantScope = bundleScope(claimant) else { return true }
        guard let modeScope = bundleScope(mode) else { return false }
        return modeScope.allSatisfy { target in
            claimantScope.contains { $0.covers(target) }
        }
    }

    /// Whether the modes can register in the same app.
    static func bundleScopesIntersect(_ a: Mode, _ b: Mode) -> Bool {
        guard let left = bundleScope(a), let right = bundleScope(b) else { return true }
        return left.contains { l in right.contains { l.intersects($0) } }
    }

    enum BundleMatcher: Equatable {
        case exact(String)
        case prefix(String)

        // Overlap is symmetric; `covers` is directional.
        func intersects(_ other: BundleMatcher) -> Bool {
            covers(other) || other.covers(self)
        }

        // A prefix covers exact IDs and longer prefixes, while an exact ID cannot cover a prefix.
        func covers(_ other: BundleMatcher) -> Bool {
            switch (self, other) {
            case let (.exact(a), .exact(b)): return a.lowercased() == b.lowercased()
            case let (.prefix(a), .exact(b)): return b.lowercased().hasPrefix(a.lowercased())
            case let (.prefix(a), .prefix(b)): return b.lowercased().hasPrefix(a.lowercased())
            case (.exact, .prefix): return false
            }
        }
    }

    /// Registration scope, or nil for every app; URL and window constraints do not restrict it.
    static func bundleScope(_ mode: Mode) -> [BundleMatcher]? {
        guard !mode.constraints.isEmpty else { return nil }
        var matchers: [BundleMatcher] = []
        for constraint in mode.constraints {
            // An exact ID narrows a constraint that also has a prefix.
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

    // URL patterns cannot be proven disjoint, so two URL constrained modes may contend.
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
    public struct BoundTrigger: Equatable, Sendable {
        public let mode: Mode
        public let trigger: Mode.TriggerKey
    }

    /// Keyed by position, not key text, so a repeated entry cannot share its id with the one it repeats.
    public static func registrantId(mode: Mode, index: Int) -> String { "\(mode.id)#\(index)" }

    public static func modeRegistrants(_ modes: [Mode]) -> [Registrant] {
        modes.flatMap { mode in
            mode.triggerKeys.enumerated().map { index, trigger in
                Registrant(id: registrantId(mode: mode, index: index), key: trigger.key, enabled: mode.enabled)
            }
        }
    }

    public static func boundTriggers(in modes: [Mode], shadowed: Set<String>) -> [BoundTrigger] {
        modes.filter(\.enabled).flatMap { mode in
            mode.triggerKeys.enumerated().compactMap { index, trigger in
                shadowed.contains(registrantId(mode: mode, index: index))
                    ? nil : BoundTrigger(mode: mode, trigger: trigger)
            }
        }
    }

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
            // Collision is not transitive across sided and sideless keys; only registered bindings claim.
            if claimed.contains(where: { $0.collides(with: descriptor) }) {
                shadowed.insert(registrant.id)
            } else {
                claimed.append(descriptor)
            }
        }
        return shadowed
    }
}
