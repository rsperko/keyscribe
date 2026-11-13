import Foundation

public struct PlaceLayer: Equatable, Sendable {
    public var labels: [AgentPlace.Label]
    public var containers: [String]
    public var unresolved: Bool

    public init(labels: [AgentPlace.Label] = [], containers: [String] = [], unresolved: Bool = false) {
        self.labels = labels
        self.containers = containers
        self.unresolved = unresolved
    }
}

public protocol PlaceRoute: Route {
    func place(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PlaceLayer, next: Int?)?
}

public struct TerminalHost: Equatable, Sendable {
    public var route: String
    public var app: String
    public var pid: Int
    public var ttys: [String]

    public init(route: String, app: String, pid: Int, ttys: [String]) {
        self.route = route
        self.app = app
        self.pid = pid
        self.ttys = ttys
    }
}

public struct TerminalPlaceWalk: Equatable, Sendable {
    public var layers: [PlaceLayer]
    public var host: TerminalHost?
    public var surface: String?

    public init(layers: [PlaceLayer] = [], host: TerminalHost? = nil, surface: String? = nil) {
        self.layers = layers
        self.host = host
        self.surface = surface
    }
}

public enum TerminalPlaces {
    public static func walk(agent pid: Int, facts: TerminalFacts, routes: [any Route]) -> TerminalPlaceWalk? {
        guard facts.process(pid) != nil else { return nil }
        var walk = TerminalPlaceWalk()
        var start = pid
        layers: for _ in 0..<TerminalRoutes.maxLayers {
            let chain = TerminalRoutes.ancestors(of: start, facts: facts)
            for (index, process) in chain.enumerated() {
                let inner = chain[..<index]
                for route in routes {
                    if let placed = route as? any PlaceRoute, let found = placed.place(process, inner: inner, facts: facts) {
                        walk.layers.append(found.layer)
                        walk.surface = walk.surface ?? route.name
                        guard let next = found.next, !found.layer.unresolved else { return walk }
                        start = next
                        continue layers
                    }
                    if let terminal = route as? any TerminalRoute, terminal.claims(process) {
                        if terminal.placeScript != nil, let app = terminal.bundle(of: process) {
                            walk.host = TerminalHost(route: terminal.name, app: app, pid: process.pid, ttys: TerminalRoutes.ttys(of: inner))
                            walk.surface = walk.surface ?? terminal.name
                        }
                        return walk
                    }
                    if let pane = route as? any PaneRoute, process.name == pane.processName, process.tty == nil {
                        guard let next = pane.open(process, inner: inner, facts: facts)?.next else { return walk }
                        start = next
                        continue layers
                    }
                }
            }
            return walk
        }
        return walk
    }

    public static func userSet(_ text: String?, unless defaults: [String] = []) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return defaults.contains { trimmed.range(of: $0, options: .regularExpression) != nil } ? nil : trimmed
    }
}

public final class CachedTerminalFacts: TerminalFacts, @unchecked Sendable {
    private let base: TerminalFacts
    private var ran: [[String]: (status: Int32, output: String)] = [:]

    public init(_ base: TerminalFacts) { self.base = base }

    public func process(_ pid: Int) -> TerminalProcess? { base.process(pid) }
    public func processes(named name: String) -> [TerminalProcess]? { base.processes(named: name) }
    public func processes(onTTY tty: String) -> [TerminalProcess]? { base.processes(onTTY: tty) }
    public func children(of pid: Int) -> [TerminalProcess]? { base.children(of: pid) }
    public func socketOwners(in directory: String) -> [String: Int]? {
        if let earlier = owners[directory] { return earlier }
        let found = base.socketOwners(in: directory)
        owners[directory] = .some(found)
        return found
    }
    private var owners: [String: [String: Int]?] = [:]
    public func run(_ argv: [String]) -> (status: Int32, output: String) {
        if let earlier = ran[argv] { return earlier }
        let result = base.run(argv)
        ran[argv] = result
        return result
    }
}
