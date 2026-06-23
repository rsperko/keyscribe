import Foundation

// Verbatim is a live edit (design.md §4.2): a span delimited by the spoken triggers
// "begin verbatim" / "end verbatim" is pulled into a single nonce token so the LLM cannot touch
// it, then restored verbatim. Gated by the mode's live-edits opt-in at the call site. Runs as the
// first tokenization step (before redaction), so it is the last text mutation before the LLM.
public enum VerbatimTokenizer {
    public static func apply(_ text: String, into tokenizer: Tokenizer) -> String {
        let afterPairs = replacePairs(text, tokenizer)
        return replaceUnterminated(afterPairs, tokenizer)
    }

    private static func replacePairs(_ text: String, _ tokenizer: Tokenizer) -> String {
        let pattern = #"(?i)\bbegin verbatim\b\s*(.*?)\s*\bend verbatim\b"#
        guard let re = RegexCache.regex(pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let spans = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            m -> (range: Range<String.Index>, value: String)? in
            guard let full = Range(m.range, in: text), let content = Range(m.range(at: 1), in: text) else { return nil }
            return (full, String(text[content]))
        }
        return tokenizer.splice(text, spans: spans, type: .verbatim)
    }

    private static func replaceUnterminated(_ text: String, _ tokenizer: Tokenizer) -> String {
        guard let r = text.range(of: "begin verbatim", options: .caseInsensitive) else { return text }
        let content = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return text }
        let token = tokenizer.tokenize(content, type: .verbatim)
        let prefix = text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? token : "\(prefix) \(token)"
    }
}
