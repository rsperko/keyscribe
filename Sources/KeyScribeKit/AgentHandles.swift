import Foundation

public enum AgentHandles {
    public struct Conversation: Equatable, Sendable {
        public var id: String
        public var folder: String
        public var name: String?
        public init(id: String, folder: String, name: String? = nil) {
            self.id = id
            self.folder = folder
            self.name = name
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
            let base = conversation.name.map(normalize) ?? base(forFolder: conversation.folder)
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
    case unresolved(spoken: String, body: String)
    case ambiguous(spoken: String, names: [String], body: String)
    case nearMiss(spoken: String, name: String, body: String, unaddressed: String?)
    case none(body: String)
    indirect case open(AgentAddress)

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
    private static let minimumUntoldNearMiss = 6

    static func isRowWord(_ word: String) -> Bool {
        Int(word) != nil || rowWords.contains(word) || soundsLikeARow.contains(word)
    }

    public static func parse(_ text: String, names: [String], namesKnown: Bool = true) -> AgentAddress {
        parse(text, names: names, namesKnown: namesKnown, explicit: false, assumeTold: false)
    }

    private static func parse(_ text: String, names: [String], namesKnown: Bool, explicit: Bool, assumeTold: Bool) -> AgentAddress {
        let tokens = words(in: text)
        let bare = tokens.map { AgentHandles.normalize(String(text[$0])) }
        func body(after count: Int) -> String { rest(of: text, after: tokens[count - 1]) }
        guard let first = bare.first else { return .none(body: text) }

        if !assumeTold, let opened = opening(tokens, bare: bare, in: text, names: names, namesKnown: namesKnown) { return .open(opened) }

        let told = assumeTold ? 0 : first == "please" && bare.count > 1 && bare[1] == "tell" ? 2 : first == "tell" ? 1 : nil
        let start = told ?? 0
        guard start < tokens.count else { return .none(body: text) }
        let available = tokens.count - start
        func spoken(_ length: Int) -> String { bare[start..<(start + length)].joined(separator: " ") }
        func unresolved(_ length: Int) -> AgentAddress { .unresolved(spoken: spoken(length), body: body(after: start + length)) }

        if bare[start] == "session", available > 1 {
            let said = bare[start + 1]
            if let row = Int(said) ?? rowWords.firstIndex(of: said).map({ $0 + 1 }) { return .row(row, body: body(after: start + 2)) }
            if soundsLikeARow.contains(said) { return unresolved(2) }
        }

        let normalized = Array(Set(names.map(AgentHandles.normalize))).sorted()
            .filter { told != nil || explicit || !isNumberLike($0) }
        let span = (0..<available).first { endsAddress(String(text[tokens[start + $0]])) }.map { $0 + 1 } ?? available
        let lengths = Array(1...min((normalized.map { $0.split(separator: " ").count }.max() ?? 0) + 1, span))
        let found = SpokenNameMatch.leading(
            Array(bare[start...]), names: normalized, limit: span,
            minimumWords: { told != nil || $0 == .exact ? 1 : 2 })
        if bare[start] == "session", span > 1, found.map({ $0.length == 1 }) ?? true {
            let named = parse(body(after: start + 1), names: names, namesKnown: namesKnown, explicit: explicit, assumeTold: told != nil)
            if case .none = named {} else { return named }
        }
        func nearName(_ length: Int) -> String? {
            let said = AgentHandles.matchKey(spoken(length))
            guard found == nil, told != nil || said.count >= minimumUntoldNearMiss else { return nil }
            return normalized.first { soundsAlike(said, AgentHandles.matchKey($0)) }
        }
        if let near = lengths.last(where: { nearName($0) != nil }), let name = nearName(near) {
            return .nearMiss(spoken: spoken(near), name: name, body: body(after: start + near), unaddressed: told == nil ? text : nil)
        }
        guard told != nil || found != nil else { return .none(body: text) }
        if let found {
            let next = start + found.length
            if next < tokens.count, next - start < span, AgentHandles.distinguishingWords.contains(bare[next]) {
                return unresolved(found.length + 1)
            }
            guard found.names.count == 1 else {
                return .ambiguous(spoken: spoken(found.length), names: found.names, body: body(after: next))
            }
            return .name(found.names[0], body: body(after: next))
        }
        if namesKnown, notAnAddress.contains(bare[start]) { return .none(body: text) }
        let candidates = 1...min(4, available)
        let beforeTo = candidates.first { start + $0 < tokens.count && bare[start + $0] == "to" }
        let marked = candidates.first { endsAddress(String(text[tokens[start + $0 - 1]])) }
        return unresolved([beforeTo, marked].compactMap { $0 }.min() ?? 1)
    }

    private static func opening(_ tokens: [Range<String.Index>], bare: [String], in text: String, names: [String], namesKnown: Bool) -> AgentAddress? {
        guard let verb = VoiceCommandGrammar.focusVerbs.map({ $0.split(separator: " ").map(String.init) })
            .first(where: { bare.starts(with: $0) && bare.count > $0.count })
        else { return nil }
        let skipped = verb.count + (bare.count > verb.count + 1 && bare[verb.count] == "the" ? 1 : 0)
        let target = rest(of: text, after: tokens[skipped - 1])
        guard !target.isEmpty else { return nil }
        let inner = parse(target, names: names, namesKnown: namesKnown, explicit: true, assumeTold: false)
        switch inner {
        case .name(_, ""), .row(_, ""), .ambiguous(_, _, ""), .nearMiss(_, _, "", _), .unresolved(_, ""): return inner
        case .none where isNumberLike(target): return .unresolved(spoken: AgentHandles.normalize(target), body: "")
        default: return nil
        }
    }

    private static func isNumberLike(_ name: String) -> Bool {
        let words = AgentHandles.normalize(name).split(separator: " ").map(String.init)
        return !words.isEmpty && words.allSatisfy(isRowWord)
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

extension AgentAddress {
    static let connectingWords: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "from", "in", "into", "of", "on", "or", "the", "to", "with"]

    public static func shorterSpokenName(for name: String, among names: [String]) -> String? {
        let words = name.split(separator: " ")
        let candidates = Array(Set(names + [name]))
        for count in words.indices.dropFirst() where !connectingWords.contains(String(words[count - 1])) {
            let spoken = words.prefix(count).joined(separator: " ")
            if case .name(name, let body) = parse("\(spoken), run the unit tests.", names: candidates), !body.isEmpty {
                return spoken
            }
        }
        return nil
    }
}
