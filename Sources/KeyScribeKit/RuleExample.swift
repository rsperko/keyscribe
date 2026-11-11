import Foundation

public struct RuleExample: Equatable, Sendable {
    public let said: String
    public let result: String
    let tried: String
    let output: String

    public init(said: String, result: String) {
        self.init(said: said, result: result, tried: said, output: result)
    }

    init(said: String, result: String, tried: String, output: String) {
        self.said = said
        self.result = result
        self.tried = tried
        self.output = output
    }

    public static func == (lhs: RuleExample, rhs: RuleExample) -> Bool {
        lhs.said == rhs.said && lhs.result == rhs.result
    }

    static let placeholder = "\u{2026}"
    private static let slot = "\u{E000}"
    private static let sample = "sample words"
    private static let limit = 4

    public static func examples(for rule: ReplacementRule) -> [RuleExample] {
        guard case .ready(let regex, let template, let submit) = ReplacementsStage.prepare(rule) else { return [] }
        let phrases = rule.isRegex ? (PatternReader.phrases(rule.heard, slot: slot) ?? []) : [rule.heard]
        var seen = Set<String>()
        var examples: [RuleExample] = []
        for phrase in phrases where examples.count < limit {
            let tried = phrase.replacingOccurrences(of: slot, with: sample)
            guard let match = completeMatch(regex, tried) else { continue }
            let output = regex.replacementString(for: match, in: tried, offset: 0, template: template)
            let said = phrase.replacingOccurrences(of: slot, with: placeholder)
            guard seen.insert(said.lowercased()).inserted else { continue }
            examples.append(RuleExample(
                said: said, result: readable(output.replacingOccurrences(of: sample, with: placeholder), submit: submit),
                tried: tried, output: output))
        }
        return examples
    }

    public static func matchesCompletely(_ rule: ReplacementRule, _ said: String) -> Bool {
        guard case .ready(let regex, _, _) = ReplacementsStage.prepare(rule) else { return false }
        return completeMatch(regex, said) != nil
    }

    private static func completeMatch(_ regex: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: whole), match.range == whole else { return nil }
        return match
    }

    private static func readable(_ output: String, submit: Mode.Submit?) -> String {
        var parts: [String] = []
        var text = ""
        func flush() {
            let kept = text.trimmingCharacters(in: .whitespaces)
            if !kept.isEmpty { parts.append(kept) }
            text = ""
        }
        var chars = Array(output)[...]
        while let char = chars.first {
            chars = chars.dropFirst()
            switch char {
            case "\n" where chars.first == "\n":
                chars = chars.dropFirst()
                flush()
                parts.append("New paragraph")
            case "\n", "\r":
                flush()
                parts.append("New line")
            case "\t":
                flush()
                parts.append("Tab")
            default:
                text.append(char)
            }
        }
        flush()
        let shown = parts.isEmpty ? "Nothing" : parts.joined(separator: " + ")
        return submit == nil ? shown : shown + ", then presses Return"
    }
}

private struct PatternReader {
    indirect enum Node {
        case text(String)
        case either([[Node]])
        case optional([[Node]])
    }

    private enum Atom {
        case literal(Character)
        case space
        case quiet(Character)
        case zeroWidth
        case group([[Node]])
        case open
    }

    private let chars: [Character]
    private let slot: String
    private var index = 0
    private var captures = 0

    static func phrases(_ pattern: String, slot: String) -> [String]? {
        var reader = PatternReader(chars: Array(pattern), slot: slot)
        guard let alternatives = reader.alternation(), reader.index == reader.chars.count else { return nil }
        var seen = Set<String>()
        return alternatives.flatMap(expand).compactMap { raw in
            let phrase = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return phrase.isEmpty || !seen.insert(phrase).inserted ? nil : phrase
        }
    }

    private init(chars: [Character], slot: String) {
        self.chars = chars
        self.slot = slot
    }

    private static func expand(_ sequence: [Node]) -> [String] {
        var results = [""]
        for node in sequence {
            let options: [String] = switch node {
            case .text(let text): [text]
            case .either(let alternatives): alternatives.flatMap(expand)
            case .optional(let alternatives): alternatives.flatMap(expand) + [""]
            }
            results = Array(results.flatMap { result in options.map { result + $0 } }.prefix(16))
        }
        return results
    }

    private var current: Character? { index < chars.count ? chars[index] : nil }

    private mutating func eat(_ char: Character) -> Bool {
        guard current == char else { return false }
        index += 1
        return true
    }

    private mutating func alternation() -> [[Node]]? {
        var alternatives: [[Node]] = []
        repeat {
            guard let sequence = sequence() else { return nil }
            alternatives.append(sequence)
        } while eat("|")
        return alternatives
    }

    private mutating func sequence() -> [Node]? {
        var nodes: [Node] = []
        while let char = current, char != "|", char != ")" {
            guard let atom = atom(), let produced = quantified(atom) else { return nil }
            nodes += produced
        }
        return nodes
    }

    private mutating func atom() -> Atom? {
        guard let char = current else { return nil }
        index += 1
        switch char {
        case "^", "$": return .zeroWidth
        case ".": return .open
        case "[": return characterClass()
        case "(": return group()
        case "\\": return escape()
        case "*", "+", "?", "{", "}", "]": return nil
        case _ where char.isWhitespace: return .space
        default: return .literal(char)
        }
    }

    private mutating func escape() -> Atom? {
        guard let char = current else { return nil }
        index += 1
        switch char {
        case "s": return .space
        case "b", "A", "z", "Z": return .zeroWidth
        case "w", "d", "S", "W", "D": return .open
        case _ where char.isLetter || char.isNumber: return nil
        default: return .literal(char)
        }
    }

    private mutating func group() -> Atom? {
        var capturing = true
        if eat("?") {
            if eat(":") {
                capturing = false
            } else {
                while let char = current, char.isLetter || char == "-" { index += 1 }
                return eat(")") ? .zeroWidth : nil
            }
        }
        if capturing { captures += 1 }
        defer { if capturing { captures -= 1 } }
        guard let alternatives = alternation(), eat(")") else { return nil }
        return .group(alternatives)
    }

    private mutating func characterClass() -> Atom? {
        var members: [Character] = []
        var space = false
        if current == "^" { return nil }
        while let char = current, char != "]" {
            index += 1
            if char == "\\" {
                guard let escaped = current else { return nil }
                index += 1
                if escaped == "s" { space = true } else if escaped.isLetter || escaped.isNumber { return nil } else { members.append(escaped) }
            } else if char == "-", !members.isEmpty, current != "]" {
                return nil
            } else if char.isWhitespace {
                space = true
            } else {
                members.append(char)
            }
        }
        guard eat("]") else { return nil }
        if space { return .space }
        guard let first = members.first else { return nil }
        if members.allSatisfy({ $0.isPunctuation || $0.isSymbol }) { return .quiet(first) }
        return members.allSatisfy({ $0.isLetter }) ? .literal(first) : nil
    }

    private mutating func quantified(_ atom: Atom) -> [Node]? {
        enum Count { case one, optional, any, some }
        var count = Count.one
        if eat("?") {
            count = .optional
        } else if eat("*") {
            count = .any
        } else if eat("+") {
            count = .some
        } else if current == "{" {
            while let char = current, char != "}" { index += 1 }
            guard eat("}") else { return nil }
            count = .some
        }
        if count != .one { _ = eat("?") || eat("+") }
        let skipped = count == .optional || count == .any
        switch atom {
        case .zeroWidth: return count == .one ? [] : nil
        case .space: return [.text(" ")]
        case .literal(let char), .quiet(let char): return skipped ? [] : [.text(String(char))]
        case .open: return captures > 0 && (count == .some || count == .any) ? [.text(slot)] : nil
        case .group(let alternatives): return [skipped ? .optional(alternatives) : .either(alternatives)]
        }
    }
}
