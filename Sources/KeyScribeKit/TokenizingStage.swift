import Foundation

// A pipeline command that tokenizes spans on `apply` and restores them on `post` (LIFO). Verbatim
// and redaction are the same machinery — a position, a shared per-dictation Tokenizer, and a span
// scanner — differing only in WHERE they sort and HOW they find spans. One struct + two factories
// captures that; a third protector (design.md §4.2) becomes one more factory, not another copy.
public struct TokenizingStage: PipelineStage {
    public let position: StagePosition
    public let order: Int
    private let tokenizer: Tokenizer
    private let scan: @Sendable (String, Tokenizer) -> String

    public init(
        position: StagePosition, order: Int = 0, tokenizer: Tokenizer,
        scan: @escaping @Sendable (String, Tokenizer) -> String
    ) {
        self.position = position
        self.order = order
        self.tokenizer = tokenizer
        self.scan = scan
    }

    public func apply(_ context: inout PipelineContext) { context.text = scan(context.text, tokenizer) }
    public func post(_ context: inout PipelineContext) { context.text = tokenizer.restore(context.text) }
    public var issuedTokens: [String] { tokenizer.issuedTokens }

    // Verbatim sorts BEFORE the post-STT text stages so its span is opaque to them (protected from
    // everything except STT); redaction sorts AFTER them so it tokenizes the fully-transformed text
    // just before the LLM (design.md §4.2.1).
    public static func verbatim(tokenizer: Tokenizer = Tokenizer()) -> TokenizingStage {
        TokenizingStage(position: .verbatimMark, tokenizer: tokenizer) { VerbatimTokenizer.apply($0, into: $1) }
    }

    public static func redaction(tokenizer: Tokenizer = Tokenizer()) -> TokenizingStage {
        TokenizingStage(position: .postSTTMark, tokenizer: tokenizer) { RedactionTokenizer.apply($0, into: $1) }
    }
}

extension Tokenizer {
    // Rebuild `text` with each span replaced by its nonce token, in one left-to-right pass. The spans
    // must be ordered by start and non-overlapping (the scanners guarantee this). Shared by the
    // verbatim and redaction scanners so the cursor/splice accumulation lives in exactly one place.
    func splice(_ text: String, spans: [(range: Range<String.Index>, value: String)], type: TokenType) -> String {
        guard !spans.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for span in spans {
            result += text[cursor..<span.range.lowerBound]
            result += tokenize(span.value, type: type)
            cursor = span.range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
