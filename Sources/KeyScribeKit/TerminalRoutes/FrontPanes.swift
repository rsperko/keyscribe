import Foundation

public struct TerminalFront: Equatable, Sendable {
    public var app: String
    public var tty: String?

    public init(app: String, tty: String?) {
        self.app = app
        self.tty = tty
    }
}

public struct FrontView: Equatable, Sendable {
    public var host: String
    public var server: Int
    public var pane: String

    public init(host: String, server: Int, pane: String) {
        self.host = host
        self.server = server
        self.pane = pane
    }
}

public struct FrontPane: Equatable, Sendable {
    public var app: String
    public var tty: String?
    public var multiplexers: [String]
    public var view: FrontView?

    public init(app: String, tty: String?, multiplexers: [String], view: FrontView? = nil) {
        self.app = app
        self.tty = tty
        self.multiplexers = multiplexers
        self.view = view
    }
}

public enum FrontUnknown: Error, Equatable, Sendable {
    case noTerminal
    case unsupported(String)
    case notAllowed(String)
    case unreadable(String)
    case changed
    case ambiguous
    case multiplexer(String)
    case severalViews(String)
    case unreported(String)
    case nested(String)
    case processesUnreadable
    case tooDeep
}

public enum FrontCheck: Equatable, Sendable {
    case shown
    case elsewhere
    case unknown(FrontUnknown)
}

public enum FrontReading: Equatable, Sendable {
    case pane(FrontPane)
    case unknown(FrontUnknown)

    public func check(agent pid: Int, facts: TerminalFacts, surfaces: ResolvedSurfaces) -> FrontCheck {
        switch self {
        case .unknown(let why): return .unknown(why)
        case .pane(let pane):
            if let view = pane.view {
                guard let route = surfaces.route(named: view.host) else { return .unknown(.unreported(view.host)) }
                return route.check(agent: pid, view: view, facts: facts, multiplexerProcesses: surfaces.multiplexerProcesses)
            }
            guard let tty = pane.tty else { return .unknown(.noTerminal) }
            return FrontPanes.ttys(of: pid, facts: facts).contains(tty) ? .shown : .elsewhere
        }
    }
}

public enum FrontPanes {
    public static func read(
        answer: String, from terminal: any TerminalRoute, app: String, appPid: Int, facts: TerminalFacts, panes: [any PaneRoute]
    ) -> FrontReading {
        let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .unknown(.noTerminal) }
        switch terminal.front(answer: value, appPid: appPid, facts: facts) {
        case .tty(let tty): return read(TerminalFront(app: app, tty: tty), facts: facts, panes: panes)
        case .view(let view): return .pane(FrontPane(app: app, tty: nil, multiplexers: [], view: view))
        case .unknown(let why): return .unknown(why)
        }
    }

    public static func read(_ front: TerminalFront, facts: TerminalFacts, panes: [any PaneRoute]) -> FrontReading {
        guard var tty = front.tty else { return .unknown(.noTerminal) }
        var multiplexers: [String] = []
        for _ in 0...TerminalRoutes.maxLayers {
            guard let processes = facts.processes(onTTY: tty) else { return .unknown(.processesUnreadable) }
            let clients = processes.filter(\.foreground).flatMap { process in
                panes.filter { $0.isClient(process) }.map { (route: $0, process: process) }
            }
            guard let client = clients.first else {
                return .pane(FrontPane(app: front.app, tty: tty, multiplexers: multiplexers))
            }
            guard clients.count == 1 else { return .unknown(.ambiguous) }
            multiplexers.append(client.route.name)
            switch client.route.front(client: client.process, tty: tty, facts: facts) {
            case .tty(let inner): tty = inner
            case .view(let view): return .pane(FrontPane(app: front.app, tty: tty, multiplexers: multiplexers, view: view))
            case .unknown(let why): return .unknown(why)
            }
        }
        return .unknown(.tooDeep)
    }

    public static func ttys(of pid: Int, facts: TerminalFacts) -> Set<String> {
        Set(visible(TerminalRoutes.ancestors(of: pid, facts: facts)[...]).compactMap(\.tty))
    }

    public static func visible(_ chain: ArraySlice<TerminalProcess>) -> ArraySlice<TerminalProcess> {
        var seen: Set<String> = []
        for (index, process) in zip(chain.indices, chain) {
            guard let tty = process.tty, !seen.insert(tty).inserted || process.foreground else { return chain[..<index] }
        }
        return chain
    }
}
