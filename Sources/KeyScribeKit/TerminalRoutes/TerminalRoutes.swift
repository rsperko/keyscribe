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
    func listeningSockets(of pid: Int) -> Set<String>?
    func run(_ argv: [String]) -> (status: Int32, output: String)
}

extension TerminalFacts {
    public func listeningSockets(of pid: Int) -> Set<String>? { nil }
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

public struct FocusWalk: Equatable, Sendable {
    public enum Listing: Equatable, Sendable {
        case table(header: [String])
        case json(rowsWhere: [String: String], column: String)
    }

    public var check: [String]
    public var listing: Listing
    public var value: String
    public var steps: Int

    public init(check: [String], listing: Listing, value: String, steps: Int) {
        self.check = check
        self.listing = listing
        self.value = value
        self.steps = steps
    }

    public init(check: [String], header: [String], value: String, steps: Int) {
        self.init(check: check, listing: .table(header: header), value: value, steps: steps)
    }

    public var column: String {
        switch listing {
        case .table(let header): header.last ?? ""
        case .json(_, let column): column
        }
    }

    public func reached(_ result: (status: Int32, output: String)) -> Bool? {
        switch listing {
        case .table(let header): Self.lastColumn(of: header, in: result)?.contains(value)
        case .json(let rowsWhere, let column): Self.column(column, rowsWhere: rowsWhere, in: result)?.contains(value)
        }
    }

    public static func column(_ column: String, rowsWhere: [String: String], in result: (status: Int32, output: String)) -> Set<String>? {
        guard result.status == 0,
              let rows = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]]
        else { return nil }
        let matching = rows.filter { row in rowsWhere.allSatisfy { scalar(row[$0.key]) == $0.value } }
        guard !matching.isEmpty else { return nil }
        return Set(matching.compactMap { scalar($0[column]) })
    }

    private static func scalar(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default: return nil
        }
    }

    public static func lastColumn(of header: [String], in result: (status: Int32, output: String)) -> Set<String>? {
        guard result.status == 0, !header.isEmpty else { return nil }
        let lines = result.output.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard let first = lines.first, first.starts(with: header) else { return nil }
        let rows = lines.dropFirst()
        guard !rows.isEmpty, rows.allSatisfy({ $0.count >= header.count }) else { return nil }
        return Set(rows.map { $0[header.count - 1] })
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

public struct FocusDefinition: Equatable, Sendable, Encodable {
    public var id: String
    public var requiresEnv: [String]
    public var argv: [String]

    public init(id: String, requiresEnv: [String], argv: [String]) {
        self.id = id
        self.requiresEnv = requiresEnv
        self.argv = argv
    }

    public static func placeholder(_ argument: String) -> String? {
        guard argument.count > 2, argument.hasPrefix("{"), argument.hasSuffix("}") else { return nil }
        return String(argument.dropFirst().dropLast())
    }

    func runs(within environmentKeys: [String]) -> Bool {
        guard let executable = argv.first, executable.hasPrefix("/"), Self.placeholder(executable) == nil else { return false }
        let required = Set(requiresEnv)
        return required.isSubset(of: environmentKeys) && argv.compactMap(Self.placeholder).allSatisfy(required.contains)
    }
}

public protocol Route: Sendable {
    var name: String { get }
    var environmentKeys: [String] { get }
    var focusDefinitions: [FocusDefinition] { get }
    func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening?
    func check(agent pid: Int, view: FrontView, facts: TerminalFacts, multiplexerProcesses: Set<String>) -> FrontCheck
}

extension Route {
    public var focusDefinitions: [FocusDefinition] { [] }

    public func check(agent pid: Int, view: FrontView, facts: TerminalFacts, multiplexerProcesses: Set<String>) -> FrontCheck {
        .unknown(.unreported(name))
    }
}

public protocol TerminalRoute: Route {
    var apps: Set<String> { get }
    var noun: String { get }
    var frontScript: String? { get }
    func readFront(appPid: Int, facts: TerminalFacts, reported: [[String: String]]) -> FrontStep?
    var placeScript: String? { get }
    func front(answer: String, appPid: Int, facts: TerminalFacts) -> FrontStep
    func bundle(of process: TerminalProcess) -> String?
    func places(answer: String, ttys: [String]) -> PlaceLayer?
}

extension TerminalRoute {
    public var noun: String { "tab" }
    public var placeScript: String? { nil }
    public func readFront(appPid: Int, facts: TerminalFacts, reported: [[String: String]]) -> FrontStep? { nil }
    public func front(answer: String, appPid: Int, facts: TerminalFacts) -> FrontStep { .tty(answer) }
    public func claims(_ process: TerminalProcess) -> Bool { bundle(of: process) != nil }

    public func bundle(of process: TerminalProcess) -> String? {
        process.app.flatMap { apps.contains($0) ? $0 : nil }
    }
    public func places(answer: String, ttys: [String]) -> PlaceLayer? { nil }
}

public protocol PaneRoute: Route {
    var processName: String { get }
    func isClient(_ process: TerminalProcess) -> Bool
    func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep
}

public enum TerminalSelector: Equatable, Sendable {
    case script(app: String, pid: Int, body: String)
    case url(String)
    case command(PaneCommand)
    case connector(String)
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

    public static func plan(agent pid: Int, facts: TerminalFacts, routes: [any Route]) -> [OpenAction] {
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

    public static func ancestors(of pid: Int, facts: TerminalFacts) -> [TerminalProcess] {
        var chain: [TerminalProcess] = []
        var next: Int? = pid
        while let pid = next, pid > 1, chain.count < maxAncestors, !chain.contains(where: { $0.pid == pid }),
              let process = facts.process(pid) {
            chain.append(process)
            next = process.parent
        }
        return chain
    }

    public static func nearest(_ key: String, in inner: ArraySlice<TerminalProcess>) -> TerminalProcess? {
        inner.reversed().first { $0.environment[key] != nil }
    }

    public static func rows(_ result: (status: Int32, output: String)) -> [[String]] {
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    public static func steadiest(_ clients: [Int], preferring pid: Int?) -> Int? {
        clients.first { $0 == pid } ?? clients.min()
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ result: (status: Int32, output: String)) -> T? {
        guard result.status == 0 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(result.output.utf8))
    }

    public static func describe(app: String?, multiplexers: [String]) -> String? {
        let shown = multiplexers.filter { multiplexer in app.map { $0 != multiplexer && !$0.hasPrefix(multiplexer + " ") } ?? true }
        let parts = [app].compactMap(\.self) + shown
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    public static func ttys(of processes: ArraySlice<TerminalProcess>) -> [String] {
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
            case .select(.url), .select(.command), .select(.connector): break
            }
        }
        return (app, multiplexers)
    }
}

extension TerminalFacts {
    public func reporting(_ environment: [String: String], for pid: Int, keeping keys: Set<String>) -> TerminalFacts {
        ReportedFacts(base: self, pid: pid, environment: environment.filter { keys.contains($0.key) })
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
    func listeningSockets(of pid: Int) -> Set<String>? { base.listeningSockets(of: pid) }
    func run(_ argv: [String]) -> (status: Int32, output: String) { base.run(argv) }

    private func reported(_ process: TerminalProcess) -> TerminalProcess {
        guard process.pid == pid else { return process }
        var process = process
        process.environment.merge(environment) { own, _ in own }
        return process
    }
}
