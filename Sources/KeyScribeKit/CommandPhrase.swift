import Foundation

// Shared builder for spoken-command phrase regexes (verbatim markers, clipboard insert). Between a
// phrase's words it tolerates an optional weak separator — STT transcribes a spoken pause as a
// comma/semicolon/colon mid-phrase ("begin, verbatim", "insert clipboard, contents") — so a
// spuriously-punctuated pause still fires the command. Phrases are lowercased and matched
// case-insensitively (`(?i)`); the input is engine-cased STT output.
public enum CommandPhrase {
    private static func wordJoined(_ phrase: String) -> String {
        NSRegularExpression.escapedPattern(for: phrase.lowercased())
            .replacingOccurrences(of: " ", with: "[,;:]?\\s+")
    }

    static func boundedTrigger(_ phrase: String) -> String {
        #"\b"# + wordJoined(phrase) + #"\b"#
    }

    static func alternationRegex(_ phrases: [String]) -> NSRegularExpression? {
        let alternation = phrases.filter { !$0.isEmpty }.map(wordJoined).joined(separator: "|")
        guard !alternation.isEmpty else { return nil }
        return RegexCache.regex("(?i)\\b(?:\(alternation))\\b", options: [])
    }
}
