import Foundation

public struct AgentConversation: Equatable, Sendable {
    public var id: String
    public var agent: String
    public var pid: Int?
    public var host: AgentHostLocation?
    public var cwd: String
    public var handle: String
    public var state: AgentLiveState
    public var connectorLive: Bool
    public var title: String?
    public var startedAt: Date?
    public var setup: String?
    public var nameSource: AgentNameSource
    public var placeName: AgentPlaceName?
    public var placeSurface: String?
    public var otherNames: [String]
    public var placeUnreadSince: Date?
    public var innerAgent: String?

    public var reachable: Bool { connectorLive || host != nil }
    public var runningAgent: String { innerAgent ?? agent }

    public init(
        id: String, agent: String, pid: Int?, cwd: String, handle: String, state: AgentLiveState, connectorLive: Bool,
        title: String? = nil, startedAt: Date? = nil, setup: String? = nil, nameSource: AgentNameSource = .folder,
        placeName: AgentPlaceName? = nil, placeSurface: String? = nil, otherNames: [String] = [], placeUnreadSince: Date? = nil,
        host: AgentHostLocation? = nil, innerAgent: String? = nil
    ) {
        self.innerAgent = innerAgent
        self.host = host
        self.placeSurface = placeSurface
        self.placeUnreadSince = placeUnreadSince
        self.otherNames = otherNames
        self.setup = setup
        self.nameSource = nameSource
        self.placeName = placeName
        self.title = title
        self.startedAt = startedAt
        self.id = id
        self.agent = agent
        self.pid = pid
        self.cwd = cwd
        self.handle = handle
        self.state = state
        self.connectorLive = connectorLive
    }
}

public enum AgentNameSource: Equatable, Sendable { case chosen, agent, place, folder }

public struct AgentPlaceName: Equatable, Sendable {
    public var surface: String
    public var level: AgentPlace.Level
    public var label: String
    public var term: String?

    public init(surface: String, level: AgentPlace.Level, label: String, term: String? = nil) {
        self.surface = surface
        self.level = level
        self.label = label
        self.term = term
    }

    public var word: String { term ?? level.rawValue }
}

public struct RememberedName: Codable, Hashable, Sendable {
    public var name: String
    public var pid: Int?
    public var startedAt: Int
    public var native: String?
    public var agent: String
    public var previous: [String]

    public init(name: String, pid: Int?, startedAt: Int, native: String?, agent: String = "", previous: [String] = []) {
        self.previous = previous
        self.name = name
        self.pid = pid
        self.startedAt = startedAt
        self.native = native
        self.agent = agent
    }

    enum CodingKeys: String, CodingKey {
        case name, pid, native, agent, previous
        case startedAt = "started_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        startedAt = try c.decode(Int.self, forKey: .startedAt)
        native = try c.decodeIfPresent(String.self, forKey: .native)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        previous = try c.decodeIfPresent([String].self, forKey: .previous) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(native, forKey: .native)
        try c.encode(agent, forKey: .agent)
        if !previous.isEmpty { try c.encode(previous, forKey: .previous) }
    }
}

public struct AgentDirectory: Sendable {
    public static let retiredLimit = 512
    public private(set) var conversations: [AgentConversation] = []
    public private(set) var disconnected: [AgentConversation] = []
    public private(set) var revision = 0
    private var handleById: [String: String] = [:]
    struct Retired: Equatable, Sendable {
        var name: String
        var update: Int
    }

    private(set) var retired: [String: Retired] = [:]
    private var updates = 0
    private var chosen: [String: String] = [:]
    private(set) var nativeNameById: [String: String] = [:]
    private var remembering: [String: RememberedName]
    private var startById: [String: Int] = [:]
    private var preferredById: [String: String] = [:]
    private var sourceById: [String: AgentNameSource] = [:]
    private var placeNameById: [String: AgentPlaceName] = [:]
    private var folderUnknown: Set<String> = []
    private var former: [String: [String]] = [:]
    private var placeShared: [String: AgentRecipient.SharedName] = [:]
    public private(set) var formerNames: [String: String] = [:]
    public private(set) var sharedPlaceNames: [String: AgentRecipient.SharedName] = [:]

    public init(chosen: [String: String] = [:], remembered: [String: RememberedName] = [:]) {
        self.chosen = chosen.mapValues(AgentHandles.normalize).filter { !$0.value.isEmpty }
        self.remembering = remembered.filter { Self.isSayable($0.value.name) }.mapValues { saved in
            var kept = saved
            kept.previous = Self.previous(saved.previous, apartFrom: saved.name)
            return kept
        }
        rememberAll()
    }

    private static func isSayable(_ name: String) -> Bool { !name.isEmpty && AgentHandles.normalize(name) == name }

    private static func previous(_ names: [String], apartFrom name: String?) -> [String] {
        var seen = Set([name].compactMap { $0 }.map(AgentHandles.matchKey))
        return names.filter { isSayable($0) && seen.insert(AgentHandles.matchKey($0)).inserted }
    }

    public func previousNames(of id: String) -> [String] {
        Self.previous(former[id] ?? remembering[id]?.previous ?? [], apartFrom: handleById[id] ?? chosen[id])
    }

    private mutating func indexPreviousNames() {
        var claimed = Set(handleById.values.map(AgentHandles.matchKey))
        claimed.formUnion(chosen.filter { handleById[$0.key] == nil }.values.map(AgentHandles.matchKey))
        claimed.formUnion(remembering.values.map { AgentHandles.matchKey($0.name) })
        let placeHolders = Dictionary(placeShared.map { (AgentHandles.matchKey($0.key), $0.value.names) }, uniquingKeysWith: { first, _ in first })
        var holders: [String: (name: String, ids: [String])] = [:]
        for (id, handle) in handleById.sorted(by: { $0.key < $1.key }) where former[id] != nil {
            for name in previousNames(of: id) {
                let key = AgentHandles.matchKey(name)
                guard !claimed.contains(key), placeHolders[key].map({ $0 == [handle] }) ?? true else { continue }
                holders[key, default: (name, [])].ids.append(id)
            }
        }
        formerNames = [:]
        sharedPlaceNames = placeShared
        for holder in holders.values {
            if holder.ids.count == 1 {
                formerNames[holder.name] = holder.ids[0]
            } else {
                sharedPlaceNames[holder.name] = AgentRecipient.SharedName(names: holder.ids.compactMap { handleById[$0] }.sorted())
            }
        }
    }

    private func keepsName(_ id: String) -> Bool { chosen[id] == nil && !folderUnknown.contains(id) }

    public var chosenNames: [String: String] { chosen }

    public private(set) var remembered: [String: RememberedName] = [:]

    private mutating func rememberAll() {
        remembered = rememberedNow()
    }

    func rememberedNow() -> [String: RememberedName] {
        var names = remembering
        for conversation in conversations + disconnected {
            if let saved = remembering(conversation) { names[conversation.id] = saved }
        }
        return names
    }

    private func remembering(_ conversation: AgentConversation) -> RememberedName? {
        let previous = previousNames(of: conversation.id)
        guard keepsName(conversation.id) || (chosen[conversation.id] != nil && !previous.isEmpty),
              let start = startById[conversation.id], let name = handleById[conversation.id]
        else { return nil }
        return RememberedName(
            name: name, pid: conversation.pid, startedAt: start, native: nativeNameById[conversation.id], agent: conversation.agent,
            previous: previous)
    }

    public var handles: [String] { conversations.map(\.handle) }

    public func conversation(handle: String) -> AgentConversation? {
        let wanted = AgentHandles.matchKey(handle)
        return conversations.first { AgentHandles.matchKey($0.handle) == wanted }
    }

    public func conversation(pid: Int) -> AgentConversation? {
        conversations.first { $0.pid == pid }
    }

    private mutating func retire(_ id: String, as name: String) {
        retired[id] = Retired(name: name, update: updates)
    }

    private mutating func capRetired() {
        guard retired.count > Self.retiredLimit else { return }
        let byUpdate = Dictionary(grouping: retired.values.map(\.update), by: { $0 }).mapValues(\.count)
        var kept = 0
        var oldestKept = Int.max
        for (update, count) in byUpdate.sorted(by: { $0.key > $1.key }) {
            guard oldestKept == Int.max || kept + count <= Self.retiredLimit else { break }
            kept += count
            oldestKept = update
        }
        retired = retired.filter { $0.value.update >= oldestKept }
    }

    public mutating func setStates(_ states: [String: AgentLiveState]) {
        var changed = false
        for index in conversations.indices {
            guard let state = states[conversations[index].id], conversations[index].state != state else { continue }
            conversations[index].state = state
            changed = true
        }
        for index in disconnected.indices {
            guard let state = states[disconnected[index].id], disconnected[index].state != state else { continue }
            disconnected[index].state = state
            changed = true
        }
        if changed { revision += 1 }
    }

    public mutating func update(
        entries: [AgentSession], live: Set<String>, titles: [String: String] = [:], nativeNames: [String: String?] = [:],
        running: (RememberedName) -> Bool = { _ in false }, excluded: Set<String> = [], places: [String: AgentPlace] = [:],
        unplaced: Set<String> = [], unreadSince: [String: Date] = [:]
    ) {
        updates += 1
        func conversationId(_ entry: AgentSession) -> String { AgentSessionID.make(agent: entry.agent, native: entry.id) }
        func usable(_ name: String) -> String? {
            let normalized = AgentHandles.normalize(name)
            return normalized.isEmpty || AgentHandles.isReserved(normalized) ? nil : normalized
        }
        let before = handleById
        var placed: [String: (name: String, place: AgentPlaceName)] = [:]
        var sharing: [String: (label: String, groups: [String], surface: String)] = [:]
        let known = places
        var agentLabelHolders: [String: [String]] = [:]
        var containerHolders: [String: [String]] = [:]
        for entry in entries {
            let id = conversationId(entry)
            guard let place = known[id] else { continue }
            let keys = Set(place.labels.filter { $0.level == .agent }.compactMap { usable($0.text).map(AgentHandles.matchKey) })
            for key in keys { agentLabelHolders[key, default: []].append(id) }
            for container in Set(place.containers) { containerHolders[container, default: []].append(id) }
        }
        var labelled: [(entry: AgentSession, place: AgentPlace, label: AgentPlace.Label, base: String, key: String, source: String)] = []
        for entry in entries {
            let id = conversationId(entry)
            guard let place = known[id], let label = place.labels.first(where: { !$0.onlyAfterVerb && usable($0.text) != nil }),
                  let base = usable(label.text)
            else { continue }
            let key = AgentHandles.matchKey(base)
            labelled.append((entry, place, label, base, key, label.level == .agent ? "agent \(key)" : "container \(label.container)"))
        }
        func holders(of source: String) -> [String] {
            source.hasPrefix("agent ") ? agentLabelHolders[String(source.dropFirst(6))] ?? [] : containerHolders[String(source.dropFirst(10))] ?? []
        }
        func union(_ lists: [[String]]) -> [String] {
            var seen: Set<String> = []
            return lists.flatMap { $0 }.filter { seen.insert($0).inserted }
        }
        var sourcesByGroup: [String: [String]] = [:]
        var sourcesSeen: Set<String> = []
        for item in labelled {
            let group = "\(item.label.level == .agent) \(item.key)"
            if sourcesSeen.insert("\(group)\u{0}\(item.source)").inserted { sourcesByGroup[group, default: []].append(item.source) }
        }
        let membersByKey = sourcesByGroup.mapValues { union($0.map(holders)) }
        func workspace(_ id: String, apartFrom base: String) -> String? {
            (known[id]?.labels.first { $0.level == .workspace }?.text ?? known[id]?.workspace).flatMap { usable($0) }.flatMap {
                AgentHandles.matchKey($0) == AgentHandles.matchKey(base) ? nil : $0
            }
        }
        var apartByGroup: [String: Bool] = [:]
        for item in labelled {
            let id = conversationId(item.entry)
            let byAgent = AgentHandles.matchKey(item.base) == AgentHandles.matchKey(item.entry.agent) ? nil : usable("\(item.base) \(item.entry.agent)")
            let group = "\(item.label.level == .agent) \(item.key)"
            let members = membersByKey[group] ?? []
            let apart = apartByGroup[group] ?? {
                let workspaces = members.map { workspace($0, apartFrom: item.base) }
                let apart = workspaces.allSatisfy { $0 != nil } && Set(workspaces.compactMap { $0.map(AgentHandles.matchKey) }).count == members.count
                apartByGroup[group] = apart
                return apart
            }()
            let ownWorkspace = workspace(id, apartFrom: item.base).flatMap { usable("\($0) \(item.base)") }
            let earlier = [nativeNameById[id], remembering[id]?.native].compactMap { $0 }.map(AgentHandles.matchKey)
            let given = [byAgent, ownWorkspace].compactMap { $0 }.first { earlier.contains(AgentHandles.matchKey($0)) }
            let qualifiedName = given ?? (apart ? ownWorkspace : nil) ?? byAgent
            let qualifies = members.count > 1 || given != nil
            placed[id] = (qualifies ? qualifiedName ?? item.base : item.base,
                          AgentPlaceName(
                              surface: item.label.surface ?? item.place.surface, level: item.label.level, label: item.label.text, term: item.label.term))
            guard qualifies else { continue }
            let held = sharing[item.key]?.groups ?? []
            sharing[item.key] = (
                sharing[item.key]?.label ?? item.base, held.last == group || held.contains(group) ? held : held + [group], item.label.surface ?? item.place.surface)
        }
        let liveIds = Set(entries.map(conversationId))
        for conversation in conversations + disconnected where !liveIds.contains(conversation.id) {
            if let saved = remembering(conversation) { remembering[conversation.id] = saved }
        }
        let runningProcesses = Set(entries.compactMap { entry in entry.pid.flatMap { pid in entry.startedAt.map { "\(pid) \($0)" } } })
        remembering = remembering.filter { id, saved in
            guard !liveIds.contains(id) else { return true }
            let replaced = saved.pid.map { runningProcesses.contains("\($0) \(saved.startedAt)") } ?? false
            return !replaced && running(saved)
        }
        for (id, handle) in handleById where !liveIds.contains(id) && !folderUnknown.contains(id) {
            retire(id, as: handle)
        }
        handleById = handleById.filter { liveIds.contains($0.key) }
        startById = Dictionary(entries.compactMap { entry in entry.startedAt.map { (conversationId(entry), $0) } }, uniquingKeysWith: { first, _ in first })
        var answered = before
        for entry in entries {
            let id = conversationId(entry)
            guard let saved = remembering.removeValue(forKey: id), saved.pid == entry.pid, saved.startedAt == entry.startedAt else { continue }
            if former[id] == nil, !saved.previous.isEmpty { former[id] = saved.previous }
            guard chosen[id] == nil else { continue }
            retire(id, as: saved.name)
            nativeNameById[id] = saved.native
            answered[id] = answered[id] ?? saved.name
        }
        var preferred: [String: String] = [:]
        var sources: [String: AgentNameSource] = [:]
        var outranked: [String: String] = [:]
        var owned: [String: String] = [:]
        for entry in entries {
            let id = conversationId(entry)
            if !(placed[id].map { [.title, .pane, .agent].contains($0.place.level) } ?? false),
               let own = (nativeNames[id] ?? entry.explicitName).flatMap(usable) { owned[id] = own }
        }
        let aliased = Dictionary(grouping: entries.compactMap { entry in
            entry.alias.flatMap(usable).map { (key: AgentHandles.matchKey($0), id: conversationId(entry)) }
        }, by: \.key).mapValues { $0.map(\.id) }
        for ids in Dictionary(grouping: owned.keys.sorted(), by: { AgentHandles.matchKey(owned[$0]!) }).values {
            let base = owned[ids[0]]!
            let rivals = (aliased[AgentHandles.matchKey(base)] ?? []).filter { !ids.contains($0) }
            guard ids.count + rivals.count > 1 else { continue }
            let spaces = (ids + rivals).map { workspace($0, apartFrom: base) }
            guard spaces.allSatisfy({ $0 != nil }), Set(spaces.compactMap { $0.map(AgentHandles.matchKey) }).count == spaces.count else { continue }
            for (id, space) in zip(ids, spaces) { owned[id] = usable("\(space!) \(owned[id]!)") ?? owned[id] }
        }
        for entry in entries {
            let id = conversationId(entry)
            let paneNamed = placed[id].map { [.title, .pane, .agent].contains($0.place.level) } ?? false
            let own = paneNamed ? (nativeNames[id] ?? entry.explicitName).flatMap(usable) : owned[id]
            let reported = paneNamed ? nil : own
            if paneNamed { outranked[id] = own }
            let kept = excluded.contains(id) || unplaced.contains(id) ? nativeNameById[id] : nil
            let native = reported ?? placed[id]?.name ?? kept
            sources[id] = reported != nil ? .agent : placed[id] != nil ? .place : kept != nil ? sourceById[id] ?? .folder : .folder
            preferred[id] = native
            if chosen[id] == nil, native != nativeNameById[id] || (!entry.folder.isEmpty && folderUnknown.contains(id)) {
                handleById[id] = nil
                retired[id] = nil
            }
            nativeNameById[id] = native
        }
        var inUse = Set(handleById.values.map(AgentHandles.matchKey))
        let chosenBy = Dictionary(grouping: chosen, by: { AgentHandles.matchKey($0.value) }).mapValues { Set($0.map(\.key)) }
        let held = Set(remembering.values.map { AgentHandles.matchKey($0.name) })
        for entry in entries where handleById[conversationId(entry)] == nil {
            let id = conversationId(entry)
            guard let previous = chosen[id] ?? retired[id]?.name else { continue }
            let key = AgentHandles.matchKey(previous)
            let chosenByAnother = chosenBy[key].map { !$0.subtracting([id]).isEmpty } ?? false
            guard !inUse.contains(key), !chosenByAnother, !held.contains(key) else { continue }
            handleById[id] = previous
            inUse.insert(key)
        }
        let away = Set(chosen.filter { !liveIds.contains($0.key) }.values).union(remembering.values.map(\.name))
        let named = entries.filter { preferred[conversationId($0)] != nil }.sorted { conversationId($0) < conversationId($1) }
        let unnamed = entries.filter { preferred[conversationId($0)] == nil }
        handleById = AgentHandles.assign(
            (named + unnamed).map { AgentHandles.Conversation(id: conversationId($0), folder: $0.nameBase, name: preferred[conversationId($0)]) },
            existing: handleById, reserved: away)
        for (id, old) in answered where liveIds.contains(id) {
            if let now = handleById[id], AgentHandles.matchKey(now) != AgentHandles.matchKey(old) { former[id] = [old] }
        }
        former = former.filter { liveIds.contains($0.key) }
        folderUnknown = Set(entries.filter { $0.folder.isEmpty && preferred[conversationId($0)] == nil }.map(conversationId))
        sourceById = sources
        placeNameById = placed.mapValues(\.place).merging(placeNameById.filter { unplaced.contains($0.key) }) { now, _ in now }
        preferredById = preferred
        let assignedKeys = Set(handleById.values.map(AgentHandles.matchKey))
        let agentById = Dictionary(entries.map { (conversationId($0), $0.agent) }, uniquingKeysWith: { first, _ in first })
        placeShared = Dictionary(sharing.values.filter { !assignedKeys.contains(AgentHandles.matchKey($0.label)) }.map { sharedGroups in
            let shared = (label: sharedGroups.label, members: union(sharedGroups.groups.map { membersByKey[$0] ?? [] }), surface: sharedGroups.surface)
            let agents = shared.members.compactMap { agentById[$0] }
            return (shared.label, AgentRecipient.SharedName(
                names: shared.members.compactMap { handleById[$0] }.sorted(),
                tellApartIn: Set(agents).count < agents.count ? shared.surface : nil))
        }, uniquingKeysWith: { first, _ in first })
        var sharedByKey = Dictionary(grouping: placeShared.keys, by: AgentHandles.matchKey)
        for (word, other) in otherNames(entries: entries, places: known, containerHolders: containerHolders, outranked: outranked, usable: usable) {
            let key = AgentHandles.matchKey(word)
            if case .also = other.kind, other.names.count == 1 {
                for shared in sharedByKey[key] ?? [] { placeShared[shared] = nil }
                placeShared[word] = other
                sharedByKey[key] = [word]
            } else if sharedByKey[key] == nil {
                placeShared[word] = other
                sharedByKey[key] = [word]
            }
        }
        indexPreviousNames()

        let othersByHandle = otherNamesByHandle()
        let next = entries.map {
            AgentConversation(
                id: conversationId($0), agent: $0.agent, pid: $0.pid, cwd: $0.cwd,
                handle: handleById[conversationId($0)] ?? AgentHandles.base(forFolder: $0.nameBase),
                state: $0.state, connectorLive: live.contains(conversationId($0)), title: titles[conversationId($0)],
                startedAt: $0.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }, setup: $0.setup,
                nameSource: chosen[conversationId($0)] != nil ? .chosen : sources[conversationId($0)] ?? .folder,
                placeName: placeNameById[conversationId($0)],
                placeSurface: known[conversationId($0)]?.surface, otherNames: handleById[conversationId($0)].flatMap { othersByHandle[$0] } ?? [],
                placeUnreadSince: unreadSince[conversationId($0)], host: $0.host, innerAgent: $0.innerAgent)
        }.sorted { $0.handle < $1.handle }
        let shown = next.filter { !excluded.contains($0.id) }
        let excludedNow = next.filter { excluded.contains($0.id) }
        for id in liveIds { retired[id] = nil }
        capRetired()
        nativeNameById = nativeNameById.filter { liveIds.contains($0.key) || remembering[$0.key] != nil || retired[$0.key] != nil }
        if shown != conversations || excludedNow != disconnected {
            conversations = shown
            disconnected = excludedNow
            revision += 1
        }
        rememberAll()
    }

    private func otherNames(
        entries: [AgentSession], places: [String: AgentPlace], containerHolders: [String: [String]], outranked: [String: String],
        usable: (String) -> String?
    ) -> [String: AgentRecipient.SharedName] {
        let names = Set(handleById.values.map(AgentHandles.matchKey))
        var found: [String: (word: String, ids: [String], kind: AgentRecipient.SharedName.Kind)] = [:]
        var foundIds: [String: Set<String>] = [:]
        for entry in entries {
            let id = AgentSessionID.make(agent: entry.agent, native: entry.id)
            guard handleById[id] != nil else { continue }
            let fromPlace: [(text: String, kind: AgentRecipient.SharedName.Kind)] = places[id].map { place in place.labels.compactMap { label in
                let seenAs = "\(label.surface ?? place.surface) \([.agent, .title].contains(label.level) || label.term != nil ? label.word : "\(label.word) label")"
                if label.onlyAfterVerb { return (label.text, .afterVerb(seenAs)) }
                switch label.level {
                case .agent, .pane: return (label.text, .also(seenAs))
                case .title: return (label.text, .afterVerb(seenAs))
                case .tab, .workspace:
                    let alone = containerHolders[label.container]?.count == 1
                    return alone ? (label.text, .held(seenAs)) : nil
                }
            } } ?? []
            let own = outranked[id].map { [(text: $0, kind: AgentRecipient.SharedName.Kind.afterVerb("agent\u{2019}s own name"))] } ?? []
            let alias = entry.alias.map { [(text: $0, kind: AgentRecipient.SharedName.Kind.also("agent\u{2019}s own name"))] } ?? []
            for (text, kind) in fromPlace + own + alias {
                guard let word = usable(text) else { continue }
                let key = AgentHandles.matchKey(word)
                guard !names.contains(key) else { continue }
                guard found[key] != nil else {
                    found[key] = (word, [id], kind)
                    foundIds[key] = [id]
                    continue
                }
                let earlier = found[key]!.kind
                if foundIds[key, default: []].insert(id).inserted {
                    found[key]?.ids.append(id)
                    found[key]?.kind = Self.weaker(earlier, kind)
                } else if Self.weaker(earlier, kind) != kind {
                    found[key]?.kind = kind
                }
            }
        }
        return Dictionary(found.values.map { other in
            (other.word, AgentRecipient.SharedName(names: other.ids.compactMap { handleById[$0] }.sorted(), kind: other.kind))
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func weaker(_ one: AgentRecipient.SharedName.Kind, _ other: AgentRecipient.SharedName.Kind) -> AgentRecipient.SharedName.Kind {
        func rank(_ kind: AgentRecipient.SharedName.Kind) -> Int {
            switch kind {
            case .held: 0
            case .afterVerb: 1
            case .also: 2
            case .place: 3
            }
        }
        return rank(one) <= rank(other) ? one : other
    }

    public func otherNames(for id: String) -> [String] {
        handleById[id].flatMap { otherNamesByHandle()[$0] } ?? []
    }

    private func otherNamesByHandle() -> [String: [String]] {
        var byHandle: [String: [String]] = [:]
        for (word, shared) in placeShared where shared.names.count == 1 {
            switch shared.kind {
            case .also, .afterVerb: byHandle[shared.names[0], default: []].append(word)
            case .place, .held: break
            }
        }
        return byHandle.mapValues { $0.sorted() }
    }

    public func renameProblem(_ id: String, to raw: String) -> AgentHandles.RenameError? {
        let handle = AgentHandles.normalize(raw)
        if handle.isEmpty { return .empty }
        if AgentHandles.isReserved(handle) { return .reserved }
        let held = Array(handleById.filter { $0.key != id }.values)
            + Array(chosen.filter { $0.key != id && handleById[$0.key] == nil }.values)
            + remembering.filter { $0.key != id }.values.map(\.name)
            + placeShared.filter { entry in
                guard case .also = entry.value.kind else { return false }
                return entry.value.names != [handleById[id]].compactMap { $0 }
            }.keys
        return held.contains { AgentHandles.matchKey($0) == AgentHandles.matchKey(handle) } ? .taken : nil
    }

    public struct DefaultName: Equatable, Sendable {
        public var name: String
        public var source: AgentNameSource
        public var place: AgentPlaceName?
        public var otherNames: [String]

        public init(name: String, source: AgentNameSource, place: AgentPlaceName?, otherNames: [String] = []) {
            self.name = name
            self.source = source
            self.place = place
            self.otherNames = otherNames
        }
    }

    public func defaultName(for id: String) -> DefaultName? {
        guard let conversation = (conversations + disconnected).first(where: { $0.id == id }) else { return nil }
        let source = sourceById[id] ?? .folder
        let place = placeNameById[id]
        let others = otherNames(for: id)
        guard chosen[id] != nil else { return DefaultName(name: conversation.handle, source: source, place: place, otherNames: others) }
        let held = Array(handleById.filter { $0.key != id }.values)
            + Array(chosen.filter { $0.key != id }.values)
            + remembering.filter { $0.key != id }.values.map(\.name)
        let folder = AgentSession.nameBase(cwd: conversation.cwd, agent: conversation.agent)
        let name = AgentHandles.assign(
            [AgentHandles.Conversation(id: id, folder: folder, name: preferredById[id])], existing: [:], reserved: Set(held))[id]
        return name.map { DefaultName(name: $0, source: source, place: place, otherNames: others) }
    }

    public mutating func useDefaultName(_ id: String) {
        guard chosen.removeValue(forKey: id) != nil else { return }
        if let replaced = handleById.removeValue(forKey: id) { former[id] = [replaced] }
        retired[id] = nil
        indexPreviousNames()
        rememberAll()
        revision += 1
    }

    public mutating func carryChosenName(from old: String, to new: String, previous carried: [String]) -> Bool {
        guard chosen[new] == nil, handleById[new] != nil, let name = chosen[old] else { return false }
        defer {
            indexPreviousNames()
            rememberAll()
        }
        chosen[old] = nil
        remembering[old] = nil
        handleById[old] = nil
        retired[old] = nil
        former[old] = nil
        do {
            try rename(new, to: name)
            former[new] = Self.previous(carried, apartFrom: handleById[new])
            return true
        } catch {
            chosen[old] = name
            return false
        }
    }

    public mutating func rename(_ id: String, to raw: String) throws {
        if let problem = renameProblem(id, to: raw) { throw problem }
        let old = handleById[id]
        let wasChosen = chosen[id] != nil
        handleById = try AgentHandles.rename(id, to: raw, in: handleById)
        chosen[id] = handleById[id]
        if let old, let now = handleById[id], AgentHandles.matchKey(old) != AgentHandles.matchKey(now) {
            let kept = wasChosen ? [] : (former[id] ?? []).filter { AgentHandles.matchKey($0) != AgentHandles.matchKey(now) }
            former[id] = [old] + kept.filter { AgentHandles.matchKey($0) != AgentHandles.matchKey(old) }
        }
        indexPreviousNames()
        func renamed(_ conversation: AgentConversation) -> AgentConversation {
            var c = conversation
            c.handle = handleById[c.id] ?? c.handle
            if c.id == id { c.nameSource = .chosen }
            return c
        }
        conversations = conversations.map(renamed)
            .sorted { $0.handle < $1.handle }
        disconnected = disconnected.map(renamed)
            .sorted { $0.handle < $1.handle }
        rememberAll()
        revision += 1
    }
}
