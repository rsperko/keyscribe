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

    public init(
        id: String, agent: String, pid: Int, cwd: String, handle: String, state: AgentLiveState, connectorLive: Bool,
        title: String? = nil
    ) {
        self.title = title
        self.id = id
        self.agent = agent
        self.pid = pid
        self.cwd = cwd
        self.handle = handle
        self.state = state
        self.connectorLive = connectorLive
    }
}

public struct AgentDirectory: Sendable {
    public private(set) var conversations: [AgentConversation] = []
    public private(set) var revision = 0
    private var handleById: [String: String] = [:]
    private var retired: [String: String] = [:]
    private var chosen: [String: String] = [:]
    private var nativeNameById: [String: String] = [:]

    public init(chosen: [String: String] = [:]) {
        self.chosen = chosen
    }

    public var chosenNames: [String: String] { chosen }

    public var handles: [String] { conversations.map(\.handle) }

    public func conversation(handle: String) -> AgentConversation? {
        let wanted = AgentHandles.matchKey(handle)
        return conversations.first { AgentHandles.matchKey($0.handle) == wanted }
    }

    public func conversation(pid: Int) -> AgentConversation? {
        conversations.first { $0.pid == pid }
    }

    public mutating func update(
        claude entries: [ClaudeRegistryEntry], live: Set<String>, titles: [String: String] = [:], nativeNames: [String: String?] = [:]
    ) {
        let liveIds = Set(entries.map(\.sessionId))
        for (id, handle) in handleById where !liveIds.contains(id) {
            retired[id] = handle
        }
        handleById = handleById.filter { liveIds.contains($0.key) }
        var preferred: [String: String] = [:]
        for entry in entries {
            let id = entry.sessionId
            let native = (nativeNames[id] ?? entry.explicitName).map(AgentHandles.normalize)
                .flatMap { $0.isEmpty || AgentHandles.isReserved($0) ? nil : $0 }
            preferred[id] = native
            if chosen[id] == nil, native != nativeNameById[id] {
                handleById[id] = nil
                retired[id] = nil
            }
            nativeNameById[id] = native
        }
        for entry in entries where handleById[entry.sessionId] == nil {
            guard let previous = chosen[entry.sessionId] ?? retired[entry.sessionId] else { continue }
            let key = AgentHandles.matchKey(previous)
            let inUse = handleById.values.contains { AgentHandles.matchKey($0) == key }
            let chosenByAnother = chosen.contains { $0.key != entry.sessionId && AgentHandles.matchKey($0.value) == key }
            if !inUse && !chosenByAnother { handleById[entry.sessionId] = previous }
        }
        let away = Set(chosen.filter { !liveIds.contains($0.key) }.values)
        let named = entries.filter { preferred[$0.sessionId] != nil }.sorted { $0.sessionId < $1.sessionId }
        let unnamed = entries.filter { preferred[$0.sessionId] == nil }
        handleById = AgentHandles.assign(
            (named + unnamed).map { AgentHandles.Conversation(id: $0.sessionId, folder: $0.folder, name: preferred[$0.sessionId]) },
            existing: handleById, reserved: away)

        let next = entries.map {
            AgentConversation(
                id: $0.sessionId, agent: "claude", pid: $0.pid, cwd: $0.cwd,
                handle: handleById[$0.sessionId] ?? AgentHandles.base(forFolder: $0.folder),
                state: $0.liveState, connectorLive: live.contains($0.sessionId), title: titles[$0.sessionId])
        }.sorted { $0.handle < $1.handle }
        if next != conversations {
            conversations = next
            revision += 1
        }
    }

    public mutating func rename(_ id: String, to raw: String) throws {
        let heldByAway = chosen.filter { $0.key != id && handleById[$0.key] == nil }.values
        if heldByAway.contains(where: { AgentHandles.matchKey($0) == AgentHandles.matchKey(raw) }) { throw AgentHandles.RenameError.taken }
        handleById = try AgentHandles.rename(id, to: raw, in: handleById)
        chosen[id] = handleById[id]
        conversations = conversations.map { var c = $0; c.handle = handleById[c.id] ?? c.handle; return c }
            .sorted { $0.handle < $1.handle }
        revision += 1
    }
}
