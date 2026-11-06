import Foundation

public enum AgentHandles {
    public struct Conversation: Equatable, Sendable {
        public var id: String
        public var folder: String
        public init(id: String, folder: String) {
            self.id = id
            self.folder = folder
        }
    }

    public enum RenameError: Error, Equatable { case empty, taken, reserved }

    private static let numberWords = ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    public static func normalize(_ raw: String) -> String {
        let spaced = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(spaced)
            .split(separator: " ")
            .map { token in
                guard let n = Int(token), (2...10).contains(n) else { return String(token) }
                return numberWords[n - 2]
            }
            .joined(separator: " ")
    }

    public static func base(forFolder folder: String) -> String {
        normalize(folder)
    }

    public static let distinguishingWords = ["blue", "green", "orange", "purple", "yellow", "pink", "silver", "brown", "amber", "black"]

    public static func matchKey(_ raw: String) -> String {
        normalize(raw).filter { $0 != " " }
    }

    public static func isReserved(_ name: String) -> Bool {
        let words = normalize(name).split(separator: " ").map(String.init)
        guard words.first == "session" else { return false }
        return words.count == 1 || AgentAddress.isRowWord(words[1])
    }

    public static func assign(_ conversations: [Conversation], existing: [String: String], reserved: Set<String> = []) -> [String: String] {
        let live = Set(conversations.map(\.id))
        var assigned = existing.filter { live.contains($0.key) }
        var taken = Set(assigned.values.map(matchKey)).union(reserved.map(matchKey))
        for conversation in conversations where assigned[conversation.id] == nil {
            let base = base(forFolder: conversation.folder)
            let candidate = ([base] + suffixes(avoiding: Set(base.split(separator: " ").map(String.init))).map { "\(base) \($0)" })
                .first { !taken.contains(matchKey($0)) && !isReserved($0) } ?? "\(base) \(conversation.id)"
            assigned[conversation.id] = candidate
            taken.insert(matchKey(candidate))
        }
        return assigned
    }

    private static func suffixes(avoiding used: Set<String>) -> [String] {
        let words = distinguishingWords.filter { !used.contains($0) }
        let pairs = words.flatMap { first in words.filter { $0 != first }.map { "\(first) \($0)" } }
        let triples = pairs.flatMap { pair in words.filter { !pair.contains($0) }.map { "\(pair) \($0)" } }
        return words + pairs + triples
    }

    public static func rename(_ id: String, to raw: String, in current: [String: String]) throws -> [String: String] {
        let handle = normalize(raw)
        guard !handle.isEmpty else { throw RenameError.empty }
        guard !isReserved(handle) else { throw RenameError.reserved }
        if current.contains(where: { $0.key != id && matchKey($0.value) == matchKey(handle) }) { throw RenameError.taken }
        var updated = current
        updated[id] = handle
        return updated
    }
}

public enum AgentAddress: Equatable, Sendable {
    case name(String, body: String)
    case row(Int, body: String)
    case reply(body: String)
    case unresolved(spoken: String, body: String)
    case none(body: String)

    private static let notAnAddress: Set<String> = [
        "me", "us", "him", "her", "them", "it", "you", "everyone", "everybody", "someone", "somebody", "people",
        "the", "a", "an", "my", "your", "our", "their", "his", "its", "this", "that", "these", "those",
        "what", "why", "how", "when", "where", "whether", "if", "who", "which",
    ]
    private static let rowWords = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    ]
    private static let soundsLikeARow: Set<String> = ["to", "too", "for"]

    static func isRowWord(_ word: String) -> Bool {
        Int(word) != nil || rowWords.contains(word) || soundsLikeARow.contains(word)
    }

    public static func parse(_ text: String, names: [String]) -> AgentAddress {
        let tokens = words(in: text)
        let bare = tokens.map { AgentHandles.normalize(String(text[$0])) }
        func body(after count: Int) -> String { rest(of: text, after: tokens[count - 1]) }
        guard let first = bare.first else { return .none(body: text) }

        if first == "reply" {
            let message = body(after: 1)
            return message.isEmpty ? .none(body: text) : .reply(body: message)
        }

        let start = first == "please" && bare.count > 1 && bare[1] == "tell" ? 2 : first == "tell" ? 1 : nil
        guard let start, start < tokens.count else { return .none(body: text) }
        let available = tokens.count - start
        func spoken(_ length: Int) -> String { bare[start..<(start + length)].joined(separator: " ") }
        func unresolved(_ length: Int) -> AgentAddress { .unresolved(spoken: spoken(length), body: body(after: start + length)) }

        if bare[start] == "session", available > 1 {
            let said = bare[start + 1]
            if let row = Int(said) ?? rowWords.firstIndex(of: said).map({ $0 + 1 }) { return .row(row, body: body(after: start + 2)) }
            if soundsLikeARow.contains(said) { return unresolved(2) }
        }

        let keys = Dictionary(names.map { (AgentHandles.matchKey($0), AgentHandles.normalize($0)) }, uniquingKeysWith: { a, _ in a })
        func name(_ length: Int) -> String? { keys[AgentHandles.matchKey(spoken(length))] }
        let lengths = Array(1...min((names.map { $0.split(separator: " ").count }.max() ?? 0) + 1, available))

        let exact = lengths.last { name($0) != nil }
        let matched = exact.map { AgentHandles.matchKey(spoken($0)) } ?? ""
        if let near = lengths.last(where: { length in
            keys.keys.contains { $0.count > matched.count && soundsAlike(AgentHandles.matchKey(spoken(length)), $0) }
        }) {
            return unresolved(near)
        }
        if let exact, let found = name(exact) {
            let next = start + exact
            if next < tokens.count, AgentHandles.distinguishingWords.contains(bare[next]), name(exact + 1) == nil {
                return unresolved(exact + 1)
            }
            return .name(found, body: body(after: next))
        }
        if notAnAddress.contains(bare[start]) { return .none(body: text) }
        let candidates = 1...min(4, available)
        let beforeTo = candidates.first { start + $0 < tokens.count && bare[start + $0] == "to" }
        let marked = candidates.first { endsAddress(String(text[tokens[start + $0 - 1]])) }
        return unresolved([beforeTo, marked].compactMap { $0 }.min() ?? 1)
    }

    private static func words(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            let end = text[index...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            ranges.append(index..<end)
            index = end
        }
        return ranges
    }

    private static func rest(of text: String, after word: Range<String.Index>) -> String {
        let remainder = text[word.upperBound...].drop { $0.isWhitespace || $0 == "," || $0 == ":" }
        return remainder.contains(where: { $0.isLetter || $0.isNumber }) ? String(remainder) : ""
    }

    private static func endsAddress(_ word: String) -> Bool {
        word.hasSuffix(",") || word.hasSuffix(":")
    }

    private static func soundsAlike(_ spoken: String, _ name: String) -> Bool {
        spoken != name && editDistance(spoken, name) <= max(1, name.count / 6)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }
}
