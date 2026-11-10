import Foundation

struct TmuxRoute: PaneRoute, PlaceRoute {
    static let key = "TMUX"
    let name = "tmux"
    let processName = "tmux"
    let environmentKeys = [key]

    func open(_ server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        layer(server: server, inner: inner, facts: facts).map { Opening([.layer($0.layer)], next: $0.client) }
    }

    func isClient(_ process: TerminalProcess) -> Bool { process.name == processName }

    func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep {
        let rows = TerminalRoutes.rows(facts.run([client.executable] + Self.socket(client.arguments) + ["list-clients", "-F", "#{client_tty}\t#{pane_tty}"]))
        let panes = rows.filter { $0.count == 2 && $0[0] == tty }
        guard panes.count == 1, !panes[0][1].isEmpty else { return .unknown(.multiplexer(name)) }
        return .tty(panes[0][1])
    }

    private func layer(server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PaneLayer, client: Int?)? {
        guard let value = TerminalRoutes.nearest(Self.key, in: inner)?.environment[Self.key] else { return nil }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2, Int(parts[1]) == server.pid else { return nil }
        let tmux = [server.executable, "-S", String(parts[0])]
        let ttys = Set(inner.compactMap(\.tty))
        let panes = TerminalRoutes.rows(facts.run(tmux + ["list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_name}"]))
        let clients = TerminalRoutes.rows(facts.run(
            tmux + ["list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"]
        )).filter { $0.count == 4 }
        guard let pane = panes.first(where: { $0.count == 3 && ttys.contains($0[0]) }) else { return (.unresolved(name), nil) }
        let byActivity = clients.sorted { (Int($0[3]) ?? 0) > (Int($1[3]) ?? 0) }
        guard let client = byActivity.first(where: { $0[2] == pane[2] }) ?? byActivity.first, let next = Int(client[1])
        else { return (.unresolved(name), nil) }
        let commands = [["select-window", "-t", pane[1]], ["select-pane", "-t", pane[1]], ["switch-client", "-c", client[0], "-t", pane[1]]]
        return (PaneLayer(name, commands: commands.map { PaneCommand(tmux + $0) }), next)
    }

    func place(_ server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PlaceLayer, next: Int?)? {
        guard let value = TerminalRoutes.nearest(Self.key, in: inner)?.environment[Self.key] else { return nil }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2, Int(parts[1]) == server.pid else { return nil }
        let socket = String(parts[0])
        let tmux = [server.executable, "-S", socket]
        let ttys = Set(inner.compactMap(\.tty))
        let format = "#{pane_tty}\t#{pane_id}\t#{session_name}\t#{window_id}\t#{window_name}\t#{automatic-rename}\t#{status}\t#{allow-rename}"
        let panes = TerminalRoutes.rows(facts.run(tmux + ["list-panes", "-a", "-F", format])).filter { $0.count == 8 }
        guard let pane = panes.first(where: { ttys.contains($0[0]) }) else { return (PlaceLayer(unresolved: true), nil) }
        let key = "tmux:\(socket)"
        let containers = ["\(key)#pane:\(pane[1])", "\(key)#window:\(pane[3])", "\(key)#session:\(pane[2])"]
        var labels: [AgentPlace.Label] = []
        if pane[6] != "off" {
            if pane[5] == "0", pane[7] != "1", let window = TerminalPlaces.userSet(pane[4]) {
                labels.append(.init(text: window, level: .tab, container: containers[1], surface: name, term: "window"))
            }
            if let session = TerminalPlaces.userSet(pane[2], unless: [#"^\d+$"#]) {
                labels.append(.init(text: session, level: .workspace, container: containers[2], surface: name, term: "session"))
            }
        }
        let clients = TerminalRoutes.rows(facts.run(
            tmux + ["list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"]
        )).filter { $0.count == 4 }.sorted { (Int($0[3]) ?? 0) > (Int($1[3]) ?? 0) }
        let client = clients.first { $0[2] == pane[2] }.flatMap { Int($0[1]) }
        return (PlaceLayer(labels: labels, containers: containers), client)
    }

    static func socket(_ arguments: [String]) -> [String] {
        for flag in ["-L", "-S"] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count { return [flag, arguments[index + 1]] }
        }
        return []
    }
}
