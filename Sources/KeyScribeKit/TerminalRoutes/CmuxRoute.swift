import Foundation

struct CmuxRoute: TerminalRoute {
    static let surfaceKey = "CMUX_SURFACE_ID"
    let name = "cmux"
    static let app = "com.cmuxterm.app"
    let apps: Set<String> = [app]
    let environmentKeys = [surfaceKey]
    let frontScript: String? = "return id of focused terminal of selected tab of front window"
    let focusDefinitions = [
        FocusDefinition(id: "cmux", requiresEnv: [surfaceKey], argv: ["/usr/bin/env", "cmux", "focus-panel", "--panel", "{\(surfaceKey)}"]),
    ]

    func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        guard process.app == Self.app else { return nil }
        let activate = OpenAction.activate(app: Self.app, pid: process.pid)
        guard let surface = TerminalRoutes.nearest(Self.surfaceKey, in: inner)?.environment[Self.surfaceKey] else {
            return Opening([.select(.connector(focusDefinitions[0].id)), activate])
        }
        let body = """
            set found to (every terminal whose id is \(AppleScriptText.literal(surface)))
            if (count of found) is 0 then return false
            focus (item 1 of found)
            return true
            """
        return Opening([.select(.script(app: Self.app, pid: process.pid, body: body)), activate])
    }

    func front(answer id: String, appPid: Int, facts: TerminalFacts) -> FrontStep {
        guard let children = facts.children(of: appPid) else { return .unknown(.processesUnreadable) }
        var matches: Set<String> = []
        var unreadable = false
        for tty in Set(children.compactMap(\.tty)) {
            guard let processes = facts.processes(onTTY: tty) else {
                unreadable = true
                continue
            }
            if processes.contains(where: { $0.environment[Self.surfaceKey] == id }) { matches.insert(tty) }
        }
        guard matches.count <= 1 else { return .unknown(.ambiguous) }
        if let tty = matches.first { return .tty(tty) }
        return unreadable ? .unknown(.processesUnreadable) : .view(FrontView(host: name, server: appPid, pane: id))
    }

    func check(agent pid: Int, view: FrontView, facts: TerminalFacts, multiplexerProcesses: Set<String>) -> FrontCheck {
        let chain = TerminalRoutes.ancestors(of: pid, facts: facts)
        guard let terminal = chain.firstIndex(where: { $0.pid == view.server }),
              let surface = TerminalRoutes.nearest(Self.surfaceKey, in: chain[..<terminal])?.environment[Self.surfaceKey]
        else { return .unknown(.unreported(name)) }
        guard surface == view.pane, FrontPanes.visible(chain[..<terminal]).count == terminal else { return .elsewhere }
        return .shown
    }
}
