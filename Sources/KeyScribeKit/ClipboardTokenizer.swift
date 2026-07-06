import Foundation

// "insert clipboard contents" is a live edit (design.md §4.2) whose value is external: the phrase is
// replaced by a single nonce token (its own `.clipboard`/CLIP type, so it can't collide with a `.verbatim`
// token) wrapping the clipboard string — opaque to the text stages and the LLM, never sent to the cloud,
// restored after the LLM. Tokenized alongside verbatim but sorted AFTER it, so a clipboard phrase inside a
// verbatim span stays literal. Empty/absent clipboard leaves the phrase as text, not deleted.
public enum ClipboardTokenizer {
    public static let defaultPhrases = [
        "insert clipboard contents", "insert the clipboard contents",
        "insert clipboard content", "insert the clipboard content",
    ]

    // Cheap presence check that gates the clipboard read: `apply` calls the provider ONLY when the
    // command was spoken in the (already verbatim-tokenized) text, so an ordinary dictation — or a
    // clipboard phrase wrapped in a verbatim span — never touches the user's clipboard.
    public static func mentions(_ text: String, phrases: [String] = defaultPhrases) -> Bool {
        guard let re = commandRegex(phrases) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func apply(
        _ text: String, clipboard: () -> String?, phrases: [String] = defaultPhrases, into tokenizer: Tokenizer
    ) -> String {
        guard let re = commandRegex(phrases),
              re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
              let clip = clipboard(), !clip.isEmpty else { return text }
        let spans = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            m -> (range: Range<String.Index>, value: String)? in
            guard let r = Range(m.range, in: text) else { return nil }
            return (r, clip)
        }
        // spliceAbsorbing cleans the pause commas STT hangs around the command. dedup: false — two
        // "insert clipboard contents" wrap the SAME value, so a deduped token would appear twice and trip
        // the exactly-once gate; distinct tokens per site keep a faithful rewrite valid.
        return tokenizer.spliceAbsorbing(text, spans: spans, type: .clipboard, dedup: false)
    }

    private static func commandRegex(_ phrases: [String]) -> NSRegularExpression? {
        CommandPhrase.alternationRegex(phrases)
    }
}
