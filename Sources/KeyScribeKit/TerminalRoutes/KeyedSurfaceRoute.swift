import Foundation

public struct KeyedSurfaceRoute: TerminalRoute {
    public typealias Command = @Sendable (_ terminal: TerminalProcess, _ value: String, _ socket: String?) -> PaneCommand?
    public typealias FrontReader = @Sendable (_ terminal: TerminalProcess, _ socket: String?, _ facts: TerminalFacts) -> FrontStep
    public typealias TitleCommand = @Sendable (_ terminal: TerminalProcess, _ socket: String?) -> [String]?
    public typealias TitleParser = @Sendable (_ answer: String, _ pane: [String]) -> String?

    public enum Focus: Sendable {
        case url(prefix: String)
        case command(Command)
    }

    public let name: String
    public let apps: Set<String>
    public let key: String
    public let socket: String?
    public let noun: String
    public let focus: Focus
    public let front: FrontReader?
    public let titleCommand: TitleCommand?
    public let titleFrom: TitleParser?
    public let frontScript: String? = nil

    public init(
        name: String, apps: Set<String>, key: String, socket: String? = nil, noun: String = "tab", focus: Focus,
        front: FrontReader? = nil, titleCommand: TitleCommand? = nil, titleFrom: TitleParser? = nil
    ) {
        self.name = name
        self.apps = apps
        self.key = key
        self.socket = socket
        self.noun = noun
        self.focus = focus
        self.front = front
        self.titleCommand = titleCommand
        self.titleFrom = titleFrom
    }

    public var environmentKeys: [String] { [key] + (socket.map { [$0] } ?? []) }

    public func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        guard let app = bundle(of: process) else { return nil }
        let activate = OpenAction.activate(app: app, pid: process.pid)
        switch focus {
        case .url(let prefix):
            guard let url = inner.reversed().lazy.compactMap({ $0.environment[key] }).first(where: { $0.hasPrefix(prefix) }) else {
                return Opening([activate])
            }
            return Opening([.select(.url(url)), activate])
        case .command(let command):
            guard let located = located(process, inner: inner, facts: facts),
                  let focus = command(process, located.value, located.socket), !focus.arguments.isEmpty
            else { return Opening([activate]) }
            return Opening([.select(.command(focus)), activate])
        }
    }

    public func titleRead(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> TitleRead? {
        guard let titleCommand, titleFrom != nil, bundle(of: process) != nil, let located = located(process, inner: inner, facts: facts),
              let argv = titleCommand(process, located.socket), !argv.isEmpty
        else { return nil }
        return TitleRead(route: name, source: .command(argv), pane: [located.value] + TerminalRoutes.ttys(of: inner))
    }

    public func title(answer: String, pane: [String]) -> String? {
        titleFrom?(answer, pane)
    }

    private func located(
        _ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts
    ) -> (value: String, socket: String?)? {
        guard Self.isPath(process.executable), let carrier = TerminalRoutes.nearest(key, in: inner), let value = carrier.environment[key],
              Self.usable(value)
        else { return nil }
        guard let socket else { return (value, nil) }
        guard let path = carrier.environment[socket].map(Self.path), Self.owns(path, pid: process.pid, facts: facts) else { return nil }
        return (value, path)
    }

    public func readFront(appPid: Int, facts: TerminalFacts, reported: [[String: String]]) -> FrontStep? {
        guard let front else { return nil }
        guard let terminal = facts.process(appPid), Self.isPath(terminal.executable) else { return .unknown(.processesUnreadable) }
        guard let socket else { return front(terminal, nil, facts) }
        guard let listening = facts.listeningSockets(of: appPid) else { return .unknown(.processesUnreadable) }
        let owned = listening.count > 1 ? listening.intersection(Self.carried(socket, under: appPid, facts: facts, reported: reported)) : listening
        guard owned.count <= 1, listening.count <= 1 || owned.count == 1 else { return .unknown(.ambiguous) }
        guard let path = owned.first else { return .unknown(.unreported(name)) }
        return front(terminal, path, facts)
    }

    public static let carrierDepth = 3
    public static let carrierLimit = 256

    static func carried(_ key: String, under pid: Int, facts: TerminalFacts, reported: [[String: String]]) -> Set<String> {
        var found = Set(reported.compactMap { $0[key].map(path) })
        var level = [pid]
        var seen = 0
        for _ in 0..<carrierDepth where !level.isEmpty && seen < carrierLimit {
            var next: [Int] = []
            for parent in level {
                for child in facts.children(of: parent) ?? [] where seen < carrierLimit {
                    seen += 1
                    if let value = child.environment[key] { found.insert(path(value)) }
                    next.append(child.pid)
                }
            }
            level = next
        }
        return found
    }

    public static func owns(_ socket: String, pid: Int, facts: TerminalFacts) -> Bool {
        (socket as NSString).isAbsolutePath && facts.listeningSockets(of: pid)?.contains(socket) == true
    }

    public static func path(_ socket: String) -> String {
        socket.hasPrefix("unix:") ? String(socket.dropFirst("unix:".count)) : socket
    }

    private static func isPath(_ executable: String) -> Bool { (executable as NSString).isAbsolutePath }

    private static func usable(_ value: String) -> Bool { !value.isEmpty && !value.hasPrefix("-") }
}
