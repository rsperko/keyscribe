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
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for m in matches {
            guard let full = Range(m.range, in: text),
                  let content = Range(m.range(at: 1), in: text) else { continue }
            result += text[cursor..<full.lowerBound]
            result += tokenizer.tokenize(String(text[content]), type: .verbatim)
            cursor = full.upperBound
        }
        result += text[cursor...]
        return result
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

// Verbatim as a pipeline command. It sorts BEFORE the post-STT text stages (design.md §4.2.1) so a
// verbatim span is an opaque token before live edits / replacements / numbers / fuzzy run — it is
// protected from everything except STT. `post` restores it (LIFO, after the LLM). The shared
// per-dictation Tokenizer is injected so the host can also collect issued tokens for the gate.
public struct VerbatimStage: PipelineStage, TokenizingStage {
    public let position = StagePosition.verbatimMark
    public let order = 0
    private let tokenizer: Tokenizer
    public init(tokenizer: Tokenizer = Tokenizer()) { self.tokenizer = tokenizer }
    public func apply(_ context: inout PipelineContext) {
        context.text = VerbatimTokenizer.apply(context.text, into: tokenizer)
    }
    public func post(_ context: inout PipelineContext) {
        context.text = tokenizer.restore(context.text)
    }
    public var issuedTokens: [String] { tokenizer.issuedTokens }
}
