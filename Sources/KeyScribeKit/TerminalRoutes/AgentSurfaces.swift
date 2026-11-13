import Foundation

public struct AgentSurfaces: Sendable {
    public var terminals: [any TerminalRoute]
    public var multiplexers: [any PaneRoute]

    public init(terminals: [any TerminalRoute] = [], multiplexers: [any PaneRoute] = []) {
        self.terminals = terminals
        self.multiplexers = multiplexers
    }

    public static var builtIn: AgentSurfaces {
        AgentSurfaces(
            terminals: [ScriptedTerminalRoute.ghostty, ScriptedTerminalRoute.terminal, ScriptedTerminalRoute.iterm, WarpRoute(), CmuxRoute()],
            multiplexers: [HerdrRoute(), TmuxRoute(), ZellijRoute()])
    }

    public enum Conflict: Error, Equatable, Sendable {
        case name(String)
        case app(String)
        case processName(String)
    }

    public func resolve() throws -> ResolvedSurfaces {
        let routes = terminals.map { $0 as any Route } + multiplexers.map { $0 as any Route }
        var names: Set<String> = []
        for route in routes where !names.insert(route.name).inserted { throw Conflict.name(route.name) }
        var apps: Set<String> = []
        for terminal in terminals {
            if let shared = terminal.apps.sorted().first(where: apps.contains) { throw Conflict.app(shared) }
            apps.formUnion(terminal.apps)
        }
        var processes: Set<String> = []
        for pane in multiplexers where !processes.insert(pane.processName).inserted { throw Conflict.processName(pane.processName) }
        return ResolvedSurfaces(terminals: terminals, multiplexers: multiplexers, routes: routes)
    }
}

public struct ResolvedSurfaces: Sendable {
    public let terminals: [any TerminalRoute]
    public let multiplexers: [any PaneRoute]
    public let routes: [any Route]
    public let environmentKeys: Set<String>
    public let multiplexerProcesses: Set<String>

    fileprivate init(terminals: [any TerminalRoute], multiplexers: [any PaneRoute], routes: [any Route]) {
        self.terminals = terminals
        self.multiplexers = multiplexers
        self.routes = routes
        environmentKeys = Set(routes.flatMap(\.environmentKeys))
        multiplexerProcesses = Set(multiplexers.map(\.processName))
    }

    public func terminal(_ app: String) -> (any TerminalRoute)? { terminals.first { $0.apps.contains(app) } }

    public func terminal(named name: String) -> (any TerminalRoute)? { terminals.first { $0.name == name } }

    public func route(named name: String) -> (any Route)? { routes.first { $0.name == name } }
}
