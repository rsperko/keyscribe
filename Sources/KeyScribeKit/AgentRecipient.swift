import Foundation

public enum AgentRecipient {
    public enum Source: Equatable, Sendable { case fixed, current, front, spoken }

    public struct Frozen: Equatable, Sendable {
        public var id: String
        public var source: Source
        public init(id: String, source: Source) {
            self.id = id
            self.source = source
        }
    }

    public enum AskReason: Equatable, Sendable {
        case noRecipient
        case noSuchRow(Int)
        case unknownName(String)
        case ambiguousName(String, matches: [String])
        case soundsLike(String, name: String)
    }

    public enum Resolution: Equatable, Sendable {
        case deliver(id: String, body: String, source: Source)
        case select(id: String)
        case open(id: String)
        case ask(body: String, reason: AskReason)

        public var makesCurrent: String? {
            switch self {
            case .deliver(let id, _, .spoken), .deliver(let id, _, .front), .select(let id), .open(let id): return id
            case .deliver, .ask: return nil
            }
        }
    }

    public static func initial(target: Mode.Agent.Target, current: String?, names: [String: String]) -> Frozen? {
        switch target {
        case .handle(let name):
            return id(named: name, in: names).map { Frozen(id: $0, source: .fixed) }
        case .current:
            return current.map { Frozen(id: $0, source: .current) }
        case .ask:
            return nil
        }
    }

    public static func usesDefault(_ address: AgentAddress) -> Bool {
        switch address {
        case .none, .nearMiss: true
        case .open(let target): usesDefault(target)
        case .name, .row, .unresolved, .ambiguous: false
        }
    }

    public static func resolve(_ address: AgentAddress, frozen: Frozen?, rows: [String], names: [String: String]) -> Resolution {
        switch address {
        case .open(.unresolved(let spoken, _)):
            return .ask(body: "", reason: suggestion(for: spoken, among: Array(names.keys)))
        case .open(let target):
            switch resolve(target, frozen: frozen, rows: rows, names: names) {
            case .select(let id), .open(let id), .deliver(let id, _, _): return .open(id: id)
            case .ask(_, let reason): return .ask(body: "", reason: reason)
            }
        case .none(let body):
            guard let frozen else { return .ask(body: body, reason: .noRecipient) }
            return .deliver(id: frozen.id, body: body, source: frozen.source)
        case .unresolved(let spoken, let body):
            return .ask(body: body, reason: .unknownName(spoken))
        case .ambiguous(let spoken, let matches, let body):
            guard let first = matches.sorted().first, let id = id(named: first, in: names) else {
                return .ask(body: body, reason: .ambiguousName(spoken, matches: matches))
            }
            return addressed(id, body: body)
        case .nearMiss(let spoken, let name, let body, let unaddressed):
            if let frozen, id(named: name, in: names) == frozen.id {
                guard let unaddressed else { return addressed(frozen.id, body: body) }
                return .deliver(id: frozen.id, body: unaddressed, source: frozen.source)
            }
            return .ask(body: body, reason: .soundsLike(spoken, name: name))
        case .row(let row, let body):
            guard rows.indices.contains(row - 1) else { return .ask(body: body, reason: .noSuchRow(row)) }
            return addressed(rows[row - 1], body: body)
        case .name(let name, let body):
            guard let id = id(named: name, in: names) else { return .ask(body: body, reason: .unknownName(name)) }
            return addressed(id, body: body)
        }
    }

    private static func suggestion(for spoken: String, among names: [String]) -> AskReason {
        let close = AgentAddress.closest(to: spoken, among: names)
        switch close.count {
        case 0: return .unknownName(spoken)
        case 1: return .soundsLike(spoken, name: close[0])
        default: return .ambiguousName(spoken, matches: close)
        }
    }

    private static func addressed(_ id: String, body: String) -> Resolution {
        body.isEmpty ? .select(id: id) : .deliver(id: id, body: body, source: .spoken)
    }

    private static func id(named name: String, in names: [String: String]) -> String? {
        let wanted = AgentHandles.matchKey(name)
        return names.first { AgentHandles.matchKey($0.key) == wanted }?.value
    }
}
