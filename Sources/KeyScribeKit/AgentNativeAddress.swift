import Foundation

public struct AgentNativeAddress: Sendable {
    public struct Reading: Equatable, Sendable {
        public var native: String?
        public var words: Int

        public init(native: String?, words: Int) {
            self.native = native
            self.words = words
        }
    }

    public var agent: String
    public var read: @Sendable (_ words: ArraySlice<String>) -> Reading?

    public init(agent: String, read: @escaping @Sendable (_ words: ArraySlice<String>) -> Reading?) {
        self.agent = agent
        self.read = read
    }
}

public struct AgentNativeRoster: Sendable {
    public struct Member: Equatable, Sendable {
        public var agent: String
        public var native: String
        public var id: String
        public var handle: String
        public var otherNames: [String]
        public var workspace: String?

        public init(agent: String, native: String, id: String, handle: String, otherNames: [String] = [], workspace: String? = nil) {
            self.agent = agent
            self.native = native
            self.id = id
            self.handle = handle
            self.otherNames = otherNames
            self.workspace = workspace
        }
    }

    public var addresses: [AgentNativeAddress]
    public var members: [Member]

    public init(addresses: [AgentNativeAddress] = [], members: [Member] = []) {
        self.addresses = addresses
        self.members = members
    }

    public func addingLate(_ late: AgentNativeRoster) -> AgentNativeRoster {
        var merged = self
        for member in late.members {
            guard let index = merged.members.firstIndex(where: { $0.id == member.id }) else { continue }
            merged.members[index].workspace = merged.members[index].workspace ?? member.workspace
            let known = Set(merged.members[index].otherNames.map(AgentHandles.matchKey))
            merged.members[index].otherNames += member.otherNames.filter { !known.contains(AgentHandles.matchKey($0)) }
        }
        return merged
    }

    public static func words(_ text: String) -> [String] {
        var apart = ""
        for character in text {
            if let last = apart.last, last.isLetter && character.isNumber || last.isNumber && character.isLetter { apart.append(" ") }
            apart.append(character)
        }
        return AgentHandles.normalize(apart).split(separator: " ").map(String.init)
    }

    func handles(named spoken: String) -> [String: String] {
        let key = AgentHandles.matchKey(spoken)
        let named = members.filter { member in ([member.handle] + member.otherNames).contains { AgentHandles.matchKey($0) == key } }
        return Dictionary(named.map { ($0.id, $0.handle) }, uniquingKeysWith: { first, _ in first })
    }

    func settle(_ reading: (tokens: Int, handles: [String: String]), against name: (length: Int, exact: String?)?) -> [String: String]? {
        let named = name?.length ?? 0
        if reading.tokens > named { return reading.handles }
        guard reading.tokens == named else { return nil }
        guard let exact = name?.exact else { return reading.handles }
        return reading.handles.isEmpty ? nil : reading.handles.merging(handles(named: exact)) { kept, _ in kept }
    }

    static let longestRead = 32
    static let longestReadThroughReplacements = 8

    func read(_ tokens: ArraySlice<String>) -> (tokens: Int, handles: [String: String])? {
        guard !addresses.isEmpty else { return nil }
        var words: [String] = []
        var tokensThrough: [Int] = []
        var endsToken: [Bool] = []
        for (index, token) in tokens.prefix(Self.longestRead).enumerated() {
            let parts = Self.words(token)
            for (part, word) in parts.enumerated() {
                words.append(word)
                tokensThrough.append(index + 1)
                endsToken.append(part == parts.count - 1)
            }
        }
        var best: (tokens: Int, handles: [String: String])?
        func consider(from start: Int, in workspace: String?) {
            guard start < words.count else { return }
            let said = start == 0 ? words[...] : Array(words[start...])[...]
            for address in addresses {
                guard let reading = address.read(said), reading.words > 0, start + reading.words <= words.count else { continue }
                let end = start + reading.words - 1
                let through = tokensThrough[end]
                let named = endsToken[end] ? reading.native.map { native in
                    members.filter { member in
                        member.agent == address.agent && member.native == native
                            && (workspace.map { member.workspace.map(AgentHandles.matchKey) == $0 } ?? true)
                    }
                } ?? [] : []
                let handles = Dictionary(named.map { ($0.id, $0.handle) }, uniquingKeysWith: { first, _ in first })
                if let found = best, found.tokens > through { continue }
                if let found = best, found.tokens == through {
                    best = (through, found.handles.merging(handles) { kept, _ in kept })
                } else {
                    best = (through, handles)
                }
            }
        }
        consider(from: 0, in: nil)
        for workspace in Set(members.compactMap(\.workspace)) {
            let named = Self.words(workspace)
            guard !named.isEmpty, words.starts(with: named), endsToken[named.count - 1] else { continue }
            consider(from: named.count, in: AgentHandles.matchKey(workspace))
        }
        return best
    }
}
