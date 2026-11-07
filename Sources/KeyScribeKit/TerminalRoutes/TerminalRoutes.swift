import Foundation

public struct TerminalProcess: Equatable, Sendable {
    public var pid: Int
    public var parent: Int?
    public var tty: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var executable: String
    public var app: String?
    public var foreground: Bool
    public var directory: String?
    public var startedAt: Int?
    public var argumentsReadable: Bool

    public init(
        pid: Int, parent: Int?, tty: String?, arguments: [String], environment: [String: String], executable: String,
        app: String?, foreground: Bool = true, directory: String? = nil, startedAt: Int? = nil, argumentsReadable: Bool = true
    ) {
        self.foreground = foreground
        self.directory = directory
        self.startedAt = startedAt
        self.argumentsReadable = argumentsReadable
        self.pid = pid
        self.parent = parent
        self.tty = tty
        self.arguments = arguments
        self.environment = environment
        self.executable = executable
        self.app = app
    }

    public var name: String { (executable as NSString).lastPathComponent }
}

public protocol TerminalFacts {
    func process(_ pid: Int) -> TerminalProcess?
    func processes(named name: String) -> [TerminalProcess]?
    func processes(onTTY tty: String) -> [TerminalProcess]?
    func children(of pid: Int) -> [TerminalProcess]?
    func socketOwners(in directory: String) -> [String: Int]?
    func run(_ argv: [String]) -> (status: Int32, output: String)
}

public struct PaneCommand: Equatable, Sendable {
    public var arguments: [String]
    public var accepting: Set<Int32>
    public var until: FocusWalk?

    public init(_ arguments: [String], accepting: Set<Int32> = [0], until: FocusWalk? = nil) {
        self.arguments = arguments
        self.accepting = accepting
        self.until = until
    }
}

public struct PaneLayer: Equatable, Sendable {
    public var multiplexer: String
    public var commands: [PaneCommand]
    public var confirmed: Bool

    public init(_ multiplexer: String, commands: [PaneCommand], confirmed: Bool = true) {
        self.multiplexer = multiplexer
        self.commands = commands
        self.confirmed = confirmed
    }

    public static func unresolved(_ multiplexer: String) -> PaneLayer {
        PaneLayer(multiplexer, commands: [], confirmed: false)
    }
}

public struct Opening: Equatable, Sendable {
    public var actions: [OpenAction]
    public var next: Int?

    public init(_ actions: [OpenAction], next: Int? = nil) {
        self.actions = actions
        self.next = next
    }
}

public enum FrontStep: Equatable, Sendable {
    case tty(String)
    case view(FrontView)
    case unknown(FrontUnknown)
}

public protocol Route: Sendable {
    var name: String { get }
    var environmentKeys: [String] { get }
    func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening?
    func check(agent pid: Int, view: FrontView, facts: TerminalFacts) -> FrontCheck
}

extension Route {
    public func check(agent pid: Int, view: FrontView, facts: TerminalFacts) -> FrontCheck { .unknown(.unreported(name)) }
}

public protocol TerminalRoute: Route {
    var app: String { get }
    var frontScript: String? { get }
    func front(answer: String, appPid: Int, facts: TerminalFacts) -> FrontStep
}

extension TerminalRoute {
    public func front(answer: String, appPid: Int, facts: TerminalFacts) -> FrontStep { .tty(answer) }
}

public protocol PaneRoute: Route {
    var processName: String { get }
    func isClient(_ process: TerminalProcess) -> Bool
    func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep
}

public enum TerminalSelector: Equatable, Sendable {
    case script(app: String, pid: Int, body: String)
    case url(String)
    case connector
}

public enum OpenAction: Equatable, Sendable {
    case layer(PaneLayer)
    case select(TerminalSelector)
    case activate(app: String, pid: Int)
    case unsupported(app: String, pid: Int)
}

public enum TerminalRoutes {
    public static let maxAncestors = 64
    public static let maxLayers = 4
    public static let terminalRoutes: [any TerminalRoute] = ScriptedTerminalRoute.all.map { $0 as any TerminalRoute } + [WarpRoute(), CmuxRoute()]
    public static let paneRoutes: [any PaneRoute] = [HerdrRoute(), TmuxRoute(), ZellijRoute()]
    public static let routes: [any Route] = terminalRoutes.map { $0 as any Route } + paneRoutes.map { $0 as any Route }
    public static let environmentKeys: Set<String> = Set(routes.flatMap(\.environmentKeys))

    public static func terminal(_ app: String) -> (any TerminalRoute)? { terminalRoutes.first { $0.app == app } }

    static func route(named name: String) -> (any Route)? { routes.first { $0.name == name } }

    public static func plan(agent pid: Int, facts: TerminalFacts, routes: [any Route] = routes) -> [OpenAction] {
        var actions: [OpenAction] = []
        var start = pid
        layers: for _ in 0..<maxLayers {
            let chain = ancestors(of: start, facts: facts)
            for (index, process) in chain.enumerated() {
                for route in routes {
                    guard let opening = route.open(process, inner: chain[..<index], facts: facts) else { continue }
                    actions += opening.actions
                    guard let next = opening.next else { return actions }
                    start = next
                    continue layers
                }
            }
            if let owner = chain.first(where: { $0.app != nil }), let app = owner.app {
                actions.append(.unsupported(app: app, pid: owner.pid))
            }
            return actions
        }
        return actions
    }

    static func ancestors(of pid: Int, facts: TerminalFacts) -> [TerminalProcess] {
        var chain: [TerminalProcess] = []
        var next: Int? = pid
        while let pid = next, pid > 1, chain.count < maxAncestors, !chain.contains(where: { $0.pid == pid }),
              let process = facts.process(pid) {
            chain.append(process)
            next = process.parent
        }
        return chain
    }

    static func nearest(_ key: String, in inner: ArraySlice<TerminalProcess>) -> TerminalProcess? {
        inner.reversed().first { $0.environment[key] != nil }
    }

    static func rows(_ result: (status: Int32, output: String)) -> [[String]] {
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    static func steadiest(_ clients: [Int], preferring pid: Int?) -> Int? {
        clients.first { $0 == pid } ?? clients.min()
    }

    static func ttys(of processes: ArraySlice<TerminalProcess>) -> [String] {
        var seen: [String] = []
        for tty in processes.reversed().compactMap(\.tty) where !seen.contains(tty) { seen.append(tty) }
        return seen
    }
}

extension TerminalRoutes {
    public static func layers(of actions: [OpenAction]) -> (app: String?, multiplexers: [String]) {
        var app: String?
        var multiplexers: [String] = []
        for action in actions {
            switch action {
            case .layer(let layer): multiplexers.insert(layer.multiplexer, at: 0)
            case .select(.script(let bundle, _, _)), .activate(let bundle, _), .unsupported(let bundle, _): app = app ?? bundle
            case .select(.url), .select(.connector): break
            }
        }
        return (app, multiplexers)
    }
}

extension TerminalFacts {
    public func reporting(_ environment: [String: String], for pid: Int) -> TerminalFacts {
        ReportedFacts(base: self, pid: pid, environment: environment.filter { TerminalRoutes.environmentKeys.contains($0.key) })
    }
}

private struct ReportedFacts: TerminalFacts {
    var base: TerminalFacts
    var pid: Int
    var environment: [String: String]

    func process(_ pid: Int) -> TerminalProcess? { base.process(pid).map(reported) }
    func processes(named name: String) -> [TerminalProcess]? { base.processes(named: name)?.map(reported) }
    func processes(onTTY tty: String) -> [TerminalProcess]? { base.processes(onTTY: tty)?.map(reported) }
    func children(of pid: Int) -> [TerminalProcess]? { base.children(of: pid)?.map(reported) }
    func socketOwners(in directory: String) -> [String: Int]? { base.socketOwners(in: directory) }
    func run(_ argv: [String]) -> (status: Int32, output: String) { base.run(argv) }

    private func reported(_ process: TerminalProcess) -> TerminalProcess {
        guard process.pid == pid else { return process }
        var process = process
        process.environment.merge(environment) { own, _ in own }
        return process
    }
}
