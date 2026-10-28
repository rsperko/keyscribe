import Foundation

public enum ReplacementAuthoring {
    public static let maxCharacters = 65_536
    public static let previewLimit = 160

    public static func isWithinLimit(_ replacement: String) -> Bool {
        replacement.count <= maxCharacters
    }

    public static func normalizingLineEndings(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func regexReturnMarkerValid(_ replacement: String) -> Bool {
        guard replacement.contains("<CR>") else { return true }
        return ReturnSuffix.parse(ReplacementEscapes.expandTemplate(replacement)) != nil
    }

    public static func literalReturnMarkerAdvisory(replace: String, regex: Bool) -> String? {
        guard !regex, replace.contains("<CR>") else { return nil }
        return "Types “<CR>” as text. Only a regular-expression rule can press Return."
    }

    // The Email starter's sign-off before it stopped inserting a placeholder. An install that edited its Email
    // mode keeps this rule, so it is recognized exactly — never by its text alone — to point at the edit.
    public static let retiredSignOffRule = (heard: #"[\s,]*my sign[- ]?off[\s,.]*"#, replace: #"\n\nBest,\nYour Name"#)

    public static func placeholderAdvisory(heard: String, replace: String, regex: Bool) -> String? {
        guard regex, heard == retiredSignOffRule.heard, replace == retiredSignOffRule.replace else { return nil }
        return "Still inserts the placeholder “Your Name”. Edit it into your own sign-off."
    }

    // Wraps a pattern so neither end of a match can split a word, using the same regex `\w` that flags a match
    // as inside a word. An edge that is itself punctuation or space still matches beside a word. nil where the
    // wrap could change what the pattern means: free-spacing mode (a trailing comment would swallow the
    // wrapper), an existing lookaround at an edge, or a pattern that does not compile.
    public static func wholeWordPattern(_ pattern: String) -> String? {
        if pattern.range(of: #"\(\?[a-zA-Z]*x"#, options: .regularExpression) != nil { return nil }
        if pattern.hasPrefix("(?<=") || pattern.hasPrefix("(?<!") { return nil }
        if pattern.range(of: #"\(\?[=!][^()]*\)$"#, options: .regularExpression) != nil { return nil }
        let wrapped = #"(?:(?<!\w)|(?!\w))(?:"# + pattern + #")(?:(?!\w)|(?<!\w))"#
        guard (try? NSRegularExpression(pattern: wrapped)) != nil, ReplacementSafety.isSafe(wrapped) else { return nil }
        return wrapped
    }

    public static func pressesReturn(replace: String, regex: Bool) -> Bool {
        regex && ReturnSuffix.parse(ReplacementEscapes.expandTemplate(replace))?.submit != nil
    }

    // The one sentence a rule needs when its behaviour is not the ordinary word fix. A Return-pressing rule that
    // can act mid-sentence gets the return-scope advisory instead, with its repair.
    public static func behaviorSummary(replace: String, regex: Bool, wholeDictation: Bool) -> String? {
        guard wholeDictation else { return nil }
        return pressesReturn(replace: replace, regex: regex)
            ? "Matches only when said alone. Presses Return." : "Matches only when said alone."
    }

    // A rule that presses Return only does so when it is everything said; anywhere else its Return is dropped.
    public static func returnScopeAdvisory(replace: String, regex: Bool, wholeDictation: Bool) -> String? {
        guard !wholeDictation, pressesReturn(replace: replace, regex: regex) else { return nil }
        return "This rule also replaces words within sentences, where Return is skipped."
    }

    public struct Preview: Equatable, Sendable {
        public let text: String
        public let isTruncated: Bool
        public let fullCount: Int
    }

    public static func preview(for replacement: String) -> Preview {
        let fullCount = replacement.count
        guard fullCount > 0 else { return Preview(text: "Nothing", isTruncated: false, fullCount: 0) }
        let escaped = escapedPrefix(
            replacement, spacesVisible: replacement.allSatisfy(\.isWhitespace))
        guard escaped.count > previewLimit else {
            return Preview(text: escaped, isTruncated: false, fullCount: fullCount)
        }
        let truncated = String(escaped.prefix(previewLimit - 1)) + "…"
        return Preview(text: truncated, isTruncated: true, fullCount: fullCount)
    }

    private static func escapedPrefix(_ text: String, spacesVisible: Bool) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\r\n": out += #"\r\n"#
            case "\n": out += #"\n"#
            case "\r": out += #"\r"#
            case "\t": out += #"\t"#
            case " " where spacesVisible: out += "␣"
            default: out.append(character)
            }
            if out.count > previewLimit { break }
        }
        return out
    }
}
