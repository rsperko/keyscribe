import Foundation

struct TmuxRoute: PaneRoute {
    static let key = "TMUX"
    let environmentKeys = [key]

    func layer(server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PaneLayer, client: Int?)? {
        guard let value = inner.last?.environment[Self.key] else { return nil }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2, Int(parts[1]) == server.pid else { return nil }
        let tmux = [server.executable, "-S", String(parts[0])]
        let ttys = Set(inner.compactMap(\.tty))
        let panes = TerminalRoutes.rows(facts.run(tmux + ["list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_name}"]))
        let clients = TerminalRoutes.rows(facts.run(
            tmux + ["list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"]
        )).filter { $0.count == 4 }
        guard let pane = panes.first(where: { $0.count == 3 && ttys.contains($0[0]) }) else { return (.unresolved("tmux"), nil) }
        let byActivity = clients.sorted { (Int($0[3]) ?? 0) > (Int($1[3]) ?? 0) }
        guard let client = byActivity.first(where: { $0[2] == pane[2] }) ?? byActivity.first, let next = Int(client[1])
        else { return (.unresolved("tmux"), nil) }
        let commands = [["select-window", "-t", pane[1]], ["select-pane", "-t", pane[1]], ["switch-client", "-c", client[0], "-t", pane[1]]]
        return (PaneLayer("tmux", commands: commands.map { PaneCommand(tmux + $0) }), next)
    }
}
