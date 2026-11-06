import Foundation

public struct ClaudeRegistryEntry: Equatable, Sendable {
    public var pid: Int
    public var sessionId: String
    public var cwd: String
    public var name: String?
    public var status: String
    public var waitingFor: String?

    public init(pid: Int, sessionId: String, cwd: String, name: String?, status: String, waitingFor: String?) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.status = status
        self.waitingFor = waitingFor
    }

    public var folder: String { URL(fileURLWithPath: cwd).lastPathComponent }

    public var liveState: AgentLiveState {
        switch status {
        case "idle": return .idle
        case "waiting":
            switch waitingFor {
            case "permission prompt", "sandbox request", "worker request": return .waitingApproval
            case "input needed": return .waitingQuestion
            default: return .userDialog
            }
        default: return .working
        }
    }

    private struct Wire: Decodable {
        var pid: Int?
        var sessionId: String?
        var cwd: String?
        var kind: String?
        var name: String?
        var status: String?
        var waitingFor: String?
    }

    public static func decode(_ data: Data) -> ClaudeRegistryEntry? {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data),
              w.kind == "interactive", let pid = w.pid, let sessionId = w.sessionId, let cwd = w.cwd
        else { return nil }
        return ClaudeRegistryEntry(pid: pid, sessionId: sessionId, cwd: cwd, name: w.name, status: w.status ?? "busy", waitingFor: w.waitingFor)
    }
}
