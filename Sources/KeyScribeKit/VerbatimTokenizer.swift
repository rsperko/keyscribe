import Foundation

// Verbatim is a live edit (design.md §4.2): a span delimited by the spoken triggers
// "begin verbatim" … "end verbatim" is pulled into a single nonce token so the LLM cannot touch it,
// then restored verbatim. Gated by the mode's live-edits opt-in at the call site. Runs as the first
// tokenization step (before redaction), so it is the last text mutation before the LLM.
public enum VerbatimTokenizer {
    // The spoken markers tolerate a pause-comma between their words ("begin, verbatim") via the shared
    // CommandPhrase joiner — the same `[,;:]?\s+` builder the clipboard command uses.
    private static let beginTrigger = CommandPhrase.boundedTrigger("begin verbatim")
    private static let endTrigger = CommandPhrase.boundedTrigger("end verbatim")

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
    // A sentence terminator FLUSH against a marker word ("begin verbatim." with no space) is a pause
    // artifact of the spoken command, not content — the speaker paused after the marker, they did not
    // dictate a leading period. Stripped only when glued to the marker, so a space-separated
    // content-leading terminal (".config") survives (leadingPeriodInContentPreserved).
    private static let markerGluedTerminator = "[.!?]*"

    private static func replacePairs(_ text: String, _ tokenizer: Tokenizer) -> String {
        let pattern = "(?i)\(beginTrigger)\(markerGluedTerminator)\(contentEdge)(.*?)\(contentEdge)\(endTrigger)"
        guard let re = RegexCache.regex(pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let spans = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            m -> (range: Range<String.Index>, value: String)? in
            guard let full = Range(m.range, in: text), let content = Range(m.range(at: 1), in: text) else { return nil }
            return (full, String(text[content]))
        }
        // dedup: false — two verbatim spans with equal content must stay distinct tokens, or a
        // faithful rewrite reproducing both occurrences trips the gate's exactly-once check
        // (mirrors ClipboardTokenizer). foldBracketedTerminators: false — a user-delimited verbatim
        // span is not an inline paste; when the speaker paused (surrounding sentence terminators) it
        // must stay its own clause, not merge into the previous one.
        return tokenizer.spliceAbsorbing(
            text, spans: spans, type: .verbatim, dedup: false,
            foldBracketedTerminators: false, collapseTrailingTerminator: true)
    }

    private static func replaceUnterminated(_ text: String, _ tokenizer: Tokenizer) -> String {
        guard let re = RegexCache.regex("(?i)\(beginTrigger)", options: []),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return text }
        let edgeTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        // Same marker-glued-terminator rule as replacePairs: "begin verbatim. rest" drops the pause
        // period; "begin verbatim .config" (space first) keeps it as content.
        var contentStart = r.upperBound
        while contentStart < text.endIndex, "!.?".contains(text[contentStart]) {
            contentStart = text.index(after: contentStart)
        }
        let content = text[contentStart...].trimmingCharacters(in: edgeTrim)
        guard !content.isEmpty else { return text }
        let token = tokenizer.tokenize(content, type: .verbatim)
        let prefix = String(text[..<r.lowerBound]).trimmingCharacters(in: edgeTrim)
        return prefix.isEmpty ? token : "\(prefix) \(token)"
    }
}
