import Foundation

public enum AgentRecipient {
    public enum Source: Equatable, Sendable { case front, spoken }

    public static let nothingFocused = "No conversation focused"
    public static let nothingFocusedAdvice = "Open one, or name a conversation in your instruction."
    public static let nothingFocusedLine = "\(nothingFocused). \(nothingFocusedAdvice)"

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
        let named = Set(names.keys.map(AgentHandles.matchKey))
        return Array(names.keys) + shared.filter(\.value.kind.spokenBare).keys.filter { !named.contains(AgentHandles.matchKey($0)) }
    }

    public static func afterVerbNames(_ shared: [String: SharedName]) -> [String] {
        shared.filter { !$0.value.kind.spokenBare }.keys.sorted()
    }

    public static func addingLate(
        _ late: [String: String], sharing lateShared: [String: SharedName], to frozen: [String: String], sharing frozenShared: [String: SharedName]
    ) -> (names: [String: String], shared: [String: SharedName]) {
        guard !late.isEmpty || !lateShared.isEmpty else { return (frozen, frozenShared) }
        let frozenIds = Set(frozen.values)
        var names = frozen
        var named = Set(frozen.keys.map(AgentHandles.matchKey))
        let frozenSharedKeys = Set(frozenShared.keys.map(AgentHandles.matchKey))
        for (name, id) in late.sorted(by: { $0.key < $1.key }) where frozenIds.contains(id) {
            let key = AgentHandles.matchKey(name)
            guard !named.contains(key), !frozenSharedKeys.contains(key) else { continue }
            names[name] = id
            named.insert(key)
        }
        var shared = frozenShared
        var sharedKeys = frozenSharedKeys
        for (label, place) in lateShared.sorted(by: { $0.key < $1.key }) {
            let key = AgentHandles.matchKey(label)
            guard !named.contains(key), !sharedKeys.contains(key) else { continue }
            if place.names.allSatisfy({ named.contains(AgentHandles.matchKey($0)) }) {
                shared[label] = place
                sharedKeys.insert(key)
            }
        }
        return (names, shared)
    }

    public enum AskReason: Equatable, Sendable {
        case nothingFocused
        case noSuchRow(Int)
        case unknownName(String)
        case ambiguousName(String, matches: [String])
        case sharedName(String, matches: [String], tellApartIn: String?)
        case soundsLike(String, name: String)
        case noBreak(String)
        case shownOn(String, name: String, as: String)
        case nameOnly(String)
    }

    public enum Resolution: Equatable, Sendable {
        case deliver(id: String, body: String, source: Source)
        case open(id: String)
        case ask(body: String, reason: AskReason)
    }

    public static func usesFocus(_ address: AgentAddress) -> Bool {
        switch address {
        case .none, .nearMiss: true
        case .open(let target): usesFocus(target)
        case .unbroken: true
        case .name, .row, .unresolved, .ambiguous, .native: false
        }
    }

    public static func resolve(
        _ address: AgentAddress, focused: String?, rows: [String], names: [String: String], shared: [String: SharedName] = [:]
    ) -> Resolution {
        let resolution = resolveAddressed(address, focused: focused, rows: rows, names: names, shared: shared)
        if case .open = address { return resolution }
        if case .deliver(_, let body, .spoken) = resolution, ["", "please"].contains(AgentHandles.normalize(body)) {
            return .ask(body: "", reason: .nameOnly(said(address)))
        }
        return resolution
    }

    public static func conversation(
        _ address: AgentAddress, focused: String?, rows: [String], names: [String: String], shared: [String: SharedName] = [:]
    ) -> Resolution {
        resolveAddressed(address, focused: focused, rows: rows, names: names, shared: shared)
    }

    private static func resolveAddressed(
        _ address: AgentAddress, focused: String?, rows: [String], names: [String: String], shared: [String: SharedName]
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
        case .open(.unresolved(let spoken, _)):
            return .ask(body: "", reason: suggestion(for: spoken, among: Array(names.keys)))
        case .open(let target):
            switch resolveAddressed(target, focused: focused, rows: rows, names: names, shared: shared) {
            case .open(let id), .deliver(let id, _, _): return .open(id: id)
            case .ask(_, let reason): return .ask(body: "", reason: reason)
            }
        case .unbroken(let target, let unaddressed):
            switch resolveAddressed(target, focused: focused, rows: rows, names: names, shared: shared) {
            case .deliver(let id, _, _), .open(let id):
                if focused == id { return .deliver(id: id, body: unaddressed, source: .front) }
                return .ask(body: unaddressed, reason: .noBreak(said(target)))
            case .ask(_, let reason):
                return .ask(body: unaddressed, reason: reason)
            }
        case .none(let body):
            guard let focused else { return .ask(body: body, reason: .nothingFocused) }
            return .deliver(id: focused, body: body, source: .front)
        case .unresolved(let spoken, let body):
            return .ask(body: body, reason: .unknownName(spoken))
        case .ambiguous(let spoken, let matches, let body):
            if let asked = sharedAsk(spoken, body: body) { return asked }
            guard matches.allSatisfy({ id(named: $0, in: names) != nil }), let first = matches.sorted().first, let id = id(named: first, in: names) else {
                return .ask(body: body, reason: .ambiguousName(spoken, matches: matches))
            }
            return addressed(id, body: body)
        case .native(let spoken, let handles, let body):
            switch handles.count {
            case 0: return .ask(body: body, reason: .unknownName(spoken))
            case 1: return addressed(handles.keys.first!, body: body)
            default: return .ask(body: body, reason: .ambiguousName(spoken, matches: handles.values.sorted()))
            }
        case .nearMiss(let spoken, let name, let body, let unaddressed):
            if let focused, id(named: name, in: names) == focused {
                guard let unaddressed else { return addressed(focused, body: body) }
                return .deliver(id: focused, body: unaddressed, source: .front)
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
        case .unresolved(let spoken, _), .native(let spoken, _, _): spoken
        case .open(let inner), .unbroken(let inner, _): said(inner)
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
        .deliver(id: id, body: body, source: .spoken)
    }

    private static func id(named name: String, in names: [String: String]) -> String? {
        let wanted = AgentHandles.matchKey(name)
        return names.first { AgentHandles.matchKey($0.key) == wanted }?.value
    }
}
