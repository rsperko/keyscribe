import Foundation

// "insert clipboard contents" is a live edit (design.md §4.2) whose value is external: the phrase is
// replaced by a single nonce token (its own `.clipboard`/CLIP type, so it can't collide with a `.verbatim`
// token) wrapping the clipboard string — opaque to the text stages and the LLM, never sent to the cloud,
// restored after the LLM. Tokenized alongside verbatim but sorted AFTER it, so a clipboard phrase inside a
// verbatim span stays literal. Empty/absent clipboard leaves the phrase as text, not deleted. "insert clipboard
// as code" wraps the same value in a Markdown fence on lines of its own.
public enum ClipboardTokenizer {
    public static let defaultPhrases = [
        "insert clipboard contents", "insert the clipboard contents",
        "insert clipboard content", "insert the clipboard content",
    ]

    public static let codePhrases = (["insert clipboard", "insert the clipboard"] + defaultPhrases)
        .flatMap { phrase in [" as code", " as a code block"].map { phrase + $0 } }

    // Cheap presence check that gates the clipboard read: `apply` calls the provider ONLY when the
    // command was spoken in the (already verbatim-tokenized) text, so an ordinary dictation — or a
    // clipboard phrase wrapped in a verbatim span — never touches the user's clipboard.
    public static func mentions(_ text: String) -> Bool {
        guard let re = commandRegex(codePhrases + defaultPhrases) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public struct Clip: Equatable, Sendable {
        public var text: String
        public var isFiles: Bool

        public init(text: String, isFiles: Bool = false) {
            self.text = text
            self.isFiles = isFiles
        }

        public static func files(_ paths: [String]) -> Clip {
            let named = paths.map { path in
                guard path.contains(where: \.isWhitespace) else { return path }
                let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            return Clip(text: named.joined(separator: " "), isFiles: true)
        }
    }

    public static func apply(_ text: String, clipboard: () -> String?, into tokenizer: Tokenizer) -> String {
        apply(text, clip: { clipboard().map { Clip(text: $0) } }, into: tokenizer)
    }

    public static func apply(_ text: String, clip read: () -> Clip?, into tokenizer: Tokenizer) -> String {
        guard mentions(text), let clip = read(), !clip.text.isEmpty else { return text }
        // The code phrases first: each plain phrase is a prefix of a code one.
        let code = clip.isFiles ? clip.text : fence(clip.text)
        let fenced = splice(text, codePhrases, value: code, block: !clip.isFiles, into: tokenizer)
        return splice(fenced, defaultPhrases, value: clip.text, block: false, into: tokenizer)
    }

    // A fence longer than any run of backticks in the clipboard, so a fence inside it cannot close the block.
    public static func fence(_ clip: String) -> String {
        var longest = 0
        var run = 0
        for character in clip {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let marks = String(repeating: "`", count: max(3, longest + 1))
        var body = clip
        while body.last?.isNewline == true { body.removeLast() }
        return "\(marks)\n\(body)\n\(marks)"
    }

    private static func splice(
        _ text: String, _ phrases: [String], value: String, block: Bool, into tokenizer: Tokenizer
    ) -> String {
        guard let re = commandRegex(phrases) else { return text }
        let spans = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            m -> (range: Range<String.Index>, value: String)? in
            guard let r = Range(m.range, in: text) else { return nil }
            return (r, value)
        }
        // spliceAbsorbing cleans the pause commas STT hangs around the command. dedup: false — two
        // "insert clipboard contents" wrap the SAME value, so a deduped token would appear twice and trip
        // the exactly-once gate; distinct tokens per site keep a faithful rewrite valid.
        return tokenizer.spliceAbsorbing(text, spans: spans, type: .clipboard, dedup: false, block: block)
    }

    private static func commandRegex(_ phrases: [String]) -> NSRegularExpression? {
        CommandPhrase.alternationRegex(phrases)
    }
}
