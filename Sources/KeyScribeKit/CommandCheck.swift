import Foundation

// Pure assertion model for the `--commands-check` dev harness. The harness transcribes recorded
// audio, runs the real local dictation pipeline, and hands each case's final output here to check
// that a spoken command behaved. Assertions are declarative data (a manifest row), so exercising a
// new command is adding a case, not code (principles.md §2). Matching for presence/absence is
// case-insensitive — STT casing varies (a sentence-initial "Insert new line" vs mid-utterance
// "insert new line"), and "was the trigger phrase consumed" must not hinge on how the engine cased
// it; `equals` stays exact because a whole-utterance replacement's output is generated, not heard.
public enum CommandCheck {
    public struct Assertion: Equatable, Sendable, Decodable {
        // Substrings that MUST appear (the inserted control char, clipboard value, or a literal that
        // proves a command did NOT fire).
        public var contains: [String]
        // Substrings that MUST be absent (a consumed trigger phrase, or text "scratch that" removed).
        public var absent: [String]
        // The whole output must equal this (a whole-utterance replacement's generated value).
        public var equals: String?
        // This value must appear with no sentence/clause punctuation immediately before it (the
        // spurious-terminator-before-paste artifact the clipboard fold removes).
        public var noLeadingPunct: String?

        public init(
            contains: [String] = [], absent: [String] = [],
            equals: String? = nil, noLeadingPunct: String? = nil
        ) {
            self.contains = contains
            self.absent = absent
            self.equals = equals
            self.noLeadingPunct = noLeadingPunct
        }

        enum CodingKeys: String, CodingKey { case contains, absent, equals, noLeadingPunct }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            contains = try c.decodeIfPresent([String].self, forKey: .contains) ?? []
            absent = try c.decodeIfPresent([String].self, forKey: .absent) ?? []
            equals = try c.decodeIfPresent(String.self, forKey: .equals)
            noLeadingPunct = try c.decodeIfPresent(String.self, forKey: .noLeadingPunct)
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let passed: Bool
        public let failures: [String]
    }

    public static func evaluate(output: String, assertion: Assertion) -> Outcome {
        var failures: [String] = []
        for needle in assertion.contains where !needle.isEmpty
        && output.range(of: needle, options: .caseInsensitive) == nil {
            failures.append("missing \(display(needle))")
        }
        for needle in assertion.absent where !needle.isEmpty
        && output.range(of: needle, options: .caseInsensitive) != nil {
            failures.append("survived \(display(needle))")
        }
        if let expected = assertion.equals, output != expected {
            failures.append("expected exactly \(display(expected)), got \(display(output))")
        }
        if let value = assertion.noLeadingPunct, hasLeadingPunct(before: value, in: output) {
            failures.append("punctuation before \(display(value))")
        }
        return Outcome(passed: failures.isEmpty, failures: failures)
    }

    // True if the char immediately before `value` (skipping one run of spaces) is sentence or clause
    // punctuation. Locates `value` case-insensitively; a value absent from the text is not an artifact.
    static func hasLeadingPunct(before value: String, in text: String) -> Bool {
        guard let r = text.range(of: value, options: .caseInsensitive) else { return false }
        var i = r.lowerBound
        while i > text.startIndex {
            let prev = text.index(before: i)
            if text[prev] == " " { i = prev } else { return ".,;:!?".contains(text[prev]) }
        }
        return false
    }

    static func display(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
}
