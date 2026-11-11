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

    public struct SharedName: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case place
            case also(String)
            case afterVerb(String)
            case held(String)

            var spokenBare: Bool {
                switch self {
                case .place, .also: true
                case .afterVerb, .held: false
                }
            }
        }

        public var names: [String]
        public var tellApartIn: String?
        public var kind: Kind

        public init(names: [String], tellApartIn: String? = nil, kind: Kind = .place) {
            self.names = names
            self.tellApartIn = tellApartIn
            self.kind = kind
        }
    }

    public static func spokenNames(_ names: [String: String], shared: [String: SharedName]) -> [String] {
        Array(names.keys) + shared.filter(\.value.kind.spokenBare).keys
            .filter { key in !names.keys.contains { AgentHandles.matchKey($0) == AgentHandles.matchKey(key) } }
    }

    public static func afterVerbNames(_ shared: [String: SharedName]) -> [String] {
        shared.filter { !$0.value.kind.spokenBare }.keys.sorted()
    }

    public static func addingLate(
        _ late: [String: String], sharing lateShared: [String: SharedName], to frozen: [String: String], sharing frozenShared: [String: SharedName]
    ) -> (names: [String: String], shared: [String: SharedName]) {
        func taken(_ name: String, _ names: [String: String], _ shared: [String: SharedName]) -> Bool {
            let key = AgentHandles.matchKey(name)
            return names.keys.contains { AgentHandles.matchKey($0) == key } || shared.keys.contains { AgentHandles.matchKey($0) == key }
        }
        let frozenIds = Set(frozen.values)
        var names = frozen
        for (name, id) in late.sorted(by: { $0.key < $1.key }) where frozenIds.contains(id) && !taken(name, names, frozenShared) {
            names[name] = id
        }
        var shared = frozenShared
        for (label, place) in lateShared.sorted(by: { $0.key < $1.key }) where !taken(label, names, shared) {
            let members = place.names.filter { member in names.keys.contains { AgentHandles.matchKey($0) == AgentHandles.matchKey(member) } }
            if members.count == place.names.count { shared[label] = place }
        }
        return (names, shared)
    }

    public enum AskReason: Equatable, Sendable {
        case noRecipient
        case noSuchRow(Int)
        case unknownName(String)
        case ambiguousName(String, matches: [String])
        case sharedName(String, matches: [String], tellApartIn: String?)
        case soundsLike(String, name: String)
        case noBreak(String)
        case shownOn(String, name: String, as: String)
        case sayToSelect(String)
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
        case .open(let target), .select(let target): usesDefault(target)
        case .unbroken: true
        case .name, .row, .unresolved, .ambiguous: false
        }
    }

    public static func resolve(
        _ address: AgentAddress, frozen: Frozen?, rows: [String], names: [String: String], shared: [String: SharedName] = [:]
    ) -> Resolution {
        let resolution = resolveAddressed(address, frozen: frozen, rows: rows, names: names, shared: shared)
        switch (address, resolution) {
        case (.open, _), (.select, _): return resolution
        case (_, .select): return .ask(body: "", reason: .sayToSelect(said(address)))
        case (_, .deliver(_, let body, .spoken)) where AgentHandles.normalize(body) == "please":
            return .ask(body: "", reason: .sayToSelect(said(address)))
        default: return resolution
        }
    }

    public static func conversation(
        _ address: AgentAddress, frozen: Frozen?, rows: [String], names: [String: String], shared: [String: SharedName] = [:]
    ) -> Resolution {
        resolveAddressed(address, frozen: frozen, rows: rows, names: names, shared: shared)
    }

    private static func resolveAddressed(
        _ address: AgentAddress, frozen: Frozen?, rows: [String], names: [String: String], shared: [String: SharedName]
    ) -> Resolution {
        func sharedAsk(_ spoken: String, body: String) -> Resolution? {
            guard id(named: spoken, in: names) == nil,
                  let place = shared.first(where: { AgentHandles.matchKey($0.key) == AgentHandles.matchKey(spoken) })
            else { return nil }
            if case .held(let seenAs) = place.value.kind, place.value.names.count == 1 {
                return .ask(body: body, reason: .shownOn(place.key, name: place.value.names[0], as: seenAs))
            }
            if place.value.names.count == 1, let only = id(named: place.value.names[0], in: names) { return addressed(only, body: body) }
            return .ask(body: body, reason: .sharedName(place.key, matches: place.value.names, tellApartIn: place.value.tellApartIn))
        }
        switch address {
        case .open(.unresolved(let spoken, _)), .select(.unresolved(let spoken, _)):
            return .ask(body: "", reason: suggestion(for: spoken, among: Array(names.keys)))
        case .open(let target):
            switch resolveAddressed(target, frozen: frozen, rows: rows, names: names, shared: shared) {
            case .select(let id), .open(let id), .deliver(let id, _, _): return .open(id: id)
            case .ask(_, let reason): return .ask(body: "", reason: reason)
            }
        case .select(let target):
            switch resolveAddressed(target, frozen: frozen, rows: rows, names: names, shared: shared) {
            case .select(let id), .open(let id), .deliver(let id, _, _): return .select(id: id)
            case .ask(_, let reason): return .ask(body: "", reason: reason)
            }
        case .unbroken(let target, let unaddressed):
            switch resolveAddressed(target, frozen: frozen, rows: rows, names: names, shared: shared) {
            case .deliver(let id, _, _), .select(let id), .open(let id):
                if let frozen, frozen.id == id { return .deliver(id: id, body: unaddressed, source: frozen.source) }
                return .ask(body: unaddressed, reason: .noBreak(said(target)))
            case .ask(_, let reason):
                return .ask(body: unaddressed, reason: reason)
            }
        case .none(let body):
            guard let frozen else { return .ask(body: body, reason: .noRecipient) }
            return .deliver(id: frozen.id, body: body, source: frozen.source)
        case .unresolved(let spoken, let body):
            return .ask(body: body, reason: .unknownName(spoken))
        case .ambiguous(let spoken, let matches, let body):
            if let asked = sharedAsk(spoken, body: body) { return asked }
            guard matches.allSatisfy({ id(named: $0, in: names) != nil }), let first = matches.sorted().first, let id = id(named: first, in: names) else {
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
            if let asked = sharedAsk(name, body: body) { return asked }
            guard let id = id(named: name, in: names) else { return .ask(body: body, reason: .unknownName(name)) }
            return addressed(id, body: body)
        }
    }

    private static func said(_ address: AgentAddress) -> String {
        switch address {
        case .name(let name, _), .nearMiss(_, let name, _, _): name
        case .row(let row, _): "conversation \(row)"
        case .ambiguous(_, let matches, _): matches.sorted().first ?? ""
        case .unresolved(let spoken, _): spoken
        case .open(let inner), .select(let inner), .unbroken(let inner, _): said(inner)
        case .none: ""
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
