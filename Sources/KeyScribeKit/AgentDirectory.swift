import Foundation

public struct AgentConversation: Equatable, Sendable {
    public var id: String
    public var agent: String
    public var pid: Int
    public var cwd: String
    public var handle: String
    public var state: AgentLiveState
    public var connectorLive: Bool
}

public struct AgentDirectory: Sendable {
    public private(set) var conversations: [AgentConversation] = []
    public private(set) var revision = 0
    private var handleById: [String: String] = [:]
    private var retired: [String: String] = [:]
    private var chosen: [String: String] = [:]

    public init() {}

    public var handles: [String] { conversations.map(\.handle) }

    public func conversation(handle: String) -> AgentConversation? {
        let wanted = AgentHandles.matchKey(handle)
        return conversations.first { AgentHandles.matchKey($0.handle) == wanted }
    }

    public func conversation(pid: Int) -> AgentConversation? {
        conversations.first { $0.pid == pid }
    }

    public mutating func update(claude entries: [ClaudeRegistryEntry], live: Set<String>) {
        let liveIds = Set(entries.map(\.sessionId))
        for (id, handle) in handleById where !liveIds.contains(id) {
            retired[id] = handle
        }
        handleById = handleById.filter { liveIds.contains($0.key) }
        for entry in entries where handleById[entry.sessionId] == nil {
            guard let previous = retired[entry.sessionId] else { continue }
            let key = AgentHandles.matchKey(previous)
            let inUse = handleById.values.contains { AgentHandles.matchKey($0) == key }
            let chosenByAnother = chosen.contains { $0.key != entry.sessionId && AgentHandles.matchKey($0.value) == key }
            if !inUse && !chosenByAnother { handleById[entry.sessionId] = previous }
        }
        let away = Set(chosen.filter { !liveIds.contains($0.key) }.values)
        handleById = AgentHandles.assign(
            entries.map { AgentHandles.Conversation(id: $0.sessionId, folder: $0.folder) }, existing: handleById, reserved: away)

        let next = entries.map {
            AgentConversation(
                id: $0.sessionId, agent: "claude", pid: $0.pid, cwd: $0.cwd,
                handle: handleById[$0.sessionId] ?? AgentHandles.base(forFolder: $0.folder),
                state: $0.liveState, connectorLive: live.contains($0.sessionId))
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
