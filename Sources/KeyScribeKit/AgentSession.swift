import Foundation

public struct AgentKind: Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var connectorName: String
    public var reloadCommand: String?
    public var connectorFeatures: Set<String>

    public init(id: String, displayName: String, connectorName: String, reloadCommand: String? = nil, connectorFeatures: Set<String> = []) {
        self.id = id
        self.displayName = displayName
        self.connectorName = connectorName
        self.reloadCommand = reloadCommand
        self.connectorFeatures = connectorFeatures
    }
}

public struct AgentSession: Equatable, Sendable {
    public var agent: String
    public var id: String
    public var pid: Int
    public var cwd: String
    public var explicitName: String?
    public var state: AgentLiveState
    public var startedAt: Int?
    public var title: AgentTitle
    public var setup: String?

    public init(
        agent: String, id: String, pid: Int, cwd: String, explicitName: String? = nil, state: AgentLiveState, startedAt: Int? = nil,
        title: AgentTitle = AgentTitle(), setup: String? = nil
    ) {
        self.setup = setup
        self.agent = agent
        self.id = id
        self.pid = pid
        self.cwd = cwd
        self.explicitName = explicitName
        self.state = state
        self.startedAt = startedAt
        self.title = title
    }

    public var folder: String { URL(fileURLWithPath: cwd).lastPathComponent }
}

public struct AgentTitle: Equatable, Sendable {
    public var explicitName: String?
    public var generatedTitle: String?

    public init(explicitName: String? = nil, generatedTitle: String? = nil) {
        self.explicitName = explicitName
        self.generatedTitle = generatedTitle
    }
}

public enum AgentSessionID {
    public static let separator: Character = ":"

    public static func make(agent: String, native: String) -> String {
        "\(agent)\(separator)\(native)"
    }

    public static func split(_ id: String) -> (agent: String, native: String)? {
        guard let at = id.firstIndex(of: separator), at != id.startIndex else { return nil }
        return (String(id[..<at]), String(id[id.index(after: at)...]))
    }

    public static func native(_ id: String) -> String { split(id)?.native ?? id }

    public static func agent(of id: String) -> String? { split(id)?.agent }
}
