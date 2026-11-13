import Foundation

public enum RouteConformance {
    public static func problems(_ surfaces: AgentSurfaces) -> [String] {
        do { _ = try surfaces.resolve() } catch { return ["the surfaces do not resolve: \(error)"] }
        return surfaces.terminals.flatMap(problems(terminal:)) + surfaces.multiplexers.flatMap(problems(pane:))
    }

    private static let terminalPid = 2
    private static let agentPid = 3
    private static let tty = "/dev/ttys999"

    private static func problems(terminal: any TerminalRoute) -> [String] {
        var found = strangerProblems(terminal)
        for app in terminal.apps.sorted() {
            let facts = Facts(table: [
                terminalPid: TerminalProcess(
                    pid: terminalPid, parent: 1, tty: nil, arguments: [], environment: [:],
                    executable: "/Applications/Conformance.app/Contents/MacOS/conformance", app: app),
                agentPid: TerminalProcess(
                    pid: agentPid, parent: terminalPid, tty: tty, arguments: ["agent"], environment: [:], executable: "/usr/local/bin/agent", app: nil),
            ])
            let plan = TerminalRoutes.plan(agent: agentPid, facts: facts, routes: [terminal])
            if !plan.contains(.activate(app: app, pid: terminalPid)) {
                found.append("\(terminal.name): opening \(app) started without its own environment does not bring it forward")
            }
        }
        if let front = terminal.readFront(appPid: terminalPid, facts: Facts(), reported: []), !isUnknown(front) {
            found.append("\(terminal.name): reads a front it could not read")
        }
        return found + checkProblems(terminal)
    }

    private static func problems(pane: any PaneRoute) -> [String] {
        var found = strangerProblems(pane)
        let client = TerminalProcess(
            pid: terminalPid, parent: 1, tty: tty, arguments: [pane.processName], environment: [:], executable: pane.processName, app: nil)
        if !isUnknown(pane.front(client: client, tty: tty, facts: Facts())) {
            found.append("\(pane.name): reads a front it could not read")
        }
        return found + checkProblems(pane)
    }

    private static func strangerProblems(_ route: any Route) -> [String] {
        let stranger = TerminalProcess(
            pid: terminalPid, parent: 1, tty: nil, arguments: ["conformance-stranger"], environment: [:],
            executable: "/usr/local/bin/conformance-stranger", app: "dev.keyscribe.conformance-stranger")
        let agent = TerminalProcess(pid: agentPid, parent: terminalPid, tty: tty, arguments: [], environment: [:], executable: "agent", app: nil)
        guard route.open(stranger, inner: [agent], facts: Facts()) != nil else { return [] }
        return ["\(route.name): opens a process that is not its own"]
    }

    private static func checkProblems(_ route: any Route) -> [String] {
        let facts = Facts(table: [
            terminalPid: TerminalProcess(pid: terminalPid, parent: 1, tty: nil, arguments: [], environment: [:], executable: "server", app: nil),
            agentPid: TerminalProcess(pid: agentPid, parent: terminalPid, tty: tty, arguments: [], environment: [:], executable: "agent", app: nil),
        ])
        let check = route.check(
            agent: agentPid, view: FrontView(host: route.name, server: terminalPid, pane: "1"), facts: facts, multiplexerProcesses: [])
        guard case .unknown = check else { return ["\(route.name): confirms a view it could not read"] }
        return []
    }

    private static func isUnknown(_ step: FrontStep) -> Bool {
        if case .unknown = step { return true }
        return false
    }

    private struct Facts: TerminalFacts {
        var table: [Int: TerminalProcess] = [:]
        func process(_ pid: Int) -> TerminalProcess? { table[pid] }
        func processes(named name: String) -> [TerminalProcess]? { nil }
        func processes(onTTY tty: String) -> [TerminalProcess]? { nil }
        func children(of pid: Int) -> [TerminalProcess]? { nil }
        func socketOwners(in directory: String) -> [String: Int]? { nil }
        func run(_ argv: [String]) -> (status: Int32, output: String) { (1, "") }
    }
}
