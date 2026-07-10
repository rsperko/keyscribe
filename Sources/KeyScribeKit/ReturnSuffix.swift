import Foundation

// Recognizes an inline `<CR>` suffix on an already-`expandTemplate`-expanded regex replacement template:
// a terminal, unescaped `<CR>` requests a physical Return keystroke after the whole-utterance insert
// (see agent_notes/replace_with_return). The marker is stripped from the template here, so `<CR>` never
// reaches NSRegularExpression, the pasteboard, the target, or an LLM as text.
//
// `\<CR>` escapes the marker to the literal text `<CR>`. Escape parity is judged against the expanded
// template, where ReplacementEscapes emits a literal backslash as a *pair* (`\\`): a `<CR>` preceded by
// an odd run of backslashes is escaped (the last one is the escape), an even run is a real marker. Only
// a terminal marker is valid; an unescaped `<CR>` anywhere else is invalid configuration and the caller
// drops the rule.
public enum ReturnSuffix {
    public struct Parsed: Equatable, Sendable {
        public let template: String
        public let submit: Mode.Submit?
    }

    private static let marker: [Character] = ["<", "C", "R", ">"]

    // Returns nil ⇒ invalid rule (unescaped non-terminal `<CR>`); the caller drops it.
    public static func parse(_ expandedTemplate: String) -> Parsed? {
        var chars = Array(expandedTemplate)
        let mlen = marker.count

        func isMarkerStart(_ arr: [Character], _ i: Int) -> Bool {
            i + mlen <= arr.count && Array(arr[i..<i + mlen]) == marker
        }
        func backslashRunEven(_ arr: [Character], before i: Int) -> Bool {
            var j = i - 1, run = 0
            while j >= 0, arr[j] == "\\" { run += 1; j -= 1 }
            return run % 2 == 0
        }

        var submit: Mode.Submit? = nil
        var terminalIdx: Int? = nil
        let endStart = chars.count - mlen
        if endStart >= 0, isMarkerStart(chars, endStart), backslashRunEven(chars, before: endStart) {
            submit = .return
            terminalIdx = endStart
        }

        // Any unescaped `<CR>` that is not the terminal marker is invalid — a key action belongs only at
        // the end of an expansion.
        for i in chars.indices where isMarkerStart(chars, i) {
            if backslashRunEven(chars, before: i), i != terminalIdx { return nil }
        }

        if let t = terminalIdx {
            chars.removeSubrange(t..<t + mlen)
            // Whitespace immediately before the suffix goes with it (`/resume <CR>` → `/resume`).
            while let last = chars.last, last.isWhitespace { chars.removeLast() }
        }

        // Every `<CR>` still present is escaped (unescaped non-terminal returned nil; the terminal one was
        // removed). Drop the single escaping backslash so it renders as literal `<CR>`. Collect first, then
        // remove in descending index order so earlier removals never shift a pending one.
        var escapeBackslashes: [Int] = []
        for i in chars.indices where isMarkerStart(chars, i) {
            if i - 1 >= 0, chars[i - 1] == "\\" { escapeBackslashes.append(i - 1) }
        }
        for p in escapeBackslashes.sorted(by: >) { chars.remove(at: p) }

        return Parsed(template: String(chars), submit: submit)
    }
}
