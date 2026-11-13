import Foundation

public struct ClaudeRegistryEntry: Equatable, Sendable {
    public var pid: Int
    public var sessionId: String
    public var cwd: String
    public var name: String?
    public var nameSource: String?
    public var status: String
    public var waitingFor: String?
    public var startedAt: Int?
    public var configDir: String?

    public init(
        pid: Int, sessionId: String, cwd: String, name: String?, status: String, waitingFor: String?, nameSource: String? = nil,
        startedAt: Int? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.nameSource = nameSource
        self.status = status
        self.waitingFor = waitingFor
        self.startedAt = startedAt
    }

    public var folder: String { URL(fileURLWithPath: cwd).lastPathComponent }

    public var explicitName: String? {
        guard nameSource == "user", let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

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
        var nameSource: String?
        var status: String?
        var waitingFor: String?
        var startedAt: Int?
    }

    public enum Record: Equatable, Sendable {
        case interactive(ClaudeRegistryEntry)
        case other
        case invalid
    }

    public static func read(_ data: Data) -> Record {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data), let kind = w.kind, !kind.isEmpty else { return .invalid }
        guard kind == "interactive" else { return .other }
        guard let pid = w.pid, let sessionId = w.sessionId, let cwd = w.cwd else { return .invalid }
        return .interactive(ClaudeRegistryEntry(
            pid: pid, sessionId: sessionId, cwd: cwd, name: w.name, status: w.status ?? "busy", waitingFor: w.waitingFor, nameSource: w.nameSource,
            startedAt: w.startedAt))
    }

    public static func decode(_ data: Data) -> ClaudeRegistryEntry? {
        if case .interactive(let entry) = read(data) { return entry }
        return nil
    }
}

extension ClaudeRegistryEntry {
    public var session: AgentSession {
        AgentSession(agent: AgentKind.claude.id, id: sessionId, pid: pid, cwd: cwd, explicitName: explicitName, state: liveState, startedAt: startedAt,
            title: AgentTitle(generatedTitle: nameSource == "auto" ? name : nil),
            setup: configDir)
    }
}

extension AgentKind {
    public static let claude = AgentKind(
        id: "claude", displayName: "Claude Code", connectorName: "Claude Code connector", reloadCommand: "/reload-plugins",
        connectorFeatures: ["focus", "label", "readiness", "notify", "fill", "check"])
}

extension AgentDirectory {
    public mutating func update(
        claude entries: [ClaudeRegistryEntry], live: Set<String>, titles: [String: String] = [:], nativeNames: [String: String?] = [:],
        running: (RememberedName) -> Bool = { _ in false }
    ) {
        update(entries: entries.map(\.session), live: live, titles: titles, nativeNames: nativeNames, running: running)
    }
}

extension AgentProcesses.Rule {
    public static let claude = AgentProcesses.Rule(
        agent: AgentKind.claude.id, names: ["node", "claude"], anyVersionName: true, command: "claude", setupVariable: "CLAUDE_CONFIG_DIR",
        defaultSetup: "~/.claude", needsTerminal: false)
}
