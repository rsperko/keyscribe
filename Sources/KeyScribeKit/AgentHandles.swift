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
        asciiNormalized(raw) ?? normalizeCharacters(raw)
    }

    private static func asciiNormalized(_ raw: String) -> String? {
        var words: [String] = []
        var word: [UInt8] = []
        func endWord() {
            guard !word.isEmpty else { return }
            let text = String(decoding: word, as: UTF8.self)
            if let n = Int(text), String(n) == text, (2...10).contains(n) { words.append(numberWords[n - 2]) } else { words.append(text) }
            word.removeAll(keepingCapacity: true)
        }
        for byte in raw.utf8 {
            switch byte {
            case 0x80...: return nil
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): word.append(byte + 0x20)
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): word.append(byte)
            default: endWord()
            }
        }
        endWord()
        return words.joined(separator: " ")
    }

    static func normalizeCharacters(_ raw: String) -> String {
        let spaced = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(spaced)
            .split(separator: " ")
            .map { token in
                guard let n = Int(token), String(n) == token, (2...10).contains(n) else { return String(token) }
                return numberWords[n - 2]
            }
            .joined(separator: " ")
    }

    public static func base(forFolder folder: String) -> String {
        normalize(folder)
    }

    public static let distinguishingWords = ["blue", "green", "orange", "purple", "yellow", "pink", "silver", "brown", "amber", "black"]

    static func spelling(_ raw: String) -> String {
        normalize(raw).filter { $0 != " " }
    }

    public static func matchKey(_ raw: String) -> String {
        normalize(raw).split(separator: " ").map { singular(String($0)) }.joined()
    }

    public static func singular(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), word.allSatisfy(\.isLetter) else { return word }
        if word.hasSuffix("ies") { return word.dropLast(3) + "y" }
        if ["ses", "xes", "zes", "ches", "shes"].contains(where: word.hasSuffix) { return String(word.dropLast(2)) }
        if ["ss", "us", "is"].contains(where: word.hasSuffix) { return word }
        return String(word.dropLast())
    }

    public static func isReserved(_ name: String) -> Bool {
        let words = normalize(name).split(separator: " ").map(String.init)
        guard let first = words.first, AgentAddress.rowNouns.contains(first) else { return false }
        return words.count == 1 || AgentAddress.isRowWord(words[1])
    }

    public static func assign(_ conversations: [Conversation], existing: [String: String], reserved: Set<String> = []) -> [String: String] {
        let live = Set(conversations.map(\.id))
        var assigned = existing.filter { live.contains($0.key) }
        var taken = Set(assigned.values.map(matchKey)).union(reserved.map(matchKey))
        for conversation in conversations where assigned[conversation.id] == nil {
            let base = conversation.name.map(normalize) ?? base(forFolder: conversation.folder)
            let free = { (name: String) in !taken.contains(matchKey(name)) && !isReserved(name) }
            let candidate = free(base) ? base : firstSuffixed(base, where: free) ?? "\(base) \(conversation.id)"
            assigned[conversation.id] = candidate
            taken.insert(matchKey(candidate))
        }
        return assigned
    }

    private static func firstSuffixed(_ base: String, where free: (String) -> Bool) -> String? {
        let used = Set(base.split(separator: " ").map(String.init))
        let words = distinguishingWords.filter { !used.contains($0) }
        for first in words where free("\(base) \(first)") { return "\(base) \(first)" }
        for first in words {
            for second in words where second != first && free("\(base) \(first) \(second)") { return "\(base) \(first) \(second)" }
        }
        for first in words {
            for second in words where second != first {
                for third in words where third != first && third != second && free("\(base) \(first) \(second) \(third)") {
                    return "\(base) \(first) \(second) \(third)"
                }
            }
        }
        return nil
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
    case native(spoken: String, handles: [String: String], body: String)
    case nearMiss(spoken: String, name: String, body: String, unaddressed: String?)
    case none(body: String)
    indirect case open(AgentAddress)
    indirect case unbroken(AgentAddress, unaddressed: String)

    private static let notAnAddress: Set<String> = [
        "me", "us", "him", "her", "them", "it", "you", "everyone", "everybody", "someone", "somebody", "people",
        "the", "a", "an", "my", "your", "our", "their", "his", "its", "this", "that", "these", "those",
        "what", "why", "how", "when", "where", "whether", "if", "who", "which",
    ]
    private static let notANameAfterAsk: Set<String> = [
        "again", "first", "later", "then", "now", "also", "always", "never", "only", "before", "after", "once",
        "yourself", "yourselves", "myself", "ourselves", "itself", "themselves",
    ]
    private static let rowWords = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    ]
    private static let soundsLikeARow: Set<String> = ["to", "too", "for"]
    static let rowNouns: Set<String> = ["session", "conversation"]
    private static let minimumUntoldNearMiss = 6

    static func isRowWord(_ word: String) -> Bool {
        Int(word) != nil || rowWords.contains(word) || soundsLikeARow.contains(word)
    }

    public struct Names: Sendable {
        public let names: [String]
        public let afterVerb: [String]
        let table: NameTable
        let withAfterVerb: NameTable
        let verbOnly: Set<String>

        public init(names: [String], afterVerb: [String] = []) {
            self.names = names
            self.afterVerb = afterVerb
            table = NameTable(names)
            withAfterVerb = afterVerb.isEmpty ? table : NameTable(names + afterVerb)
            verbOnly = Set(afterVerb.map(AgentHandles.matchKey))
        }
    }

    public static func parse(
        _ text: String, names: [String], namesKnown: Bool = true, read: ((String) -> String)? = nil, afterVerb: [String] = [],
        natives: AgentNativeRoster = AgentNativeRoster()
    ) -> AgentAddress {
        parse(text, among: Names(names: names, afterVerb: afterVerb), namesKnown: namesKnown, read: read, natives: natives)
    }

    public static func parse(
        _ text: String, among prepared: Names, namesKnown: Bool = true, read: ((String) -> String)? = nil,
        natives: AgentNativeRoster = AgentNativeRoster()
    ) -> AgentAddress {
        let found = parse(text, table: prepared.table, namesKnown: namesKnown, read: read, explicit: false, assumeTold: false, natives: natives)
        guard !prepared.afterVerb.isEmpty else { return found }
        let verbOnly = prepared.verbOnly
        func isVerbOnly(_ name: String) -> Bool { verbOnly.contains(AgentHandles.matchKey(name)) }
        let bare = words(in: text).map { AgentHandles.normalize(String(text[$0])) }
        let told = addressVerb(bare) != nil
        let said = bare.flatMap { $0.split(separator: " ").map(String.init) }.drop { openers.contains($0) }
        guard told || VoiceCommandGrammar.focusVerbs.contains(where: { said.starts(with: $0.split(separator: " ").map(String.init)) }) else {
            return found
        }
        func addressed(_ name: String, before body: String) -> Bool {
            guard isVerbOnly(name), body.count <= text.count else { return false }
            let head = String(text.dropLast(body.count))
            var said = words(in: head).flatMap { AgentHandles.normalize(String(head[$0])).split(separator: " ").map(String.init) }
            said.removeFirst(said.prefix { openers.contains($0) }.count)
            if said.count > 1, said.last == "please" { said.removeLast() }
            if let verb = addressVerb(said) {
                said.removeFirst(verb.count)
            } else if let verb = VoiceCommandGrammar.focusVerbs.map({ $0.split(separator: " ").map(String.init) })
                .first(where: { said.starts(with: $0) }) {
                said.removeFirst(verb.count)
            } else {
                return false
            }
            if said.first == "the" { said.removeFirst() }
            return exactName(said.joined(separator: " "), among: [name]) != nil
        }
        switch parse(text, table: prepared.withAfterVerb, namesKnown: namesKnown, read: nil, explicit: false, assumeTold: false, natives: natives) {
        case .open(.name(let name, "")) where addressed(name, before: ""):
            return .open(.name(name, body: ""))
        case .open(.native(let spoken, let handles, "")) where addressed(spoken, before: ""):
            return .open(.native(spoken: spoken, handles: handles, body: ""))
        case .name(let name, let body) where told && addressed(name, before: body):
            return .name(name, body: body)
        case .native(let spoken, let handles, let body) where told && addressed(spoken, before: body):
            return .native(spoken: spoken, handles: handles, body: body)
        default:
            return found
        }
    }

    public static func exactName(_ spoken: String, among names: [String]) -> String? {
        let wanted = AgentHandles.matchKey(spoken)
        return wanted.isEmpty ? nil : names.first { AgentHandles.matchKey($0) == wanted }
    }

    public static func asks(_ text: String) -> Bool {
        addressVerb(words(in: text).map { AgentHandles.normalize(String(text[$0])) })?.soft == true
    }

    private static func parse(
        _ text: String, table: NameTable, namesKnown: Bool, read: ((String) -> String)?, explicit: Bool, assumeTold: Bool,
        natives: AgentNativeRoster, skipsOpeners: Bool = true
    ) -> AgentAddress {
        let tokens = words(in: text)
        let bare = tokens.map { AgentHandles.normalize(String(text[$0])) }
        func body(after count: Int) -> String { rest(of: text, after: tokens[count - 1]) }
        guard !bare.isEmpty else { return .none(body: text) }

        if !assumeTold, let opened = opening(
            tokens, bare: bare, in: text, table: table, namesKnown: namesKnown, read: read, natives: natives,
            verbs: VoiceCommandGrammar.focusVerbs) {
            return .open(opened)
        }

        if !assumeTold, let verb = addressVerb(bare) {
            guard verb.count < tokens.count else { return .none(body: text) }
            let target = body(after: verb.count)
            let addressed = namesKnown && bare[verb.count] == "the"
                ? article(target, said: text, table: table, namesKnown: namesKnown, read: read, explicit: explicit, natives: natives)
                : parse(target, table: table, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: true, natives: natives)
            switch addressed {
            case .name, .row, .ambiguous, .native, .nearMiss, .unbroken: return addressed
            case .unresolved where !verb.soft: return addressed
            case .unresolved(let spoken, let body) where !notANameAfterAsk.contains(spoken) && asksAboutItself(body): return addressed
            default: return .none(body: text)
            }
        }
        let opened = bare.prefix { openers.contains($0) }.count
        if !assumeTold, skipsOpeners, opened > 0, opened < tokens.count {
            let whole = parse(
                text, table: table, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: false, natives: natives, skipsOpeners: false)
            if case .none = whole {} else { return whole }
            switch parse(
                body(after: opened), table: table, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: false, natives: natives) {
            case .none: return .none(body: text)
            case .nearMiss(let spoken, let name, let body, _): return .nearMiss(spoken: spoken, name: name, body: body, unaddressed: text)
            case let address: return address
            }
        }
        let available = tokens.count
        func spoken(_ length: Int) -> String { bare[0..<length].joined(separator: " ") }
        func unresolved(_ length: Int) -> AgentAddress { .unresolved(spoken: spoken(length), body: body(after: length)) }

        if rowNouns.contains(bare[0]), available > 1 {
            let said = bare[1]
            if let row = Int(said) ?? rowWords.firstIndex(of: said).map({ $0 + 1 }) { return .row(row, body: body(after: 2)) }
            if soundsLikeARow.contains(said) { return unresolved(2) }
        }

        let view = assumeTold || explicit ? table.all : table.unnumbered
        let entries = view.entries
        let span = (0..<available).first { endsAddress(String(text[tokens[$0]])) }.map { $0 + 1 } ?? available
        let longestName = view.longestWords
        let lengths = Array(1...min(longestName + 1, span))
        func reading(_ length: Int) -> String? {
            read.map { AgentHandles.matchKey($0(String(text[tokens[0].lowerBound..<tokens[length - 1].upperBound]))) }
        }
        func readName() -> SpokenNameMatch.Leading? {
            guard read != nil, longestName > 0 else { return nil }
            for longest in stride(from: min(2 * longestName + 1, span), through: 1, by: -1) {
                let said = reading(longest) ?? ""
                let hits = entries.filter { $0.matchKey == said }.map(\.name)
                guard !said.isEmpty, !hits.isEmpty else { continue }
                let length = (1..<longest).first { reading($0) == said } ?? longest
                let heard = AgentHandles.matchKey(spoken(length))
                let distance = editDistance(heard, said)
                let numbersOnly = AgentHandles.matchKey(InverseTextNormalizer.apply(spoken(length))) == said
                func leads(_ name: String) -> Bool {
                    let words = name.split(separator: " ")
                    return hits.contains { $0.split(separator: " ").starts(with: words) }
                }
                let rivals = numbersOnly ? [] : entries.filter {
                    !hits.contains($0.name) && !leads($0.name) && editDistance(heard, $0.matchKey) <= distance
                }
                return rivals.isEmpty ? .init(length: length, names: hits) : nil
            }
            return nil
        }
        let literal = SpokenNameMatch.leading(
            Array(bare[...]), keyed: assumeTold ? view.folded : view.plain, longest: view.longestCompact,
            limit: span, fold: assumeTold ? AgentHandles.singular : { $0 },
            minimumWords: { assumeTold || $0 == .exact ? 1 : explicit ? 2 : .max })
        let found = readName().flatMap { read in literal.map { read.length > $0.length } ?? true ? read : nil } ?? literal
        func nativeReading() -> (tokens: Int, handles: [String: String])? {
            let direct = natives.read(bare[..<span])
            guard let read, direct?.handles.isEmpty ?? true, !natives.addresses.isEmpty else { return direct }
            let longest = min(span, AgentNativeRoster.longestReadThroughReplacements)
            func prefix(_ length: Int) -> String { String(text[tokens[0].lowerBound..<tokens[length - 1].upperBound]) }
            let rewritten = AgentNativeRoster.words(read(prefix(longest)))
            guard rewritten != AgentNativeRoster.words(prefix(longest)) else { return direct }
            for length in stride(from: longest, through: 1, by: -1) {
                let said = length == longest ? rewritten : AgentNativeRoster.words(read(prefix(length)))
                guard let reading = natives.read(said[...]), reading.tokens == said.count else { continue }
                return (direct?.tokens ?? 0) > length || (direct?.tokens == length && reading.handles.isEmpty) ? direct : (length, reading.handles)
            }
            return direct
        }
        if let native = nativeReading() {
            let name = found.map { match -> (length: Int, exact: String?) in
                let key = match.names.count == 1 ? AgentHandles.matchKey(match.names[0]) : nil
                let exact = key.map { AgentHandles.matchKey(spoken(match.length)) == $0 || reading(match.length) == $0 } ?? false
                return (match.length, exact ? match.names[0] : nil)
            }
            if let handles = natives.settle(native, against: name) {
                return .native(spoken: spoken(native.tokens), handles: handles, body: body(after: native.tokens))
            }
        }
        if rowNouns.contains(bare[0]), span > 1, found.map({ $0.length == 1 }) ?? true {
            let named = parse(
                body(after: 1), table: table, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: assumeTold, natives: natives)
            if case .none = named {} else { return named }
        }
        func nearName(_ length: Int) -> String? {
            let said = AgentHandles.spelling(spoken(length))
            guard found == nil, assumeTold || said.count >= minimumUntoldNearMiss else { return nil }
            return entries.first { soundsAlike(said, $0.spelling) }?.name
        }
        if let near = lengths.last(where: { nearName($0) != nil }), let name = nearName(near) {
            return .nearMiss(spoken: spoken(near), name: name, body: body(after: near), unaddressed: !assumeTold ? text : nil)
        }
        guard assumeTold || found != nil else { return .none(body: text) }
        if let found {
            let next = found.length
            if next < tokens.count, next < span, AgentHandles.distinguishingWords.contains(bare[next]) { return unresolved(next + 1) }
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
        _ spoken: String, names: [String], namesKnown: Bool = true, read: ((String) -> String)? = nil,
        natives: AgentNativeRoster = AgentNativeRoster()
    ) -> AgentAddress {
        let table = NameTable(names)
        let addressed = namesKnown && words(in: spoken).first.map({ AgentHandles.normalize(String(spoken[$0])) }) == "the"
            ? article(spoken, said: spoken, table: table, namesKnown: namesKnown, read: read, explicit: false, natives: natives)
            : parse(spoken, table: table, namesKnown: namesKnown, read: read, explicit: false, assumeTold: true, natives: natives)
        switch addressed {
        case .name(_, ""), .row(_, ""), .ambiguous(_, _, ""), .native(_, _, ""), .nearMiss(_, _, "", _): return addressed
        default: return .none(body: spoken)
        }
    }

    struct NameTable: Sendable {
        struct Entry: Sendable {
            let name: String
            let matchKey: String
            let spelling: String
            let words: Int
            let compactLength: Int
            let numberLike: Bool
            let plain: SpokenNameMatch.Keyed
            let folded: SpokenNameMatch.Keyed
        }

        struct View: Sendable {
            let entries: [Entry]
            let plain: [(String, SpokenNameMatch.Keyed)]
            let folded: [(String, SpokenNameMatch.Keyed)]
            let longestWords: Int
            let longestCompact: Int

            init(_ entries: [Entry]) {
                self.entries = entries
                plain = entries.map { ($0.name, $0.plain) }
                folded = entries.map { ($0.name, $0.folded) }
                longestWords = entries.map(\.words).max() ?? 0
                longestCompact = entries.map(\.compactLength).max() ?? 0
            }
        }

        let all: View
        let unnumbered: View

        init(_ names: [String]) {
            let entries = Set(names.map(AgentHandles.normalize)).sorted().map { name in
                let plain = SpokenNameMatch.Keyed(name, fold: { $0 })
                let words = name.split(separator: " ")
                return Entry(
                    name: name, matchKey: words.map { AgentHandles.singular(String($0)) }.joined(), spelling: words.joined(),
                    words: words.count, compactLength: plain.compact.count, numberLike: isNumberLike(name),
                    plain: plain, folded: SpokenNameMatch.Keyed(name, fold: AgentHandles.singular))
            }
            all = View(entries)
            unnumbered = View(entries.filter { !$0.numberLike })
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

    private static func asksAboutItself(_ body: String) -> Bool {
        let said = AgentHandles.normalize(body).split(separator: " ").prefix(2).map(String.init)
        guard let first = said.first else { return false }
        if ["what", "whether", "why", "how"].contains(first) { return said.count == 1 || said[1] != "to" }
        guard said.count == 2, ["if", "when", "where"].contains(first) else { return false }
        return ["it", "they", "he", "she"].contains(said[1])
    }

    private static let breakWords: Set<String> = [
        "to", "that", "about", "whether", "if", "what", "why", "how", "when", "where", "which", "who", "for", "not", "please",
    ]

    private static func article(
        _ text: String, said: String, table: NameTable, namesKnown: Bool, read: ((String) -> String)?, explicit: Bool,
        natives: AgentNativeRoster
    ) -> AgentAddress {
        let withArticle = parse(text, table: table, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: true, natives: natives)
        switch withArticle {
        case .name(_, let body), .ambiguous(_, _, let body), .native(_, _, let body):
            if words(in: text).count - words(in: body).count > 1 { return withArticle }
        default: break
        }
        guard let the = words(in: text).first else { return .none(body: said) }
        let named = rest(of: text, after: the)
        let inner = parse(named, table: table, namesKnown: namesKnown, read: read, explicit: explicit, assumeTold: true, natives: natives)
        switch inner {
        case .name(_, let body), .row(_, let body), .ambiguous(_, _, let body), .native(_, _, let body), .nearMiss(_, _, let body, _):
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
        _ tokens: [Range<String.Index>], bare: [String], in text: String, table: NameTable, namesKnown: Bool,
        read: ((String) -> String)?, natives: AgentNativeRoster, verbs: [String]
    ) -> AgentAddress? {
        guard let verb = verbs.map({ $0.split(separator: " ").map(String.init) })
            .first(where: { bare.starts(with: $0) && bare.count > $0.count })
        else { return nil }
        let skipped = verb.count + (bare.count > verb.count + 1 && bare[verb.count] == "the" ? 1 : 0)
        let polite = bare.count > skipped + 1 && bare.last == "please" ? tokens.count - 1 : tokens.count
        let target = rest(of: text, after: tokens[skipped - 1], upTo: tokens[polite - 1].upperBound)
        guard !target.isEmpty else { return nil }
        let inner = parse(target, table: table, namesKnown: namesKnown, read: read, explicit: true, assumeTold: false, natives: natives)
        switch inner {
        case .name(_, ""), .row(_, ""), .ambiguous(_, _, ""), .native(_, _, ""), .nearMiss(_, _, "", _), .unresolved(_, ""): return inner
        case .none: return unmatchedNavigation(target)
        default: return rowNouns.contains(bare[skipped]) ? unmatchedNavigation(target) : nil
        }
    }

    public static let navigationWords = 3

    private static func unmatchedNavigation(_ target: String) -> AgentAddress? {
        let words = AgentHandles.normalize(target).split(separator: " ").map(String.init)
        if let first = words.first, rowNouns.contains(first), words.count > 1 {
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

    public static func resembling(_ spoken: String, among names: [String]) -> String? {
        let said = AgentHandles.normalize(spoken).split(separator: " ").map { AgentHandles.singular(String($0)) }
        guard !said.isEmpty else { return nil }
        let scored = names.compactMap { name -> (name: String, distance: Int)? in
            let words = AgentHandles.normalize(name).split(separator: " ").map { AgentHandles.singular(String($0)) }
            guard !words.isEmpty else { return nil }
            if words.starts(with: said) || said.starts(with: words) { return (name, 0) }
            guard words.count >= said.count else { return nil }
            let distances = zip(said, words).map { said, word in (editDistance(said, word), max(1, word.count / 3)) }
            guard distances.allSatisfy({ $0.0 <= $0.1 }) else { return nil }
            return (name, distances.map(\.0).reduce(0, +))
        }
        guard let best = scored.map(\.distance).min() else { return nil }
        let closest = scored.filter { $0.distance == best }
        return closest.count == 1 ? closest[0].name : nil
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

    private static func rest(of text: String, after word: Range<String.Index>, upTo end: String.Index? = nil) -> String {
        let remainder = text[word.upperBound..<(end ?? text.endIndex)].drop { $0.isWhitespace || $0 == "," || $0 == ":" }
        return remainder.contains(where: { $0.isLetter || $0.isNumber }) ? String(remainder) : ""
    }

    private static func endsAddress(_ word: String) -> Bool {
        word.hasSuffix(",") || word.hasSuffix(":")
    }

    private static func soundsAlike(_ spoken: String, _ name: String) -> Bool {
        let allowed = max(1, name.count / 6)
        return spoken != name && abs(spoken.count - name.count) <= allowed && editDistance(spoken, name, within: allowed) <= allowed
    }

    private static func editDistance(_ a: String, _ b: String, within limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        var row = previous
        for i in 1...a.count {
            row[0] = i
            var smallest = i
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                smallest = min(smallest, row[j])
            }
            if smallest > limit { return smallest }
            swap(&previous, &row)
        }
        return previous[b.count]
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

    public static func shorterSpokenName(for name: String, among names: [String], natives: AgentNativeRoster = AgentNativeRoster()) -> String? {
        let words = name.split(separator: " ")
        let candidates = Array(Set(names + [name]))
        for count in words.indices.dropFirst() where !connectingWords.contains(String(words[count - 1])) {
            let spoken = words.prefix(count).joined(separator: " ")
            if case .name(name, let body) = parse("tell \(spoken), run the unit tests.", names: candidates, natives: natives), !body.isEmpty {
                return spoken
            }
        }
        return nil
    }
}
