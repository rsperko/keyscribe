import Foundation

public struct TerminalProcess: Equatable, Sendable {
    public var pid: Int
    public var parent: Int?
    public var tty: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var executable: String
    public var app: String?

    public init(
        pid: Int, parent: Int?, tty: String?, arguments: [String], environment: [String: String], executable: String,
        app: String?
    ) {
        self.pid = pid
        self.parent = parent
        self.tty = tty
        self.arguments = arguments
        self.environment = environment
        self.executable = executable
        self.app = app
    }

    var name: String { (executable as NSString).lastPathComponent }
}

public protocol TerminalFacts {
    func process(_ pid: Int) -> TerminalProcess?
    func processes(named name: String) -> [TerminalProcess]
    func run(_ argv: [String]) -> (status: Int32, output: String)
}

public struct PaneCommand: Equatable, Sendable {
    public var arguments: [String]
    public var alreadyDone: String?

    public init(_ arguments: [String], alreadyDone: String? = nil) {
        self.arguments = arguments
        self.alreadyDone = alreadyDone
    }

    public func succeeded(status: Int32, output: String) -> Bool {
        status == 0 || alreadyDone.map(output.contains) == true
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

public protocol PaneRoute: Sendable {
    var environmentKeys: [String] { get }
    func layer(server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PaneLayer, client: Int?)?
}

public protocol TerminalRoute: Sendable {
    var environmentKeys: [String] { get }
    func owns(_ process: TerminalProcess) -> Bool
    func actions(terminal: TerminalProcess, inner: ArraySlice<TerminalProcess>) -> [OpenAction]
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
    static let paneRoutes: [any PaneRoute] = [HerdrRoute(), TmuxRoute(), ZellijRoute()]
    static let terminalRoutes: [any TerminalRoute] = [
        ScriptedTerminalRoute.ghostty, ScriptedTerminalRoute.terminal, ScriptedTerminalRoute.iterm, WarpRoute(), CmuxRoute(),
    ]
    public static let environmentKeys: Set<String> = Set(
        paneRoutes.flatMap(\.environmentKeys) + terminalRoutes.flatMap(\.environmentKeys))

    public static func plan(agent pid: Int, facts: TerminalFacts) -> [OpenAction] {
        var actions: [OpenAction] = []
        var start = pid
        layers: for _ in 0..<maxLayers {
            let chain = ancestors(of: start, facts: facts)
            for (index, process) in chain.enumerated() {
                let inner = chain[..<index]
                if let route = terminalRoutes.first(where: { $0.owns(process) }) {
                    return actions + route.actions(terminal: process, inner: inner)
                }
                for route in paneRoutes {
                    guard let (layer, client) = route.layer(server: process, inner: inner, facts: facts) else { continue }
                    actions.append(.layer(layer))
                    guard let client else { return actions }
                    start = client
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
