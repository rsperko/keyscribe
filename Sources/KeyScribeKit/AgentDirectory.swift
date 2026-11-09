import Foundation

public struct AgentConversation: Equatable, Sendable {
    public var id: String
    public var agent: String
    public var pid: Int
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

    public init(
        id: String, agent: String, pid: Int, cwd: String, handle: String, state: AgentLiveState, connectorLive: Bool,
        title: String? = nil, startedAt: Date? = nil, setup: String? = nil, nameSource: AgentNameSource = .folder,
        placeName: AgentPlaceName? = nil, placeSurface: String? = nil
    ) {
        self.placeSurface = placeSurface
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

    public init(surface: String, level: AgentPlace.Level, label: String) {
        self.surface = surface
        self.level = level
        self.label = label
    }
}

public struct RememberedName: Codable, Equatable, Sendable {
    public var name: String
    public var pid: Int
    public var startedAt: Int
    public var native: String?
    public var agent: String

    public init(name: String, pid: Int, startedAt: Int, native: String?, agent: String = "") {
        self.name = name
        self.pid = pid
        self.startedAt = startedAt
        self.native = native
        self.agent = agent
    }

    enum CodingKeys: String, CodingKey {
        case name, pid, native, agent
        case startedAt = "started_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pid = try c.decode(Int.self, forKey: .pid)
        startedAt = try c.decode(Int.self, forKey: .startedAt)
        native = try c.decodeIfPresent(String.self, forKey: .native)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
    }
}

public struct AgentDirectory: Sendable {
    public private(set) var conversations: [AgentConversation] = []
    public private(set) var disconnected: [AgentConversation] = []
    public private(set) var revision = 0
    private var handleById: [String: String] = [:]
    private var retired: [String: String] = [:]
    private var chosen: [String: String] = [:]
    private var nativeNameById: [String: String] = [:]
    private var remembering: [String: RememberedName]
    private var startById: [String: Int] = [:]
    private var preferredById: [String: String] = [:]
    private var sourceById: [String: AgentNameSource] = [:]
    private var placeNameById: [String: AgentPlaceName] = [:]
    public private(set) var sharedPlaceNames: [String: AgentRecipient.SharedName] = [:]

    public init(chosen: [String: String] = [:], remembered: [String: RememberedName] = [:]) {
        self.chosen = chosen
        self.remembering = remembered
    }

    public var chosenNames: [String: String] { chosen }

    public var remembered: [String: RememberedName] {
        var names = remembering
        for conversation in conversations + disconnected where chosen[conversation.id] == nil {
            guard let start = startById[conversation.id], let name = handleById[conversation.id] else { continue }
            names[conversation.id] = RememberedName(
                name: name, pid: conversation.pid, startedAt: start, native: nativeNameById[conversation.id], agent: conversation.agent)
        }
        return names
    }

    public var handles: [String] { conversations.map(\.handle) }

    public func conversation(handle: String) -> AgentConversation? {
        let wanted = AgentHandles.matchKey(handle)
        return conversations.first { AgentHandles.matchKey($0.handle) == wanted }
    }

    public func conversation(pid: Int) -> AgentConversation? {
        conversations.first { $0.pid == pid }
    }

    public mutating func update(
        entries: [AgentSession], live: Set<String>, titles: [String: String] = [:], nativeNames: [String: String?] = [:],
        running: (RememberedName) -> Bool = { _ in false }, excluded: Set<String> = [], places: [String: AgentPlace] = [:],
        unplaced: Set<String> = []
    ) {
        func conversationId(_ entry: AgentSession) -> String { AgentSessionID.make(agent: entry.agent, native: entry.id) }
        func usable(_ name: String) -> String? {
            let normalized = AgentHandles.normalize(name)
            return normalized.isEmpty || AgentHandles.isReserved(normalized) ? nil : normalized
        }
        var placed: [String: (name: String, place: AgentPlaceName)] = [:]
        var sharing: [String: (label: String, members: [String], surface: String)] = [:]
        let known = places
        var labelled: [(entry: AgentSession, place: AgentPlace, label: AgentPlace.Label, base: String, key: String, members: [String])] = []
        for entry in entries {
            let id = conversationId(entry)
            guard let place = known[id], let label = place.labels.first(where: { usable($0.text) != nil }),
                  let base = usable(label.text)
            else { continue }
            let members = entries.map(conversationId).filter { known[$0]?.containers.contains(label.container) == true }
            labelled.append((entry, place, label, base, AgentHandles.matchKey(base), members))
        }
        let membersByKey = Dictionary(grouping: labelled, by: \.key).mapValues { group in
            group.flatMap(\.members).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        }
        for item in labelled {
            let id = conversationId(item.entry)
            let qualifiedName = usable("\(item.base) \(item.entry.agent)")
            let earlier = [nativeNameById[id], remembering[id]?.native].compactMap { $0 }.map(AgentHandles.matchKey)
            let stays = qualifiedName.map { earlier.contains(AgentHandles.matchKey($0)) } ?? false
            let members = membersByKey[item.key] ?? item.members
            let qualifies = members.count > 1 || stays
            placed[id] = (qualifies ? qualifiedName ?? item.base : item.base,
                          AgentPlaceName(surface: item.place.surface, level: item.label.level, label: item.label.text))
            guard qualifies else { continue }
            let held = sharing[item.key]?.members ?? []
            sharing[item.key] = (sharing[item.key]?.label ?? item.base, held + members.filter { !held.contains($0) }, item.place.surface)
        }
        let liveIds = Set(entries.map(conversationId))
        for conversation in conversations + disconnected where !liveIds.contains(conversation.id) && chosen[conversation.id] == nil {
            guard let start = startById[conversation.id], let name = handleById[conversation.id] else { continue }
            remembering[conversation.id] = RememberedName(
                name: name, pid: conversation.pid, startedAt: start, native: nativeNameById[conversation.id], agent: conversation.agent)
        }
        remembering = remembering.filter { id, saved in
            guard !liveIds.contains(id) else { return true }
            let replaced = entries.contains { $0.pid == saved.pid && $0.startedAt == saved.startedAt }
            return !replaced && running(saved)
        }
        for (id, handle) in handleById where !liveIds.contains(id) {
            retired[id] = handle
        }
        handleById = handleById.filter { liveIds.contains($0.key) }
        startById = Dictionary(entries.compactMap { entry in entry.startedAt.map { (conversationId(entry), $0) } }, uniquingKeysWith: { first, _ in first })
        for entry in entries {
            guard let saved = remembering.removeValue(forKey: conversationId(entry)), chosen[conversationId(entry)] == nil,
                  saved.pid == entry.pid, saved.startedAt == entry.startedAt
            else { continue }
            retired[conversationId(entry)] = saved.name
            nativeNameById[conversationId(entry)] = saved.native
        }
        var preferred: [String: String] = [:]
        var sources: [String: AgentNameSource] = [:]
        for entry in entries {
            let id = conversationId(entry)
            let reported = (nativeNames[id] ?? entry.explicitName).flatMap(usable)
            let kept = excluded.contains(id) || unplaced.contains(id) ? nativeNameById[id] : nil
            let native = reported ?? placed[id]?.name ?? kept
            sources[id] = reported != nil ? .agent : placed[id] != nil ? .place : kept != nil ? sourceById[id] ?? .folder : .folder
            preferred[id] = native
            if chosen[id] == nil, native != nativeNameById[id] {
                handleById[id] = nil
                retired[id] = nil
            }
            nativeNameById[id] = native
        }
        for entry in entries where handleById[conversationId(entry)] == nil {
            guard let previous = chosen[conversationId(entry)] ?? retired[conversationId(entry)] else { continue }
            let key = AgentHandles.matchKey(previous)
            let inUse = handleById.values.contains { AgentHandles.matchKey($0) == key }
            let chosenByAnother = chosen.contains { $0.key != conversationId(entry) && AgentHandles.matchKey($0.value) == key }
            let heldForAnother = remembering.values.contains { AgentHandles.matchKey($0.name) == key }
            if !inUse && !chosenByAnother && !heldForAnother { handleById[conversationId(entry)] = previous }
        }
        let away = Set(chosen.filter { !liveIds.contains($0.key) }.values).union(remembering.values.map(\.name))
        let named = entries.filter { preferred[conversationId($0)] != nil }.sorted { conversationId($0) < conversationId($1) }
        let unnamed = entries.filter { preferred[conversationId($0)] == nil }
        handleById = AgentHandles.assign(
            (named + unnamed).map { AgentHandles.Conversation(id: conversationId($0), folder: $0.folder, name: preferred[conversationId($0)]) },
            existing: handleById, reserved: away)
        sourceById = sources
        placeNameById = placed.mapValues(\.place).merging(placeNameById.filter { unplaced.contains($0.key) }) { now, _ in now }
        preferredById = preferred
        let assignedKeys = Set(handleById.values.map(AgentHandles.matchKey))
        sharedPlaceNames = Dictionary(sharing.values.filter { !assignedKeys.contains(AgentHandles.matchKey($0.label)) }.map { shared in
            let agents = entries.filter { shared.members.contains(conversationId($0)) }.map(\.agent)
            return (shared.label, AgentRecipient.SharedName(
                names: shared.members.compactMap { handleById[$0] }.sorted(),
                tellApartIn: Set(agents).count < agents.count ? shared.surface : nil))
        }, uniquingKeysWith: { first, _ in first })

        let next = entries.map {
            AgentConversation(
                id: conversationId($0), agent: $0.agent, pid: $0.pid, cwd: $0.cwd,
                handle: handleById[conversationId($0)] ?? AgentHandles.base(forFolder: $0.folder),
                state: $0.state, connectorLive: live.contains(conversationId($0)), title: titles[conversationId($0)],
                startedAt: $0.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }, setup: $0.setup,
                nameSource: chosen[conversationId($0)] != nil ? .chosen : sources[conversationId($0)] ?? .folder,
                placeName: placeNameById[conversationId($0)],
                placeSurface: known[conversationId($0)]?.surface)
        }.sorted { $0.handle < $1.handle }
        let shown = next.filter { !excluded.contains($0.id) }
        let excludedNow = next.filter { excluded.contains($0.id) }
        if shown != conversations || excludedNow != disconnected {
            conversations = shown
            disconnected = excludedNow
            revision += 1
        }
    }

    public func renameProblem(_ id: String, to raw: String) -> AgentHandles.RenameError? {
        let handle = AgentHandles.normalize(raw)
        if handle.isEmpty { return .empty }
        if AgentHandles.isReserved(handle) { return .reserved }
        let held = Array(handleById.filter { $0.key != id }.values)
            + Array(chosen.filter { $0.key != id && handleById[$0.key] == nil }.values)
            + remembering.filter { $0.key != id }.values.map(\.name)
        return held.contains { AgentHandles.matchKey($0) == AgentHandles.matchKey(handle) } ? .taken : nil
    }

    public struct DefaultName: Equatable, Sendable {
        public var name: String
        public var source: AgentNameSource
        public var place: AgentPlaceName?
    }

    public func defaultName(for id: String) -> DefaultName? {
        guard let conversation = (conversations + disconnected).first(where: { $0.id == id }) else { return nil }
        let source = sourceById[id] ?? .folder
        let place = placeNameById[id]
        guard chosen[id] != nil else { return DefaultName(name: conversation.handle, source: source, place: place) }
        let held = Array(handleById.filter { $0.key != id }.values)
            + Array(chosen.filter { $0.key != id }.values)
            + remembering.filter { $0.key != id }.values.map(\.name)
        let folder = URL(fileURLWithPath: conversation.cwd).lastPathComponent
        let name = AgentHandles.assign(
            [AgentHandles.Conversation(id: id, folder: folder, name: preferredById[id])], existing: [:], reserved: Set(held))[id]
        return name.map { DefaultName(name: $0, source: source, place: place) }
    }

    public mutating func useDefaultName(_ id: String) {
        guard chosen.removeValue(forKey: id) != nil else { return }
        handleById[id] = nil
        retired[id] = nil
        revision += 1
    }

    public mutating func rename(_ id: String, to raw: String) throws {
        if let problem = renameProblem(id, to: raw) { throw problem }
        handleById = try AgentHandles.rename(id, to: raw, in: handleById)
        chosen[id] = handleById[id]
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
        revision += 1
    }
}
