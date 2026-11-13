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
        case focusDefinition(String)
        case environmentKey(String)
    }

    public static func isPlainName(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || ("A"..."Z").contains(first) || ("a"..."z").contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "_" || ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) }
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
        for route in routes {
            if let key = route.environmentKeys.first(where: { !Self.isPlainName($0) }) { throw Conflict.environmentKey(key) }
        }
        var definitions: Set<String> = []
        for route in routes {
            for definition in route.focusDefinitions
            where !definitions.insert(definition.id).inserted || !definition.runs(within: route.environmentKeys) {
                throw Conflict.focusDefinition(definition.id)
            }
        }
        return ResolvedSurfaces(terminals: terminals, multiplexers: multiplexers, routes: routes)
    }
}

public struct ResolvedSurfaces: Sendable {
    public let terminals: [any TerminalRoute]
    public let multiplexers: [any PaneRoute]
    public let routes: [any Route]
    public let environmentKeys: Set<String>
    public let multiplexerProcesses: Set<String>
    public let focusDefinitions: [FocusDefinition]

    fileprivate init(terminals: [any TerminalRoute], multiplexers: [any PaneRoute], routes: [any Route]) {
        self.terminals = terminals
        self.multiplexers = multiplexers
        self.routes = routes
        environmentKeys = Set(routes.flatMap(\.environmentKeys))
        focusDefinitions = routes.flatMap(\.focusDefinitions)
        multiplexerProcesses = Set(multiplexers.map(\.processName))
    }

    public func terminal(_ app: String) -> (any TerminalRoute)? { terminals.first { $0.apps.contains(app) } }

    public func terminal(named name: String) -> (any TerminalRoute)? { terminals.first { $0.name == name } }

    public func route(named name: String) -> (any Route)? { routes.first { $0.name == name } }
}
