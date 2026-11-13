import Foundation

struct ZellijRoute: PaneRoute, PlaceRoute {
    static let paneKey = "ZELLIJ_PANE_ID"
    static let clientsHeader = ["CLIENT_ID", paneKey]
    let name = "Zellij"
    let processName = "zellij"
    let environmentKeys = [paneKey]

    func open(_ server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        layer(server: server, inner: inner, facts: facts).map { Opening([.layer($0.layer)], next: $0.client) }
    }

    func isClient(_ process: TerminalProcess) -> Bool { process.name == processName && !process.arguments.contains("--server") }

    private func layer(server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PaneLayer, client: Int?)? {
        guard server.name == processName, let flag = server.arguments.firstIndex(of: "--server"), flag + 1 < server.arguments.count
        else { return nil }
        let socket = server.arguments[flag + 1]
        let clients = Self.clients(of: socket, server: server.pid, facts: facts)
        let client = TerminalRoutes.steadiest(clients, preferring: nil)
        guard let pane = TerminalRoutes.nearest(Self.paneKey, in: inner),
              let id = pane.environment[Self.paneKey].flatMap({ Int($0.replacingOccurrences(of: "terminal_", with: "")) })
        else { return (.unresolved(name), client) }
        guard let session = Self.session(server: server.pid, socket: socket, facts: facts)
        else { return (.unresolved(name), client) }
        let action = [server.executable, "--session", session, "action"]
        guard let (tab, steps) = Self.walk(to: id, in: facts.run(action + ["list-panes", "-t", "-j"])) else { return (.unresolved(name), client) }
        let walk = FocusWalk(check: action + ["list-clients"], header: Self.clientsHeader, value: "terminal_\(id)", steps: steps)
        let commands = [
            PaneCommand(action + ["go-to-tab-by-id", String(tab)]),
            PaneCommand(action + ["hide-floating-panes", "-t", String(tab)], accepting: [0, 2]),
            PaneCommand(action + ["focus-next-pane"], until: walk),
        ]
        return (PaneLayer(name, commands: commands, confirmed: clients.count <= 1), client)
    }

    func place(_ server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PlaceLayer, next: Int?)? {
        guard server.name == processName, let flag = server.arguments.firstIndex(of: "--server"), flag + 1 < server.arguments.count
        else { return nil }
        let socket = server.arguments[flag + 1]
        guard let pane = TerminalRoutes.nearest(Self.paneKey, in: inner),
              let id = pane.environment[Self.paneKey].flatMap({ Int($0.replacingOccurrences(of: "terminal_", with: "")) }),
              let session = Self.session(server: server.pid, socket: socket, facts: facts),
              let listed = Self.named(id, in: facts.run([server.executable, "--session", session, "action", "list-panes", "-t", "-j"]))
        else { return (PlaceLayer(unresolved: true), nil) }
        let key = "zellij:\(socket)"
        let containers = ["\(key)#pane:\(id)", "\(key)#tab:\(listed.tab)"]
        var labels: [AgentPlace.Label] = []
        if let tab = TerminalPlaces.userSet(listed.tabName, unless: [#"^Tab #\d+$"#]) {
            labels.append(.init(text: tab, level: .tab, container: containers[1], surface: name, term: "tab"))
        }
        let client = TerminalRoutes.steadiest(Self.clients(of: socket, server: server.pid, facts: facts), preferring: nil)
        return (PlaceLayer(labels: labels, containers: containers), client)
    }

    private struct Named: Decodable {
        var id: Int
        var is_plugin: Bool
        var tab_id: Int?
        var tab_name: String?
    }

    static func named(_ id: Int, in result: (status: Int32, output: String)) -> (tab: Int, tabName: String?)? {
        guard result.status == 0, let panes = try? JSONDecoder().decode([Named].self, from: Data(result.output.utf8)),
              let pane = panes.first(where: { !$0.is_plugin && $0.id == id }), let tab = pane.tab_id
        else { return nil }
        return (tab, pane.tab_name)
    }

    private struct Pane: Decodable {
        var id: Int
        var is_plugin: Bool
        var tab_id: Int?
        var is_floating: Bool?
        var is_suppressed: Bool?
        var is_selectable: Bool?
        var cycled: Bool { is_floating == false && is_suppressed == false && is_selectable == true }
    }

    static func walk(to id: Int, in result: (status: Int32, output: String)) -> (tab: Int, steps: Int)? {
        guard result.status == 0, let panes = try? JSONDecoder().decode([Pane].self, from: Data(result.output.utf8)),
              let target = panes.first(where: { !$0.is_plugin && $0.id == id }), target.cycled, let tab = target.tab_id
        else { return nil }
        return (tab, panes.filter { $0.tab_id == tab && $0.cycled }.count - 1)
    }

    private struct Socket {
        var pid: Int
        var device: String
        var name: String
        var peer: String? { name.hasPrefix("->") ? String(name.dropFirst(2)) : nil }
    }

    private static func sockets(_ facts: TerminalFacts) -> [Socket] {
        let (status, output) = facts.run(["/usr/sbin/lsof", "-U", "-a", "-c", "zellij", "-F", "pdn"])
        guard status == 0 || !output.isEmpty else { return [] }
        var sockets: [Socket] = []
        var pid = 0
        var device = ""
        for line in output.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int(value) ?? 0
            case "f": device = ""
            case "d": device = value
            case "n": sockets.append(Socket(pid: pid, device: device, name: value))
            default: break
            }
        }
        return sockets
    }

    static func clients(of socket: String, server: Int, facts: TerminalFacts) -> [Int] {
        let sockets = sockets(facts)
        let accepted = Set(sockets.filter { $0.pid == server && $0.name == socket }.map(\.device))
        return Array(Set(sockets.filter { $0.pid != server && $0.peer.map(accepted.contains) == true }.map(\.pid))).sorted()
    }

    static func server(ofClient client: Int, facts: TerminalFacts) -> (pid: Int, socket: String)? {
        let sockets = sockets(facts)
        let peers = Set(sockets.filter { $0.pid == client }.compactMap(\.peer))
        let servers = Set(sockets.filter { $0.pid != client && $0.peer == nil && peers.contains($0.device) }.map { "\($0.pid)\t\($0.name)" })
        guard servers.count == 1, let only = servers.first?.split(separator: "\t", maxSplits: 1), only.count == 2, let pid = Int(only[0])
        else { return nil }
        return (pid, String(only[1]))
    }

    func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep {
        guard let server = Self.server(ofClient: client.pid, facts: facts),
              let session = Self.session(server: server.pid, socket: server.socket, facts: facts),
              let panes = Self.focusedPanes(facts.run([client.executable, "--session", session, "action", "list-clients"]))
        else { return .unknown(.multiplexer(name)) }
        guard panes.count == 1, let pane = panes.first else { return .unknown(.severalViews(name)) }
        return .view(FrontView(host: name, server: server.pid, pane: pane))
    }

    static func session(server pid: Int, socket: String, facts: TerminalFacts) -> String? {
        guard let owners = facts.socketOwners(in: (socket as NSString).deletingLastPathComponent) else { return nil }
        let names = owners.filter { $0.value == pid }.map(\.key)
        return names.count == 1 ? names[0] : nil
    }

    static func focusedPanes(_ result: (status: Int32, output: String)) -> Set<String>? {
        FocusWalk.lastColumn(of: clientsHeader, in: result)
    }

    func check(agent pid: Int, view: FrontView, facts: TerminalFacts, multiplexerProcesses: Set<String>) -> FrontCheck {
        let chain = TerminalRoutes.ancestors(of: pid, facts: facts)
        guard let server = chain.firstIndex(where: { $0.pid == view.server }) else {
            switch nests(chain, in: view.server, facts: facts, multiplexerProcesses: multiplexerProcesses) {
            case true: return .unknown(.nested(name))
            case false: return .elsewhere
            case nil: return .unknown(.processesUnreadable)
            }
        }
        guard let pane = TerminalRoutes.nearest(Self.paneKey, in: chain[..<server])?.environment[Self.paneKey] else {
            return .unknown(.unreported(name))
        }
        guard "terminal_\(pane)" == view.pane, FrontPanes.visible(chain[..<server]).count == server else { return .elsewhere }
        return .shown
    }

    private func nests(_ chain: [TerminalProcess], in server: Int, facts: TerminalFacts, multiplexerProcesses: Set<String>) -> Bool? {
        let nestable = multiplexerProcesses.subtracting([processName]).sorted()
        guard chain.contains(where: { $0.tty == nil && nestable.contains($0.name) }) else { return false }
        var clients: [TerminalProcess] = []
        for name in nestable {
            guard let named = facts.processes(named: name) else { return nil }
            clients += named
        }
        return clients.contains { client in
            client.tty != nil && TerminalRoutes.ancestors(of: client.pid, facts: facts).contains { $0.pid == server }
        }
    }
}

