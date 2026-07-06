import Foundation

// A pipeline command that tokenizes spans on `apply` and restores them on `post` (LIFO). Verbatim and
// redaction are the same machinery, differing only in WHERE they sort and HOW they find spans; a third
// protector (design.md §4.2) is one more factory, not another copy.
public struct TokenizingStage: PipelineStage {
    public let position: StagePosition
    public let order: Int
    private let tokenizer: Tokenizer
    private let scan: @Sendable (String, Tokenizer) -> String

    // Factories-only: `position` (verbatim BEFORE the text stages, redaction AFTER — the load-bearing
    // ordering invariant, design.md §4.2.1) must not be caller-supplied. Use `.verbatim`/`.redaction`/`.clipboard`.
    init(
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

    // Verbatim sorts BEFORE the post-STT text stages so its span is opaque to them (protected from all but
    // STT); redaction sorts AFTER so it tokenizes the fully-transformed text just before the LLM (§4.2.1).
    public static func verbatim(tokenizer: Tokenizer = Tokenizer()) -> TokenizingStage {
        TokenizingStage(position: .verbatimMark, tokenizer: tokenizer) { VerbatimTokenizer.apply($0, into: $1) }
    }

    public static func redaction(tokenizer: Tokenizer = Tokenizer()) -> TokenizingStage {
        TokenizingStage(position: .postSTTMark, tokenizer: tokenizer) { RedactionTokenizer.apply($0, into: $1) }
    }

    // "insert clipboard contents". Sorts with verbatim (before the text stages) but at a later order, so a
    // verbatim span swallows a clipboard phrase before it can fire. `read` is lazy — invoked only when the
    // command survives to this stage, so an ordinary dictation never reads the host's clipboard.
    public static func clipboard(read: @escaping @Sendable () -> String?, tokenizer: Tokenizer = Tokenizer()) -> TokenizingStage {
        TokenizingStage(position: .verbatimMark, order: 1, tokenizer: tokenizer) {
            ClipboardTokenizer.apply($0, clipboard: read, into: $1)
        }
    }
}

extension Tokenizer {
    // Rebuild `text` with each span replaced by its nonce token, in one left-to-right pass. Spans must be
    // ordered by start and non-overlapping (scanners guarantee this). `dedup: false` mints a distinct token
    // per site even for equal values (clipboard), so N identical paste sites each survive the exactly-once gate.
    func splice(
        _ text: String, spans: [(range: Range<String.Index>, value: String)], type: TokenType, dedup: Bool = true
    ) -> String {
        guard !spans.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for span in spans {
            result += text[cursor..<span.range.lowerBound]
            result += dedup ? tokenize(span.value, type: type) : tokenizeUnique(span.value, type: type)
            cursor = span.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    // Like `splice`, but each COMMAND span absorbs the whitespace/comma run hugging it on either side, then
    // re-normalizes to one space where it still borders content — a spoken command is an invisible operator,
    // and the punctuation STT attaches around a pause ("...verbatim, new line, end...") is an artifact. Only
    // spaces/tabs/commas are absorbed, never sentence terminators (. ! ?), semicolons, or colons.
    // `hadLeftSeparator`/`hadRightSeparator` record whether the ORIGINAL boundary was a separator, so "(cmd)"
    // / "cmd." stay attached while "a cmd b" and "a, cmd, b" both collapse to "a <tok> b". Spans ordered by
    // start, non-overlapping. Command stages only (verbatim, clipboard); redaction keeps plain `splice`.
    //
    // Bracketed-terminator FOLD: an aggressively-punctuating STT (Whisper Small) can put a terminator right
    // before an inline paste ("the directory. <paste>. Decide"). When the content is bracketed by a
    // terminator on BOTH sides, the leading one is a pause artifact: dropped and RELOCATED to the trailing
    // boundary (keeping its type). Requiring both sides leaves a paste that genuinely starts the next
    // sentence ("It's broken. <paste> fixes it") untouched.
    func spliceAbsorbing(
        _ text: String, spans: [(range: Range<String.Index>, value: String)], type: TokenType, dedup: Bool = true,
        foldBracketedTerminators: Bool = true, collapseTrailingTerminator: Bool = false
    ) -> String {
        guard !spans.isEmpty else { return text }
        let absorb: Set<Character> = [" ", "\t", ","]
        let terminators: Set<Character> = [".", "!", "?"]
        var result = ""
        var cursor = text.startIndex
        func token(_ value: String) -> String {
            dedup ? tokenize(value, type: type) : tokenizeUnique(value, type: type)
        }
        for span in spans {
            let hadLeftSeparator = span.range.lowerBound > text.startIndex
                && absorb.contains(text[text.index(before: span.range.lowerBound)])
            let hadRightSeparator = span.range.upperBound < text.endIndex
                && absorb.contains(text[span.range.upperBound])
            var start = span.range.lowerBound
            while start > cursor {
                let prev = text.index(before: start)
                if absorb.contains(text[prev]) { start = prev } else { break }
            }
            var end = span.range.upperBound
            while end < text.endIndex, absorb.contains(text[end]) { end = text.index(after: end) }
            result += text[cursor..<start]

            let leadingTerminator = result.last.flatMap { terminators.contains($0) ? $0 : nil }
            let bracketed = end < text.endIndex && terminators.contains(text[end])
            if foldBracketedTerminators, let leading = leadingTerminator, bracketed {
                result.removeLast()   // drop the artifact leading terminator
                if let last = result.last, last != " ", last != "\n", last != "\t" { result += " " }
                result += token(span.value)
                result.append(leading)   // relocate it to the true clause end (replacing the trailing one)
                cursor = text.index(after: end)
                continue
            }

            if hadLeftSeparator, let last = result.last, last != " ", last != "\n", last != "\t" {
                result += " "
            }
            result += token(span.value)
            // Safe trailing-collapse: if the content already ends in a terminator AND STT left a redundant
            // one right after the end marker, drop the post-marker one (the content's own stands). Never
            // strips the content's terminator, so an intended "Hello!" survives.
            if collapseTrailingTerminator, let contentLast = span.value.last, terminators.contains(contentLast),
               end < text.endIndex, terminators.contains(text[end]) {
                cursor = text.index(after: end)
            } else {
                if hadRightSeparator, end < text.endIndex, text[end] != "\n" {
                    result += " "
                }
                cursor = end
            }
        }
        result += text[cursor...]
        return result
    }
}
