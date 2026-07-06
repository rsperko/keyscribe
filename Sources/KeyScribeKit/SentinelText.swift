import Foundation

// Token opacity for the text pipeline (design.md §4.2). Nonce sentinels (⟦SN:VERB:1⟧, ⟦SN:CLIP:1⟧) minted
// at the verbatim/clipboard mark MUST survive the post-STT text stages (replacements, numbers, fuzzy)
// byte-for-byte — a rewritten token body corrupts a verbatim insert on the no-LLM path and desyncs the
// validation gate on the LLM path. The body is plain ASCII (a user rule like `\d+` matches inside it), so
// free-substituting stages transform only the plain runs BETWEEN sentinels, leaving tokens intact.
public enum SentinelText {
    static let open = "⟦SN:"
    static let close = "⟧"

    // Apply `transform` to each substring between ⟦SN:…⟧ tokens, leaving tokens verbatim. A malformed open
    // with no matching close is treated as plain text — the tokenizer emits only well-formed pairs, so this
    // affects only user-typed lookalikes.
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
