import Foundation

// Deterministic, opt-in cleanups applied to the final string just before insertion — enforcement the
// LLM prompt cannot guarantee (only nonce tokens reliably survive a rewrite). Each is a per-mode toggle
// applied after token restore and before the trailing suffix is appended.
public enum OutputCleanup {
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
}
