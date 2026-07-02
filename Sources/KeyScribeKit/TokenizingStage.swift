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

    // Internal, factories-only: the position that decides where a protector sorts (verbatim BEFORE the
    // text stages, redaction AFTER — the load-bearing ordering invariant, design.md §4.2.1) must not be
    // caller-supplied. Construct via `.verbatim` / `.redaction` / `.clipboard`.
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

    // Verbatim sorts BEFORE the post-STT text stages so its span is opaque to them (protected from
    // everything except STT); redaction sorts AFTER them so it tokenizes the fully-transformed text
    // just before the LLM (design.md §4.2.1).
    public static func verbatim(tokenizer: Tokenizer = Tokenizer()) -> TokenizingStage {
        TokenizingStage(position: .verbatimMark, tokenizer: tokenizer) { VerbatimTokenizer.apply($0, into: $1) }
    }

    public static func redaction(tokenizer: Tokenizer = Tokenizer()) -> TokenizingStage {
        TokenizingStage(position: .postSTTMark, tokenizer: tokenizer) { RedactionTokenizer.apply($0, into: $1) }
    }

    // "insert clipboard contents" — the third protector the machinery above anticipated. Sorts with
    // verbatim (before the text stages) but at a later order, so a verbatim span swallows a clipboard
    // phrase before it can fire. The clipboard string is captured per-dictation by the host.
    public static func clipboard(_ clipboard: String?, tokenizer: Tokenizer = Tokenizer()) -> TokenizingStage {
        TokenizingStage(position: .verbatimMark, order: 1, tokenizer: tokenizer) {
            ClipboardTokenizer.apply($0, clipboard: clipboard, into: $1)
        }
    }
}

extension Tokenizer {
    // Rebuild `text` with each span replaced by its nonce token, in one left-to-right pass. The spans
    // must be ordered by start and non-overlapping (the scanners guarantee this). Shared by the
    // verbatim and redaction scanners so the cursor/splice accumulation lives in exactly one place.
    // `dedup: false` mints a distinct token per site even for equal values (clipboard), so N identical
    // paste sites stay N distinct tokens and each survives the exactly-once gate.
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

    // Like `splice`, but each COMMAND span also absorbs the whitespace/comma run that directly hugs it
    // on either side, then re-normalizes to exactly one space on any side that still borders content. A
    // spoken command is an invisible operator; the punctuation the STT attaches when the speaker pauses
    // around it ("the begin verbatim, new line, end verbatim, change" → the commas) is an artifact, not
    // content. Only spaces, tabs, and commas are absorbed — never sentence terminators (. ! ?),
    // semicolons, or colons, which are usually intended. `hadLeftSeparator`/`hadRightSeparator` capture
    // whether the ORIGINAL boundary was a separator, so attached punctuation like "(cmd)" or "cmd."
    // stays attached (no spurious space) while "a cmd b" and "a, cmd, b" both collapse to "a <tok> b".
    // Spans must be ordered by start and non-overlapping. Used only by command stages (verbatim,
    // clipboard); redaction keeps plain `splice` so it never disturbs punctuation around a sensitive
    // span. `dedup: false` (clipboard) mints a distinct token per site — see `splice`.
    //
    // Bracketed-terminator FOLD: an aggressively-punctuating STT (Whisper Small) inserts a sentence
    // terminator (. ! ?) right before an inline paste even without a pause, so "the directory. <paste>.
    // Decide" leaves a spurious period before the pasted value. When the content is bracketed by a
    // terminator on BOTH sides, the leading one is treated as a pause artifact: it is dropped (the
    // content folds into the preceding clause) and RELOCATED to the trailing boundary, keeping its type
    // (a "?" stays a "?"). Requiring a terminator on both sides leaves a paste that genuinely starts the
    // next sentence ("It's broken. <paste> fixes it" — no trailing terminator) untouched.
    func spliceAbsorbing(
        _ text: String, spans: [(range: Range<String.Index>, value: String)], type: TokenType, dedup: Bool = true
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
            if let leading = leadingTerminator, bracketed {
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
            if hadRightSeparator, end < text.endIndex, text[end] != "\n" {
                result += " "
            }
            cursor = end
        }
        result += text[cursor...]
        return result
    }
}
