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

    public init(
        id: String, agent: String, pid: Int, cwd: String, handle: String, state: AgentLiveState, connectorLive: Bool,
        title: String? = nil, startedAt: Date? = nil
    ) {
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
    public private(set) var revision = 0
    private var handleById: [String: String] = [:]
    private var retired: [String: String] = [:]
    private var chosen: [String: String] = [:]
    private var nativeNameById: [String: String] = [:]
    private var remembering: [String: RememberedName]
    private var startById: [String: Int] = [:]

    public init(chosen: [String: String] = [:], remembered: [String: RememberedName] = [:]) {
        self.chosen = chosen
        self.remembering = remembered
    }

    public var chosenNames: [String: String] { chosen }

    public var remembered: [String: RememberedName] {
        var names = remembering
        for conversation in conversations where chosen[conversation.id] == nil {
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
        running: (RememberedName) -> Bool = { _ in false }
    ) {
        func conversationId(_ entry: AgentSession) -> String { AgentSessionID.make(agent: entry.agent, native: entry.id) }
        let liveIds = Set(entries.map(conversationId))
        for conversation in conversations where !liveIds.contains(conversation.id) && chosen[conversation.id] == nil {
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
        for entry in entries {
            let id = conversationId(entry)
            let native = (nativeNames[id] ?? entry.explicitName).map(AgentHandles.normalize)
                .flatMap { $0.isEmpty || AgentHandles.isReserved($0) ? nil : $0 }
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

        let next = entries.map {
            AgentConversation(
                id: conversationId($0), agent: $0.agent, pid: $0.pid, cwd: $0.cwd,
                handle: handleById[conversationId($0)] ?? AgentHandles.base(forFolder: $0.folder),
                state: $0.state, connectorLive: live.contains(conversationId($0)), title: titles[conversationId($0)],
                startedAt: $0.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
        }.sorted { $0.handle < $1.handle }
        if next != conversations {
            conversations = next
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

    public mutating func rename(_ id: String, to raw: String) throws {
        if let problem = renameProblem(id, to: raw) { throw problem }
        handleById = try AgentHandles.rename(id, to: raw, in: handleById)
        chosen[id] = handleById[id]
        conversations = conversations.map { var c = $0; c.handle = handleById[c.id] ?? c.handle; return c }
            .sorted { $0.handle < $1.handle }
        revision += 1
    }
}
