import Foundation

struct HerdrRoute: PaneRoute {
    static let socketKey = "HERDR_SOCKET_PATH"
    static let paneKey = "HERDR_PANE_ID"
    let environmentKeys = [socketKey, paneKey]

    func layer(server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PaneLayer, client: Int?)? {
        guard server.name == "herdr", server.arguments.dropFirst().first == "server",
              let pane = TerminalRoutes.nearest(Self.socketKey, in: inner), let socket = pane.environment[Self.socketKey]
        else { return nil }
        let client = client(of: socket, server: server, facts: facts)
        guard let id = pane.environment[Self.paneKey] else { return (.unresolved("herdr"), client) }
        let focus = PaneCommand(["/usr/bin/env", "\(Self.socketKey)=\(socket)", server.executable, "agent", "focus", id])
        return (PaneLayer("herdr", commands: [focus]), client)
    }

    private struct Sessions: Decodable {
        struct Session: Decodable {
            var name: String
            var socket_path: String
        }
        var sessions: [Session]
    }

    private func client(of socket: String, server: TerminalProcess, facts: TerminalFacts) -> Int? {
        let (status, output) = facts.run([server.executable, "session", "list", "--json"])
        guard status == 0, let list = try? JSONDecoder().decode(Sessions.self, from: Data(output.utf8)),
              let name = list.sessions.first(where: { $0.socket_path == socket })?.name
        else { return nil }
        let clients = facts.processes(named: "herdr").filter { $0.tty != nil && Self.clientSession($0.arguments) == name }
        return TerminalRoutes.steadiest(clients.map(\.pid), preferring: server.parent)
    }

    static func clientSession(_ arguments: [String]) -> String? {
        var rest = Array(arguments.dropFirst())
        var session = "default"
        if let flag = rest.firstIndex(of: "--session") {
            guard flag + 1 < rest.count else { return nil }
            session = rest[flag + 1]
            rest.removeSubrange(flag...(flag + 1))
        }
        if rest.count == 3, rest[0] == "session", rest[1] == "attach" { return rest[2] }
        return rest.isEmpty ? session : nil
    }
}
