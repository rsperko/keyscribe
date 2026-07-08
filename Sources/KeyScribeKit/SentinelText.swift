import Foundation

// Token opacity for the text pipeline (design.md §4.2). Nonce sentinels (⟦SN:VERB:1⟧, ⟦SN:CLIP:1⟧) minted
// at the verbatim/clipboard mark MUST survive the post-STT text stages (replacements, numbers, fuzzy)
// byte-for-byte — a rewritten token body corrupts a verbatim insert on the no-LLM path and desyncs the
// validation gate on the LLM path. The body is plain ASCII (a user rule like `\d+` matches inside it), so
// free-substituting stages transform only the plain runs BETWEEN sentinels, leaving tokens intact.
public enum SentinelText {
    static let open = "⟦SN:"
    private static let typeNames = ["REDACT", "VERB", "CLIP"]

    public static func mappingOutsideSentinels(_ text: String, _ transform: (String) -> String) -> String {
        guard text.contains(open) else { return transform(text) }
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = text.startIndex
        while let token = firstToken(in: text, from: cursor) {
            out += transform(String(text[cursor..<token.lowerBound]))
            out += text[token]
            cursor = token.upperBound
        }
        out += transform(String(text[cursor..<text.endIndex]))
        return out
    }

    public static func containsSentinel(_ text: String) -> Bool {
        text.contains(open)
    }

    public static func neutralizeOpen(_ s: String) -> String {
        guard s.contains(open) else { return s }
        return s.replacingOccurrences(of: open, with: "⟦\u{200B}SN:")
    }

    static func firstToken(in text: String, from: String.Index) -> Range<String.Index>? {
        var cursor = from
        while let o = text.range(of: open, range: cursor..<text.endIndex) {
            if let end = tokenEnd(in: text, openUpper: o.upperBound) {
                return o.lowerBound..<end
            }
            cursor = text.index(after: o.lowerBound)
        }
        return nil
    }

    private static func tokenEnd(in text: String, openUpper: String.Index) -> String.Index? {
        let end = text.endIndex
        guard let afterType = matchType(in: text, at: openUpper), afterType < end, text[afterType] == ":" else {
            return nil
        }
        var i = text.index(after: afterType)
        let digitStart = i
        while i < end, ("0"..."9").contains(text[i]) { i = text.index(after: i) }
        guard i > digitStart, i < end, text[i] == "⟧" else { return nil }
        return text.index(after: i)
    }

    private static func matchType(in text: String, at i: String.Index) -> String.Index? {
        let rest = text[i...]
        for name in typeNames where rest.hasPrefix(name) {
            return text.index(i, offsetBy: name.count)
        }
        return nil
    }
}
