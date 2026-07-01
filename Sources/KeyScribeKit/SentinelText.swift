import Foundation

// Token opacity for the text pipeline (design.md §4.2). Nonce sentinels (⟦SN:VERB:1⟧, ⟦SN:CLIP:1⟧)
// are minted at the verbatim/clipboard mark (position 20) and MUST survive the post-STT text stages
// (position 30: replacements, numbers, fuzzy) byte-for-byte — a text stage that rewrote a token body
// would corrupt a verbatim insert on the no-LLM path (no gate) and desync the validation gate on the
// LLM path. The token body is plain ASCII, so a user rule like `\d+` or a literal `VERB` matches
// inside it; rather than police the token alphabet, free-substituting stages transform only the plain
// runs BETWEEN sentinels through this utility, leaving every token intact.
public enum SentinelText {
    static let open = "⟦SN:"
    static let close = "⟧"

    // Apply `transform` to each substring between ⟦SN:…⟧ tokens, leaving the tokens verbatim, and
    // rejoin. A malformed open with no matching close is treated as plain text (transformed) — the
    // tokenizer only ever emits well-formed pairs, so this only affects user-typed lookalikes.
    public static func mappingOutsideSentinels(_ text: String, _ transform: (String) -> String) -> String {
        guard text.contains(open) else { return transform(text) }
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = text.startIndex
        while let o = text.range(of: open, range: cursor..<text.endIndex),
              let c = text.range(of: close, range: o.upperBound..<text.endIndex) {
            out += transform(String(text[cursor..<o.lowerBound]))
            out += text[o.lowerBound..<c.upperBound]
            cursor = c.upperBound
        }
        out += transform(String(text[cursor..<text.endIndex]))
        return out
    }

    public static func containsSentinel(_ text: String) -> Bool {
        text.contains(open)
    }
}
