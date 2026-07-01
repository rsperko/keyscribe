import Foundation

// Verbatim is a live edit (design.md §4.2): a span delimited by the spoken triggers
// "begin verbatim" … "end verbatim" is pulled into a single nonce token so the LLM cannot touch it,
// then restored verbatim. Gated by the mode's live-edits opt-in at the call site. Runs as the first
// tokenization step (before redaction), so it is the last text mutation before the LLM.
public enum VerbatimTokenizer {
    private static let beginTrigger = #"\bbegin verbatim\b"#
    private static let endTrigger = #"\bend verbatim\b"#

    public static func apply(_ text: String, into tokenizer: Tokenizer) -> String {
        guard text.range(of: "verbatim", options: .caseInsensitive) != nil else { return text }
        let afterPairs = replacePairs(text, tokenizer)
        return replaceUnterminated(afterPairs, tokenizer)
    }

    // The `[\s,]*` around the content group trims pause whitespace/commas hugging the markers (so
    // "begin verbatim, new line, end verbatim" protects "new line", not ", new line,") while leaving
    // the content's own edge terminators/semicolons/colons intact — a verbatim span may legitimately
    // be "Hello!" or "foo();". spliceAbsorbing then cleans the commas hugging the OUTSIDE of the markers.
    private static let contentEdge = "[\\s,]*"

    private static func replacePairs(_ text: String, _ tokenizer: Tokenizer) -> String {
        let pattern = "(?i)\(beginTrigger)\(contentEdge)(.*?)\(contentEdge)\(endTrigger)"
        guard let re = RegexCache.regex(pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let spans = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            m -> (range: Range<String.Index>, value: String)? in
            guard let full = Range(m.range, in: text), let content = Range(m.range(at: 1), in: text) else { return nil }
            return (full, String(text[content]))
        }
        return tokenizer.spliceAbsorbing(text, spans: spans, type: .verbatim)
    }

    private static func replaceUnterminated(_ text: String, _ tokenizer: Tokenizer) -> String {
        guard let re = RegexCache.regex("(?i)\(beginTrigger)", options: []),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return text }
        let edgeTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        let content = text[r.upperBound...].trimmingCharacters(in: edgeTrim)
        guard !content.isEmpty else { return text }
        let token = tokenizer.tokenize(content, type: .verbatim)
        let prefix = String(text[..<r.lowerBound]).trimmingCharacters(in: edgeTrim)
        return prefix.isEmpty ? token : "\(prefix) \(token)"
    }
}
