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

    // Bracketed/parenthesized non-lexical annotation, e.g. `[BLANK_AUDIO]`, `[Music]`, `(water running)`.
    private static let nonSpeechAnnotation = try! NSRegularExpression(pattern: "\\[[^\\]]*\\]|\\([^)]*\\)")

    // Some STT engines render a no-speech clip not as "" but as a whole-utterance non-lexical annotation:
    // WhisperKit emits `[BLANK_AUDIO]` for a silent clip and a sound-tag like `(water running)` for faint
    // noise (verified empirically — see AGENTS.md "Silence / no-speech behavior"). Left intact these get
    // pasted as if dictated. Collapse an utterance that is *nothing but* such annotations (the only
    // speech-bearing characters live inside brackets/parens) to "", so the no-speech guard
    // (`DictationMachine.outcomeForTranscript`) short-circuits it into the .noSpeech outcome.
    //
    // Deliberately whole-utterance only: a real transcript that merely *contains* an annotation
    // ("the array[0] value", "(laughs) that was funny") is returned unchanged — partial stripping would
    // corrupt legitimate text. Lexical silence hallucinations ("Thank you.", "No", "嗯。") are out of
    // scope: they are indistinguishable from a real one-word dictation and need an audio-side VAD gate,
    // not a string denylist. An utterance with no annotation at all (e.g. a bare "...") is untouched.
    public static func blankingNonSpeechAnnotation(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = nonSpeechAnnotation.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        guard stripped != text else { return text }
        return stripped.contains(where: { $0.isLetter || $0.isNumber }) ? text : ""
    }
}
