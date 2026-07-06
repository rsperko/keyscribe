import Foundation

// Deterministic, opt-in cleanups applied to the final string just before insertion — enforcement the
// LLM prompt cannot guarantee (only nonce tokens reliably survive a rewrite). Each is a per-mode toggle
// applied after token restore and before the trailing suffix is appended.
public enum OutputCleanup {
    private static func isBoundaryLayout(_ c: Character) -> Bool {
        c == "\n" || c == "\r" || c == "\t"
    }

    public static func preserveBoundaryLayout(from source: String, in output: String) -> String {
        var sourcePrefixEnd = source.startIndex
        while sourcePrefixEnd < source.endIndex, isBoundaryLayout(source[sourcePrefixEnd]) {
            sourcePrefixEnd = source.index(after: sourcePrefixEnd)
        }

        var sourceSuffixStart = source.endIndex
        while sourceSuffixStart > sourcePrefixEnd {
            let previous = source.index(before: sourceSuffixStart)
            guard isBoundaryLayout(source[previous]) else { break }
            sourceSuffixStart = previous
        }

        var outputStart = output.startIndex
        while outputStart < output.endIndex, isBoundaryLayout(output[outputStart]) {
            outputStart = output.index(after: outputStart)
        }

        var outputEnd = output.endIndex
        while outputEnd > outputStart {
            let previous = output.index(before: outputEnd)
            guard isBoundaryLayout(output[previous]) else { break }
            outputEnd = previous
        }

        return String(source[..<sourcePrefixEnd])
            + String(output[outputStart..<outputEnd])
            + String(source[sourceSuffixStart...])
    }

    // Only sentence terminators, so a quote/paren/backtick/fence at the very end is left untouched
    // (`echo "hi."` ends in `"`, not the period). An ellipsis glyph counts; a run of ASCII dots is
    // handled by dropping them one at a time.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "\u{2026}"]

    // Strip trailing whitespace and any run of trailing sentence-ending punctuation, e.g. "ls -la." →
    // "ls -la", "Really?!" → "Really", "done . " → "done". Used for command/identifier/subject-line
    // modes where a terminal period or question mark is wrong.
    public static func trimTrailingPunctuation(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            let ch = text[prev]
            guard ch.isWhitespace || sentenceTerminators.contains(ch) else { break }
            end = prev
        }
        return String(text[text.startIndex..<end])
    }

    // Bracketed/parenthesized non-lexical annotation, e.g. `[BLANK_AUDIO]`, `[Music]`, `(water running)`.
    private static let nonSpeechAnnotation = try! NSRegularExpression(pattern: "\\[[^\\]]*\\]|\\([^)]*\\)")

    // Some STT engines render a no-speech clip as a whole-utterance non-lexical annotation (`[BLANK_AUDIO]`,
    // `(water running)`). Collapse an utterance that is nothing but such annotations so the no-speech guard
    // short-circuits it. Whole-utterance ONLY: a transcript that merely *contains* one ("the array[0] value")
    // is unchanged — partial stripping would corrupt legitimate text. Lexical hallucinations ("Thank you.",
    // "No") are out of scope; they need an audio-side VAD gate, not a string denylist.
    public static func blankingNonSpeechAnnotation(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = nonSpeechAnnotation.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        guard stripped != text else { return text }
        return stripped.contains(where: { $0.isLetter || $0.isNumber }) ? text : ""
    }

    // A bracketed marker anchored at the very start/end, e.g. the ` [END]` Whisper Small appends to real
    // speech. Inner content is letters/spaces/underscores only, so a token with a digit or operator
    // (`[0]`, `[i=1]`, `[HEAD~1]`) — the shapes real bracket expressions take — never matches.
    private static let leadingBoundaryAnnotation = try! NSRegularExpression(pattern: "^\\s*\\[[A-Za-z_ ]+\\]")
    private static let trailingBoundaryAnnotation = try! NSRegularExpression(pattern: "\\[[A-Za-z_ ]+\\]\\s*$")

    // Strip a standalone bracketed marker riding the leading/trailing edge of real speech ("real text [END]"
    // → "real text"). Unlike `blankingNonSpeechAnnotation`, fires when the middle is genuine speech — but only
    // for a whole boundary `[…]`, so an interior bracket ("the array[0] value") is untouched. On the raw STT
    // transcript a boundary `[…]` is an engine artifact, not dictation.
    public static func strippingBoundaryAnnotation(_ text: String) -> String {
        var result = text
        while let match = leadingBoundaryAnnotation.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result) {
            result = String(result[range.upperBound...])
        }
        while let match = trailingBoundaryAnnotation.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result) {
            result = String(result[..<range.lowerBound])
        }
        guard result != text else { return text }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
