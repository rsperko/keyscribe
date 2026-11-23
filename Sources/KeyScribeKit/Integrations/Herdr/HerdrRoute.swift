import Foundation

struct HerdrRoute: PaneRoute {
    static let socketKey = HerdrPlaces.socketKey
    static let paneKey = HerdrPlaces.paneKey
    let name = "herdr"
    let processName = HerdrPlaces.processName
    static let configKey = "XDG_CONFIG_HOME"
    let environmentKeys = [socketKey, paneKey, configKey]

    func open(_ server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        layer(server: server, inner: inner, facts: facts).map { Opening([.layer($0.layer)], next: $0.client) }
    }

    func isClient(_ process: TerminalProcess) -> Bool { process.name == processName && Self.clientSession(process.arguments) != nil }

    func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep {
        guard let session = Self.clientSession(client.arguments),
              let inner = Self.focusedTTY(executable: client.executable, session: session, config: Self.config(of: client), facts: facts)
        else { return .unknown(.multiplexer(name)) }
        return .tty(inner)
    }

    private func layer(server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PaneLayer, client: Int?)? {
        guard server.name == processName, server.arguments.dropFirst().first == "server",
              let pane = TerminalRoutes.nearest(Self.socketKey, in: inner), let socket = pane.environment[Self.socketKey]
        else { return nil }
        let client = client(of: socket, config: Self.config(of: server.argumentsReadable ? server : pane), server: server, facts: facts)
        guard let id = pane.environment[Self.paneKey] else { return (.unresolved(name), client) }
        let focus = PaneCommand(["/usr/bin/env", "\(Self.socketKey)=\(socket)", server.executable, "agent", "focus", id])
        return (PaneLayer(name, commands: [focus]), client)
    }

    func titleRead(_ server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> TitleRead? {
        guard server.name == processName, server.arguments.dropFirst().first == "server",
              let carrier = TerminalRoutes.nearest(Self.socketKey, in: inner), let socket = carrier.environment[Self.socketKey],
              !socket.isEmpty, let pane = carrier.environment[Self.paneKey], !pane.isEmpty
        else { return nil }
        let argv = HerdrPlaces.listCommands(socket: socket, executable: server.executable).panes
        return TitleRead(route: name, source: .command(argv), pane: [pane])
    }

    func title(answer: String, pane: [String]) -> String? {
        pane.first.flatMap { HerdrPlaces.programTitle(ofPane: $0, in: answer) }
    }

    private struct Sessions: Decodable {
        struct Session: Decodable {
            var name: String
            var socket_path: String
        }
        var sessions: [Session]
    }

    private static func config(of process: TerminalProcess) -> String? {
        process.environment[configKey].flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func sessions(_ executable: String, config: String?, facts: TerminalFacts) -> Sessions? {
        let list = [executable, "session", "list", "--json"]
        return TerminalRoutes.decode(Sessions.self, facts.run(config.map { ["/usr/bin/env", "\(configKey)=\($0)"] + list } ?? list))
    }

    private func client(of socket: String, config: String?, server: TerminalProcess, facts: TerminalFacts) -> Int? {
        guard let list = Self.sessions(server.executable, config: config, facts: facts),
              let name = list.sessions.first(where: { $0.socket_path == socket })?.name,
              let herdrs = facts.processes(named: processName)
        else { return nil }
        let clients = herdrs.filter { $0.tty != nil && Self.clientSession($0.arguments) == name && Self.config(of: $0) == config }
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

    private struct Panes: Decodable {
        struct Result: Decodable { var panes: [Pane] }
        struct Pane: Decodable {
            var pane_id: String
            var focused: Bool
        }
        var result: Result
    }

    private struct ProcessInfo: Decodable {
        struct Result: Decodable { var process_info: Info }
        struct Info: Decodable { var shell_pid: Int }
        var result: Result
    }

    private static func focusedTTY(executable: String, session: String, config: String?, facts: TerminalFacts) -> String? {
        guard let sessions = sessions(executable, config: config, facts: facts),
              let socket = sessions.sessions.first(where: { $0.name == session })?.socket_path
        else { return nil }
        let herdr = ["/usr/bin/env", "-u", paneKey, "\(socketKey)=\(socket)", executable]
        guard let panes = TerminalRoutes.decode(Panes.self, facts.run(herdr + ["pane", "list"])) else { return nil }
        let focused = panes.result.panes.filter(\.focused)
        guard focused.count == 1,
              let info = TerminalRoutes.decode(ProcessInfo.self, facts.run(herdr + ["pane", "process-info", "--pane", focused[0].pane_id]))
        else { return nil }
        return facts.process(info.result.process_info.shell_pid)?.tty
    }
}
