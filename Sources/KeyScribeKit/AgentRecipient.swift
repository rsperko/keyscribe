import Foundation

public enum AgentRecipient {
    public enum Source: Equatable, Sendable { case fixed, focused, current, spoken, reply }

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
        case noReply
        case noSuchRow(Int)
        case unknownName(String)
    }

    public enum Resolution: Equatable, Sendable {
        case deliver(id: String, body: String, source: Source)
        case select(id: String)
        case ask(body: String, reason: AskReason)

        public var makesCurrent: String? {
            switch self {
            case .deliver(let id, _, .spoken), .deliver(let id, _, .reply), .select(let id): return id
            case .deliver, .ask: return nil
            }
        }
    }

    public static func initial(target: Mode.Agent.Target, focused: String?, current: String?, names: [String: String]) -> Frozen? {
        switch target {
        case .handle(let name):
            return id(named: name, in: names).map { Frozen(id: $0, source: .fixed) }
        case .focused:
            if let focused { return Frozen(id: focused, source: .focused) }
            return current.map { Frozen(id: $0, source: .current) }
        case .current:
            return current.map { Frozen(id: $0, source: .current) }
        case .ask:
            return nil
        }
    }

    public static func resolve(_ address: AgentAddress, frozen: Frozen?, rows: [String], names: [String: String], replyTo: String?) -> Resolution {
        switch address {
        case .none(let body):
            guard let frozen else { return .ask(body: body, reason: .noRecipient) }
            return .deliver(id: frozen.id, body: body, source: frozen.source)
        case .reply(let body):
            guard let replyTo else { return .ask(body: body, reason: .noReply) }
            return .deliver(id: replyTo, body: body, source: .reply)
        case .unresolved(let spoken, let body):
            return .ask(body: body, reason: .unknownName(spoken))
        case .row(let row, let body):
            guard rows.indices.contains(row - 1) else { return .ask(body: body, reason: .noSuchRow(row)) }
            return addressed(rows[row - 1], body: body)
        case .name(let name, let body):
            guard let id = id(named: name, in: names) else { return .ask(body: body, reason: .unknownName(name)) }
            return addressed(id, body: body)
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
