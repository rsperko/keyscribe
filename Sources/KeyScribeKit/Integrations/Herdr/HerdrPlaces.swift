import Foundation

public enum HerdrPlaces {
    public static let socketKey = "HERDR_SOCKET_PATH"
    public static let paneKey = "HERDR_PANE_ID"
    public static let executableKey = "HERDR_BIN_PATH"
    public static let processName = "herdr"

    public static func listCommands(
        socket: String, executable: String
    ) -> (panes: [String], tabs: [String], workspaces: [String], agents: [String]) {
        let herdr = ["/usr/bin/env", "-u", paneKey, "\(socketKey)=\(socket)", executable]
        return (herdr + ["pane", "list"], herdr + ["tab", "list"], herdr + ["workspace", "list"], herdr + ["agent", "list"])
    }

    public struct Listing: Equatable, Sendable {
        fileprivate var panes: [PaneList.Pane]
        fileprivate var tabs: [String: TabList.Tab]
        fileprivate var workspaces: [String: WorkspaceList.Workspace]
        fileprivate var agentNames: [String: String]
    }

    fileprivate struct AgentList: Decodable {
        struct Agent: Decodable {
            var pane_id: String
            var name: String?
        }
        struct Result: Decodable { var agents: [Agent] }
        var result: Result
    }

    fileprivate struct PaneList: Decodable {
        struct Session: Decodable, Equatable, Sendable {
            var agent: String
            var kind: String
            var value: String
        }
        struct Pane: Decodable, Equatable, Sendable {
            var pane_id: String
            var tab_id: String
            var workspace_id: String
            var label: String?
            var title: String?
            var agent: String?
            var agent_session: Session?
        }
        struct Result: Decodable { var panes: [Pane] }
        var result: Result
    }

    fileprivate struct TabList: Decodable {
        struct Tab: Decodable, Equatable, Sendable {
            var tab_id: String
            var label: String?
            var number: Int?
        }
        struct Result: Decodable { var tabs: [Tab] }
        var result: Result
    }

    fileprivate struct WorkspaceList: Decodable {
        struct Workspace: Decodable, Equatable, Sendable {
            var workspace_id: String
            var label: String?
        }
        struct Result: Decodable { var workspaces: [Workspace] }
        var result: Result
    }

    public static func listing(panes: String, tabs: String, workspaces: String, agents: String) -> Listing? {
        let decoder = JSONDecoder()
        guard let paneList = try? decoder.decode(PaneList.self, from: Data(panes.utf8)),
              let tabList = try? decoder.decode(TabList.self, from: Data(tabs.utf8)),
              let workspaceList = try? decoder.decode(WorkspaceList.self, from: Data(workspaces.utf8)),
              let agentList = try? decoder.decode(AgentList.self, from: Data(agents.utf8))
        else { return nil }
        return Listing(
            panes: paneList.result.panes,
            tabs: Dictionary(tabList.result.tabs.map { ($0.tab_id, $0) }, uniquingKeysWith: { first, _ in first }),
            workspaces: Dictionary(workspaceList.result.workspaces.map { ($0.workspace_id, $0) }, uniquingKeysWith: { first, _ in first }),
            agentNames: Dictionary(
                agentList.result.agents.compactMap { agent in userSet(agent.name).map { (agent.pane_id, $0) } },
                uniquingKeysWith: { first, _ in first }))
    }

    public enum Association: Equatable, Sendable {
        case found(AgentPlace)
        case absent
        case unresolved
    }

    public enum CurrentPane: Equatable, Sendable {
        case pane(String)
        case gone
        case unreadable
    }

    public static func currentPaneCommand(socket: String, pane: String, executable: String) -> [String] {
        ["/usr/bin/env", "\(socketKey)=\(socket)", "\(paneKey)=\(pane)", executable, "pane", "current"]
    }

    private struct CurrentAnswer: Decodable {
        struct Result: Decodable {
            struct Pane: Decodable { var pane_id: String }
            var pane: Pane
        }
        struct Failure: Decodable { var code: String }
        var result: Result?
        var error: Failure?
    }

    public static func currentPane(_ answer: (status: Int32, output: String)) -> CurrentPane {
        guard let decoded = try? JSONDecoder().decode(CurrentAnswer.self, from: Data(answer.output.utf8)) else { return .unreadable }
        if answer.status == 0, let pane = decoded.result?.pane.pane_id { return .pane(pane) }
        return decoded.error?.code == "pane_not_found" ? .gone : .unreadable
    }

    public static func place(
        agent: String, native: String, in listing: Listing, socket: String, currentPane: () -> CurrentPane?
    ) -> Association {
        let claimed = listing.panes.filter { pane in
            guard let session = pane.agent_session, session.agent == agent else { return false }
            return sessionId(session) == native
        }
        if claimed.count > 1 { return .unresolved }
        if let pane = claimed.first { return .found(place(of: pane, in: listing, socket: socket)) }
        switch currentPane() {
        case nil, .gone?: return .absent
        case .unreadable?: return .unresolved
        case .pane(let id)?:
            guard let pane = listing.panes.first(where: { $0.pane_id == id }), pane.agent_session == nil,
                  pane.agent == nil || pane.agent == agent
            else { return .unresolved }
            return .found(place(of: pane, in: listing, socket: socket))
        }
    }

    private static func place(of pane: PaneList.Pane, in listing: Listing, socket: String) -> AgentPlace {
        let paneKey = "\(socket)#pane:\(pane.pane_id)"
        let tabKey = "\(socket)#tab:\(pane.tab_id)"
        let workspaceKey = "\(socket)#workspace:\(pane.workspace_id)"
        var labels: [AgentPlace.Label] = []
        if let title = userSet(pane.title) { labels.append(.init(text: title, level: .title, container: paneKey)) }
        if let label = userSet(pane.label) { labels.append(.init(text: label, level: .pane, container: paneKey)) }
        if let name = listing.agentNames[pane.pane_id] { labels.append(.init(text: name, level: .agent, container: paneKey)) }
        if let tab = listing.tabs[pane.tab_id], let label = userSet(tab.label), label != tab.number.map(String.init) {
            labels.append(.init(text: label, level: .tab, container: tabKey))
        }
        if let label = userSet(listing.workspaces[pane.workspace_id]?.label) {
            labels.append(.init(text: label, level: .workspace, container: workspaceKey))
        }
        return AgentPlace(surface: "herdr", labels: labels, containers: [paneKey, tabKey, workspaceKey])
    }

    private static func userSet(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func sessionId(_ session: PaneList.Session) -> String {
        guard session.kind == "path" else { return session.value }
        let file = URL(fileURLWithPath: session.value).deletingPathExtension().lastPathComponent
        return file.split(separator: "_").last.map(String.init) ?? file
    }
}
