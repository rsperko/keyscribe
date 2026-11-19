import Foundation

public enum CodexThreadActiveFlag: Equatable, Sendable {
    case waitingOnApproval
    case waitingOnUserInput
    case unknown(String)

    init(_ value: Any) {
        switch value as? String {
        case "waitingOnApproval": self = .waitingOnApproval
        case "waitingOnUserInput": self = .waitingOnUserInput
        case let other: self = .unknown(other ?? "")
        }
    }
}

public enum CodexThreadStatus: Equatable, Sendable {
    case notLoaded
    case idle
    case systemError
    case active([CodexThreadActiveFlag])
    case unknown(String)

    init(_ value: Any?) {
        let status = value as? [String: Any]
        switch status?["type"] as? String {
        case "notLoaded": self = .notLoaded
        case "idle": self = .idle
        case "systemError": self = .systemError
        case "active": self = .active(((status?["activeFlags"] as? [Any]) ?? []).map(CodexThreadActiveFlag.init))
        case let other: self = .unknown(other ?? "")
        }
    }

    public var liveState: AgentLiveState? {
        switch self {
        case .notLoaded: return nil
        case .idle: return .idle
        case .systemError, .unknown: return .userDialog
        case .active(let flags):
            if flags.contains(where: { if case .unknown = $0 { true } else { false } }) { return .userDialog }
            if flags.contains(.waitingOnApproval) { return .waitingApproval }
            if flags.contains(.waitingOnUserInput) { return .waitingQuestion }
            return .working
        }
    }
}

public struct CodexThread: Equatable, Sendable {
    public static let agent = "codex"

    public var id: String
    public var cwd: String
    public var name: String?
    public var ephemeral: Bool
    public var threadSource: String?
    public var status: CodexThreadStatus
    public var createdAt: Int?
    public var forkedFromId: String?
    public var parentThreadId: String?

    public init(
        id: String, cwd: String, name: String? = nil, ephemeral: Bool = false, threadSource: String? = nil, status: CodexThreadStatus,
        createdAt: Int? = nil, forkedFromId: String? = nil, parentThreadId: String? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.name = name
        self.ephemeral = ephemeral
        self.threadSource = threadSource
        self.status = status
        self.createdAt = createdAt
        self.forkedFromId = forkedFromId
        self.parentThreadId = parentThreadId
    }

    init?(_ value: Any?) {
        guard let thread = value as? [String: Any], let id = CodexJSON.text(thread["id"]), let cwd = CodexJSON.text(thread["cwd"]) else { return nil }
        self.init(
            id: id, cwd: cwd, name: thread["name"] as? String, ephemeral: CodexJSON.bool(thread["ephemeral"]) ?? false,
            threadSource: thread["threadSource"] as? String, status: CodexThreadStatus(thread["status"]), createdAt: CodexJSON.int(thread["createdAt"]),
            forkedFromId: thread["forkedFromId"] as? String, parentThreadId: thread["parentThreadId"] as? String)
    }

    public var isListed: Bool {
        status != .notLoaded && !ephemeral && (threadSource == nil || threadSource == "user")
    }

    public var title: String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public func location(instance: String) -> AgentHostLocation {
        AgentHostLocation(host: Self.agent, instance: instance, native: id)
    }

    public func session(instance: String) -> AgentSession? {
        guard isListed, let state = status.liveState else { return nil }
        return AgentSession(
            agent: Self.agent, id: id, pid: nil, cwd: cwd, state: state, startedAt: createdAt, host: location(instance: instance))
    }
}
