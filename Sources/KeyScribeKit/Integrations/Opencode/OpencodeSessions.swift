import Foundation

public struct OpencodeSession: Equatable, Sendable {
    public static let agent = "opencode"

    public var id: String
    public var title: String?
    public var directory: String
    public var createdAt: Int?

    public init(id: String, title: String?, directory: String, createdAt: Int?) {
        self.id = id
        self.title = title
        self.directory = directory
        self.createdAt = createdAt
    }

    public var shownTitle: String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public func location(instance: String) -> AgentHostLocation {
        AgentHostLocation(host: Self.agent, instance: instance, native: id)
    }

    public func agentSession(instance: String, running: Bool, asking: AgentPrompt?) -> AgentSession {
        let state: AgentLiveState = asking.map { AgentLiveState.userDialog.named(by: $0) } ?? (running ? .working : .idle)
        return AgentSession(agent: Self.agent, id: id, pid: nil, cwd: directory, state: state, startedAt: createdAt, host: location(instance: instance))
    }
}

public enum OpencodeSessions {
    public static func parse(_ data: Data) -> [OpencodeSession]? {
        guard let listed = OpencodeJSON.object(data)?["data"] as? [Any] else { return nil }
        return listed.compactMap { entry in
            guard let session = entry as? [String: Any], let id = OpencodeJSON.text(session["id"]), session["parentID"] == nil,
                  let time = session["time"] as? [String: Any], time["archived"] == nil,
                  let directory = OpencodeJSON.text((session["location"] as? [String: Any])?["directory"])
            else { return nil }
            return OpencodeSession(id: id, title: session["title"] as? String, directory: directory, createdAt: OpencodeJSON.int(time["created"]))
        }
    }

    public static func active(_ data: Data) -> Set<String>? {
        guard let running = OpencodeJSON.object(data)?["data"] as? [String: Any] else { return nil }
        return Set(running.keys)
    }
}
