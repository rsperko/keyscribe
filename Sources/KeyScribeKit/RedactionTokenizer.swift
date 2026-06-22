import Foundation

// Best-effort redaction (design.md §4.2). Pattern-matches likely-sensitive spans and tokenizes
// them BEFORE the (possibly cloud) LLM, restoring after. Gated by the mode's privacy toggle at the
// call site, which also forces context off (§4.4) so the redacted transcript is the only user
// content that can leave. This is **best-effort** — pattern matching misses obfuscated or novel
// secrets — and the UX must never imply a guarantee.
public enum RedactionTokenizer {
    // Order is informational only; overlaps resolve by earliest-then-longest below.
    static let patterns: [String] = [
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,            // email
        #"\bsk-[A-Za-z0-9]{16,}\b"#,                                    // OpenAI-style key
        #"\bAKIA[0-9A-Z]{16}\b"#,                                       // AWS access key id
        #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,                            // GitHub token
        #"\b\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}\b"#,                   // 16-digit card
        #"\b\d{3}-\d{2}-\d{4}\b"#,                                      // US SSN
        #"\b(?:\+?1[ -]?)?\(?\d{3}\)?[ -]?\d{3}[ -]?\d{4}\b"#,         // US phone
    ]

    private struct Span { let range: Range<String.Index>; let value: String }

    public static func apply(_ text: String, into tokenizer: Tokenizer) -> String {
        var spans: [Span] = []
        for pattern in patterns {
            guard let re = RegexCache.regex(pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range, in: text) {
                    spans.append(Span(range: r, value: String(text[r])))
                }
            }
        }
        guard !spans.isEmpty else { return text }

        // Earliest start first; on a tie, longest match wins. Then keep non-overlapping greedily.
        spans.sort {
            $0.range.lowerBound != $1.range.lowerBound
                ? $0.range.lowerBound < $1.range.lowerBound
                : text.distance(from: $0.range.lowerBound, to: $0.range.upperBound)
                    > text.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
        }
        var kept: [Span] = []
        var lastUpper: String.Index?
        for span in spans {
            if let lu = lastUpper, span.range.lowerBound < lu { continue }
            kept.append(span)
            lastUpper = span.range.upperBound
        }

        var result = ""
        var cursor = text.startIndex
        for span in kept {
            result += text[cursor..<span.range.lowerBound]
            result += tokenizer.tokenize(span.value, type: .redact)
            cursor = span.range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
