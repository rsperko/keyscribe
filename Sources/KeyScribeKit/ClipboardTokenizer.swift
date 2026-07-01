import Foundation

// "insert clipboard contents" is a live edit (design.md §4.2) whose span value is external: the
// spoken phrase is replaced by a single nonce token (its own `.clipboard`/CLIP type, so it can never
// collide with a `.verbatim` token when both appear in one dictation) wrapping the host-captured
// clipboard string, so the pasted content is opaque to the text stages (replacements/numbers/fuzzy)
// and to the LLM — protected from everything except being inserted, and never sent to the cloud —
// then restored after the LLM. Runs as a tokenization step alongside verbatim (before the text
// stages), sorted AFTER verbatim so a clipboard phrase inside a verbatim span stays literal. Empty
// or absent clipboard leaves the phrase as text rather than silently deleting it.
public enum ClipboardTokenizer {
    public static let defaultPhrases = ["insert clipboard contents", "insert the clipboard contents"]

    // Cheap presence check the host uses to read the clipboard ONLY when the command was spoken, so an
    // ordinary dictation never touches the user's clipboard.
    public static func mentions(_ text: String, phrases: [String] = defaultPhrases) -> Bool {
        guard let re = commandRegex(phrases) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func apply(
        _ text: String, clipboard: String?, phrases: [String] = defaultPhrases, into tokenizer: Tokenizer
    ) -> String {
        guard let clipboard, !clipboard.isEmpty, let re = commandRegex(phrases) else { return text }
        let spans = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            m -> (range: Range<String.Index>, value: String)? in
            guard let r = Range(m.range, in: text) else { return nil }
            return (r, clipboard)
        }
        // spliceAbsorbing cleans the pause commas the STT hangs around the command; dedup: false —
        // two "insert clipboard contents" both wrap the SAME clipboard value, so a deduped token would
        // appear twice and trip the exactly-once gate (forcing a needless local fallback). Distinct
        // tokens per site keep a faithful rewrite valid.
        return tokenizer.spliceAbsorbing(text, spans: spans, type: .clipboard, dedup: false)
    }

    private static func commandRegex(_ phrases: [String]) -> NSRegularExpression? {
        let alternation = phrases.filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0.lowercased()) }
            .joined(separator: "|")
        guard !alternation.isEmpty else { return nil }
        return RegexCache.regex("(?i)\\b(?:\(alternation))\\b", options: [])
    }
}
