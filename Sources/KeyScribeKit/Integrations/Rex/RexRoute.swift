import Foundation

struct RexRoute: PaneRoute {
    static let serverKey = "REX_SERVER"
    static let sessionKey = "REX_SESSION"
    static let blockKey = "REX_BLOCK"
    static let routeName = "Rex"
    let name = RexRoute.routeName
    let processName = "rex"
    let environmentKeys = [serverKey, sessionKey, blockKey]

    private struct Located {
        var rex: [String]
        var session: String
        var block: String
    }

    func open(_ server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        guard Self.isServer(server) else { return nil }
        guard let address = Self.listenAddress(server.arguments) else {
            return Opening([.layer(.unresolved(name)), .activate(app: RexAppRoute.app, pid: server.pid)])
        }
        let rex = Self.cli(server, address: address)
        let apps = Self.apps(rex: rex, facts: facts)
        guard let located = Self.locate(server: server, address: address, inner: inner) else {
            return Opening([.layer(.unresolved(name))] + Self.activate(Self.only(apps)))
        }
        let focus = PaneCommand(rex + ["focus", "-s", located.session, located.block])
        guard let app = Self.only(apps.filter { $0.sessions.contains(located.session) }) else {
            return Opening([.layer(PaneLayer(name, commands: [focus]))] + Self.activate(Self.only(apps)))
        }
        return Opening([
            .layer(PaneLayer(name, commands: [focus])), .select(.script(app: app.bundle, pid: app.pid, body: RexAppRoute.show(located.session))),
            .activate(app: app.bundle, pid: app.pid),
        ])
    }

    func check(agent pid: Int, view: FrontView, facts: TerminalFacts, multiplexerProcesses: Set<String>) -> FrontCheck {
        let chain = TerminalRoutes.ancestors(of: pid, facts: facts)
        guard let index = chain.firstIndex(where: Self.isServer), let address = Self.listenAddress(chain[index].arguments),
              let located = Self.locate(server: chain[index], address: address, inner: chain[..<index])
        else { return .unknown(.unreported(name)) }
        guard located.session == view.pane else { return .elsewhere }
        guard let shown = TerminalRoutes.decode(Session.self, facts.run(located.rex + ["session", "inspect", located.session, "--json"])) else {
            return .unknown(.unreadable(name))
        }
        let active = shown.windows.filter { $0.window_id == shown.active_window_id }
        guard active.count == 1 else { return .unknown(.unreadable(name)) }
        return active[0].focused_block_id == located.block ? .shown : .elsewhere
    }

    func isClient(_ process: TerminalProcess) -> Bool { false }

    func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep { .unknown(.multiplexer(name)) }

    private static func isServer(_ process: TerminalProcess) -> Bool {
        process.name == "rex" && (process.executable as NSString).isAbsolutePath
            && process.arguments.count > 2 && process.arguments[1] == "server" && process.arguments[2] == "run"
    }

    private static func listenAddress(_ arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--listen"), flag + 1 < arguments.count, arguments[flag + 1].hasPrefix("unix:///") else { return nil }
        return arguments[flag + 1]
    }

    private static func cli(_ server: TerminalProcess, address: String) -> [String] {
        [server.executable, "--autostart=false", "-S", address]
    }

    private static func locate(server: TerminalProcess, address: String, inner: ArraySlice<TerminalProcess>) -> Located? {
        guard let carrier = TerminalRoutes.nearest(serverKey, in: inner), carrier.environment[serverKey] == address,
              let session = carrier.environment[sessionKey].flatMap({ id($0, kind: "session") }),
              let block = carrier.environment[blockKey].flatMap({ id($0, kind: "block") })
        else { return nil }
        return Located(rex: cli(server, address: address), session: session, block: block)
    }

    static func id(_ value: String, kind: String) -> String? {
        let prefix = kind + ":"
        guard value.hasPrefix(prefix), value.count > prefix.count,
              value.dropFirst(prefix.count).unicodeScalars.allSatisfy({ $0 == "-" || $0.properties.isASCIIHexDigit })
        else { return nil }
        return value
    }

    private struct Session: Decodable {
        struct Window: Decodable {
            var window_id: String
            var focused_block_id: String?
        }
        var active_window_id: String?
        var windows: [Window]
    }

    private struct Clients: Decodable {
        struct Client: Decodable {
            struct Info: Decodable { var kind: String }
            struct Principal: Decodable {
                var transport: String?
                var pid: Int?
            }
            var info: Info?
            var principal: Principal?
            var connection_state: String?
            var session_ids: [String]?
        }
        var clients: [Client]
    }

    private struct App {
        var pid: Int
        var bundle: String
        var sessions: [String]
    }

    private static func apps(rex: [String], facts: TerminalFacts) -> [App] {
        guard let list = TerminalRoutes.decode(Clients.self, facts.run(rex + ["client", "ls", "--json"])) else { return [] }
        return list.clients.compactMap { client in
            guard client.info?.kind == "app", client.connection_state == "connected", client.principal?.transport == "unix",
                  let pid = client.principal?.pid
            else { return nil }
            return App(pid: pid, bundle: facts.process(pid)?.app ?? "", sessions: client.session_ids ?? [])
        }
    }

    private static func only(_ apps: [App]) -> App? {
        guard apps.count == 1, !apps[0].bundle.isEmpty else { return nil }
        return apps[0]
    }

    private static func activate(_ app: App?) -> [OpenAction] {
        app.map { [.activate(app: $0.bundle, pid: $0.pid)] } ?? []
    }
}

struct RexAppRoute: TerminalRoute {
    static let app = "com.superlogical.rex"
    let name = "Rex app"
    let apps: Set<String> = [app]
    let noun = "session"
    let environmentKeys: [String] = []
    let frontScript: String? = """
        set shown to current session
        if shown is missing value then return ""
        if remote of shown then return ""
        return id of shown
        """

    static func show(_ session: String) -> String {
        """
        set found to (every session whose remote is false and id ends with \(AppleScriptText.literal("/" + session)))
        if (count of found) is not 1 then return false
        show (item 1 of found)
        return true
        """
    }

    func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        bundle(of: process).map { Opening([.activate(app: $0, pid: process.pid)]) }
    }

    func front(answer: String, appPid: Int, facts: TerminalFacts) -> FrontStep {
        guard let slash = answer.lastIndex(of: "/"), let session = RexRoute.id(String(answer[answer.index(after: slash)...]), kind: "session") else {
            return .unknown(.unreported(name))
        }
        return .view(FrontView(host: RexRoute.routeName, server: appPid, pane: session))
    }
}
