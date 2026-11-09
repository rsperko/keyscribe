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
    indirect case unbroken(AgentAddress, unaddressed: String)

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

    public static func parse(
        _ text: String, names: [String], namesKnown: Bool = true, read: ((String) -> String)? = nil
    ) -> AgentAddress {
        parse(text, names: names, namesKnown: namesKnown, read: read, explicit: false, assumeTold: false)
    }

    private static func parse(
        _ text: String, names: [String], namesKnown: Bool, read: ((String) -> String)?, explicit: Bool, assumeTold: Bool,
        skipsOpeners: Bool = true
    ) -> AgentAddress {
        let tokens = words(in: text)
        let bare = tokens.map { AgentHandles.normalize(String(text[$0])) }
        func body(after count: Int) -> String { rest(of: text, after: tokens[count - 1]) }
        guard !bare.isEmpty else { return .none(body: text) }

        if !assumeTold, let opened = opening(tokens, bare: bare, in: text, names: names, namesKnown: namesKnown, read: read) {
            return .open(opened)
        }

        if !assumeTold, let verb = addressVerb(bare) {
            guard verb.count < tokens.count else { return .none(body: text) }
            let target = body(after: verb.count)
            let addressed = namesKnown && bare[verb.count] == "the"
                ? article(target, said: text, names: names, namesKnown: namesKnown, read: read, explicit: explicit)
                : parse(target, names: names, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: true)
            switch addressed {
            case .name, .row, .ambiguous, .nearMiss, .unbroken: return addressed
            case .unresolved where !verb.soft: return addressed
            default: return .none(body: text)
            }
        }
        let opened = bare.prefix { openers.contains($0) }.count
        if !assumeTold, skipsOpeners, opened > 0, opened < tokens.count {
            let whole = parse(text, names: names, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: false, skipsOpeners: false)
            if case .none = whole {} else { return whole }
            switch parse(body(after: opened), names: names, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: false) {
            case .none: return .none(body: text)
            case .nearMiss(let spoken, let name, let body, _): return .nearMiss(spoken: spoken, name: name, body: body, unaddressed: text)
            case let address: return address
            }
        }
        let available = tokens.count
        func spoken(_ length: Int) -> String { bare[0..<length].joined(separator: " ") }
        func unresolved(_ length: Int) -> AgentAddress { .unresolved(spoken: spoken(length), body: body(after: length)) }

        if bare[0] == "session", available > 1 {
            let said = bare[1]
            if let row = Int(said) ?? rowWords.firstIndex(of: said).map({ $0 + 1 }) { return .row(row, body: body(after: 2)) }
            if soundsLikeARow.contains(said) { return unresolved(2) }
        }

        let normalized = Array(Set(names.map(AgentHandles.normalize))).sorted()
            .filter { assumeTold || explicit || !isNumberLike($0) }
        let span = (0..<available).first { endsAddress(String(text[tokens[$0]])) }.map { $0 + 1 } ?? available
        let longestName = normalized.map { $0.split(separator: " ").count }.max() ?? 0
        let lengths = Array(1...min(longestName + 1, span))
        func readName() -> SpokenNameMatch.Leading? {
            guard let read, longestName > 0 else { return nil }
            func reading(_ length: Int) -> String {
                AgentHandles.matchKey(read(String(text[tokens[0].lowerBound..<tokens[length - 1].upperBound])))
            }
            for longest in stride(from: min(2 * longestName + 1, span), through: 1, by: -1) {
                let said = reading(longest)
                let hits = normalized.filter { AgentHandles.matchKey($0) == said }
                guard !said.isEmpty, !hits.isEmpty else { continue }
                let length = (1..<longest).first { reading($0) == said } ?? longest
                let heard = AgentHandles.matchKey(spoken(length))
                let distance = editDistance(heard, said)
                let rivals = normalized.filter { !hits.contains($0) && editDistance(heard, AgentHandles.matchKey($0)) <= distance }
                return rivals.isEmpty ? .init(length: length, names: hits) : nil
            }
            return nil
        }
        let found = SpokenNameMatch.leading(
            Array(bare[...]), names: normalized, limit: span,
            minimumWords: { assumeTold || $0 == .exact ? 1 : 2 }) ?? readName()
        if bare[0] == "session", span > 1, found.map({ $0.length == 1 }) ?? true {
            let named = parse(
                body(after: 1), names: names, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: assumeTold)
            if case .none = named {} else { return named }
        }
        func nearName(_ length: Int) -> String? {
            let said = AgentHandles.matchKey(spoken(length))
            guard found == nil, assumeTold || said.count >= minimumUntoldNearMiss else { return nil }
            return normalized.first { soundsAlike(said, AgentHandles.matchKey($0)) }
        }
        if let near = lengths.last(where: { nearName($0) != nil }), let name = nearName(near) {
            return .nearMiss(spoken: spoken(near), name: name, body: body(after: near), unaddressed: !assumeTold ? text : nil)
        }
        guard assumeTold || found != nil else { return .none(body: text) }
        if let found {
            let next = found.length
            if next < tokens.count, next < span, AgentHandles.distinguishingWords.contains(bare[next]) {
                return unresolved(found.length + 1)
            }
            guard found.names.count == 1 else {
                return .ambiguous(spoken: spoken(found.length), names: found.names, body: body(after: next))
            }
            return .name(found.names[0], body: body(after: next))
        }
        if namesKnown, notAnAddress.contains(bare[0]) { return .none(body: text) }
        let candidates = 1...min(4, available)
        let beforeTo = candidates.first { $0 < tokens.count && bare[$0] == "to" }
        let marked = candidates.first { endsAddress(String(text[tokens[$0 - 1]])) }
        return unresolved([beforeTo, marked].compactMap { $0 }.min() ?? 1)
    }

    public static func spokenName(
        _ spoken: String, names: [String], namesKnown: Bool = true, read: ((String) -> String)? = nil
    ) -> AgentAddress {
        let addressed = namesKnown && words(in: spoken).first.map({ AgentHandles.normalize(String(spoken[$0])) }) == "the"
            ? article(spoken, said: spoken, names: names, namesKnown: namesKnown, read: read, explicit: false)
            : parse(spoken, names: names, namesKnown: namesKnown, read: read, explicit: false, assumeTold: true)
        switch addressed {
        case .name(_, ""), .row(_, ""), .ambiguous(_, _, ""), .nearMiss(_, _, "", _): return addressed
        default: return .none(body: spoken)
        }
    }

    private static let openers: Set<String> = ["please", "hey", "so", "okay", "ok"]

    private static func addressVerb(_ bare: [String]) -> (count: Int, soft: Bool)? {
        let polite = bare.prefix { openers.contains($0) }.count
        guard bare.count > polite else { return nil }
        switch bare[polite] {
        case "tell": return (polite + 1, false)
        case "ask": return (polite + 1, true)
        default: return nil
        }
    }

    private static let breakWords: Set<String> = [
        "to", "that", "about", "whether", "if", "what", "why", "how", "when", "where", "which", "who", "for", "not", "please",
    ]

    private static func article(
        _ text: String, said: String, names: [String], namesKnown: Bool, read: ((String) -> String)?, explicit: Bool
    ) -> AgentAddress {
        let withArticle = parse(text, names: names, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: true)
        switch withArticle {
        case .name(_, let body), .ambiguous(_, _, let body):
            if words(in: text).count - words(in: body).count > 1 { return withArticle }
        default: break
        }
        guard let the = words(in: text).first else { return .none(body: said) }
        let named = rest(of: text, after: the)
        let inner = parse(named, names: names, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: true)
        switch inner {
        case .name(_, let body), .row(_, let body), .ambiguous(_, _, let body), .nearMiss(_, _, let body, _):
            return breaks(before: body, in: named) ? inner : .unbroken(inner, unaddressed: said)
        default:
            return .none(body: said)
        }
    }

    private static func breaks(before body: String, in text: String) -> Bool {
        guard !body.isEmpty else { return true }
        let address = text.dropLast(body.count).trimmingCharacters(in: .whitespaces)
        if address.hasSuffix(",") || address.hasSuffix(":") { return true }
        let first = words(in: body).first.map { AgentHandles.normalize(String(body[$0])) }
        return first.map(breakWords.contains) ?? true
    }

    private static func opening(
        _ tokens: [Range<String.Index>], bare: [String], in text: String, names: [String], namesKnown: Bool,
        read: ((String) -> String)?
    ) -> AgentAddress? {
        guard let verb = VoiceCommandGrammar.focusVerbs.map({ $0.split(separator: " ").map(String.init) })
            .first(where: { bare.starts(with: $0) && bare.count > $0.count })
        else { return nil }
        let skipped = verb.count + (bare.count > verb.count + 1 && bare[verb.count] == "the" ? 1 : 0)
        let target = rest(of: text, after: tokens[skipped - 1])
        guard !target.isEmpty else { return nil }
        let inner = parse(target, names: names, namesKnown: namesKnown, read: read, explicit: true, assumeTold: false)
        switch inner {
        case .name(_, ""), .row(_, ""), .ambiguous(_, _, ""), .nearMiss(_, _, "", _), .unresolved(_, ""): return inner
        case .none: return unmatchedNavigation(target)
        default: return bare[skipped] == "session" ? unmatchedNavigation(target) : nil
        }
    }

    public static let navigationWords = 3

    private static func unmatchedNavigation(_ target: String) -> AgentAddress? {
        let words = AgentHandles.normalize(target).split(separator: " ").map(String.init)
        if words.first == "session", words.count > 1 {
            return .unresolved(spoken: words.dropFirst().joined(separator: " "), body: "")
        }
        guard let first = words.first, !notAnAddress.contains(first) else { return nil }
        guard words.count <= navigationWords || isNumberLike(target) else { return nil }
        return .unresolved(spoken: words.joined(separator: " "), body: "")
    }

    public static func closest(to spoken: String, among names: [String]) -> [String] {
        let said = AgentHandles.matchKey(spoken)
        let scored = names.map { ($0, editDistance(said, AgentHandles.matchKey($0))) }
            .filter { $0.1 > 0 && $0.1 <= max(1, AgentHandles.matchKey($0.0).count / 3) }
        guard let best = scored.map(\.1).min() else { return [] }
        return scored.filter { $0.1 == best }.map(\.0).sorted()
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
