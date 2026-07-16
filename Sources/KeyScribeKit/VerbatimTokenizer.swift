import Foundation

// Verbatim is a live edit (design.md §4.2): a span delimited by the spoken triggers
// "begin verbatim" … "end verbatim" is pulled into a single nonce token so the LLM cannot touch it,
// then restored verbatim. Gated by the mode's live-edits opt-in at the call site. Runs as the first
// tokenization step (before redaction), so it is the last text mutation before the LLM.
public enum VerbatimTokenizer {
    // The spoken markers tolerate a pause-comma between their words ("begin, verbatim") via the shared
    // CommandPhrase joiner — the same `[,;:]?\s+` builder the clipboard command uses.
    private static let beginTrigger = CommandPhrase.boundedTrigger("begin verbatim")
    private static let endTrigger = CommandPhrase.boundedTrigger("end verbatim")

    public static func apply(_ text: String, into tokenizer: Tokenizer) -> String {
        let text = snapMarkerKeyword(text)
        guard text.range(of: "verbatim", options: .caseInsensitive) != nil else { return text }
        let afterPairs = replacePairs(text, tokenizer)
        let afterRescue = replaceRescue(afterPairs, tokenizer)
        return replaceUnterminated(afterRescue, tokenizer)
    }

    // "verbatim" is a rare, schwa-final word an on-device STT reliably mangles ("verbatum", "vebatim") —
    // the acoustic model can't pin the reduced final vowel and there is no lexicon to snap it to a real
    // word. A mistranscribed keyword defeats every marker match below, so a misheard token adjacent to a
    // marker word ("begin", or an endLike close) is snapped back to the literal before matching. The bound
    // is Levenshtein <= 1 with NO phonetic gate: "verbatim" has zero real English words within one edit
    // (so only non-word mishearings snap), and dropping the phonetic gate is what catches the r-drop
    // "vebatim" — its consonant skeleton differs, which a phonetic-key equality would reject. Only a
    // marker-adjacent token is touched, so a verbatim-like word dictated as content is left alone. Runs on
    // raw STT text (verbatim sorts before the text stages, design.md §4.2.1 — no control chars yet).
    private static let keyword = "verbatim"
    private static let keywordDistance = 1
    private static let beginWord = "begin"
    private static let keywordEdgePunct = CharacterSet(charactersIn: ".,!?;:'\"()[]")

    private static func snapMarkerKeyword(_ text: String) -> String {
        let beginSnapped = snapKeywordAfterMarker(in: text) { marker, _ in
            markerCore(marker) == beginWord
        }
        guard let beginRe = RegexCache.regex("(?i)\(beginTrigger)", options: []) else { return beginSnapped }
        // An earlier begin trigger makes an end-like correction plausible, but not guaranteed to be consumed.
        return snapKeywordAfterMarker(in: beginSnapped) { marker, keywordRange in
            guard let marker = markerCore(marker), endLike(marker) else { return false }
            return beginRe.firstMatch(
                in: beginSnapped, range: NSRange(location: 0, length: keywordRange.location)) != nil
        }
    }

    private static func snapKeywordAfterMarker(
        in text: String, matchesMarker: (String, NSRange) -> Bool
    ) -> String {
        guard let tokenRe = RegexCache.regex("\\S+", options: []) else { return text }
        let ns = text as NSString
        let ranges = tokenRe.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard ranges.count >= 2 else { return text }
        var edits: [(range: NSRange, replacement: String)] = []
        for i in 1..<ranges.count {
            let raw = ns.substring(with: ranges[i])
            guard keywordLike(core(of: raw)) else { continue }
            let marker = ns.substring(with: ranges[i - 1]).lowercased()
            guard matchesMarker(marker, ranges[i]) else { continue }
            edits.append((ranges[i], swapCore(raw, into: keyword)))
        }
        guard !edits.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for edit in edits.reversed() { mutable.replaceCharacters(in: edit.range, with: edit.replacement) }
        return mutable as String
    }

    private static func markerCore(_ marker: String) -> String? {
        var marker = String(marker.drop(while: isKeywordEdgePunctuation))
        guard !marker.isEmpty else { return nil }
        if let trailing = marker.last, ",;:".contains(trailing) { marker.removeLast() }
        return marker.isEmpty ? nil : marker
    }

    private static func isKeywordEdgePunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(keywordEdgePunct.contains)
    }

    private static func keywordLike(_ token: String) -> Bool {
        let w = token.lowercased()
        guard w != keyword, abs(w.count - keyword.count) <= keywordDistance else { return false }
        return FuzzyCorrector.levenshtein(w, keyword) <= keywordDistance
    }

    private static func core(of token: String) -> String {
        token.trimmingCharacters(in: keywordEdgePunct)
    }

    // Preserve the token's outer punctuation (a pause comma / marker-glued terminator the marker regexes
    // still expect to handle); only the alphabetic core is replaced.
    private static func swapCore(_ token: String, into replacement: String) -> String {
        let lead = String(token.prefix(while: isKeywordEdgePunctuation))
        let trail = String(token.reversed().prefix(while: isKeywordEdgePunctuation).reversed())
        return lead + replacement + trail
    }

    // The `[\s,]*` around the content group trims pause whitespace/commas hugging the markers (so
    // "begin verbatim, new line, end verbatim" protects "new line", not ", new line,") while leaving the content's
    // own edge terminators intact — a span may be "Hello!" or "foo();". spliceAbsorbing then cleans commas OUTSIDE the markers.
    private static let contentEdge = "[\\s,]*"
    // A sentence terminator FLUSH against a marker word ("begin verbatim." no space) is a pause artifact, not
    // content. Stripped only when glued to the marker, so a space-separated content-leading terminal (".config")
    // survives (leadingPeriodInContentPreserved).
    private static let markerGluedTerminator = "[.!?]*"

    private static func replacePairs(_ text: String, _ tokenizer: Tokenizer) -> String {
        let pattern = "(?i)\(beginTrigger)\(markerGluedTerminator)\(contentEdge)(.*?)\(contentEdge)\(endTrigger)"
        guard let re = RegexCache.regex(pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let spans = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            m -> (range: Range<String.Index>, value: String)? in
            guard let full = Range(m.range, in: text), let content = Range(m.range(at: 1), in: text) else { return nil }
            return (full, String(text[content]))
        }
        // dedup: false — equal-content spans must stay distinct tokens, or a faithful rewrite reproducing both
        // trips the gate's exactly-once check (mirrors ClipboardTokenizer). foldBracketedTerminators: false — a
        // user-delimited span is not an inline paste; on a pause it stays its own clause, not merged into the previous.
        return tokenizer.spliceAbsorbing(
            text, spans: spans, type: .verbatim, dedup: false,
            foldBracketedTerminators: false, collapseTrailingTerminator: true)
    }

    // Fallback close for a mistranscribed "end verbatim". Runs after replacePairs, so an exact end is
    // already consumed — a rescue never overrides a correctly-closed span. Anchors on the literal
    // "verbatim"; accepts the preceding word only when it is phonetically "end" (endLike).
    private static let contentTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))

    private static func replaceRescue(_ text: String, _ tokenizer: Tokenizer) -> String {
        guard let beginRe = RegexCache.regex("(?i)\(beginTrigger)", options: []),
              let candRe = RegexCache.regex("(?i)\\b(\\w+)[,;:]?\\s+verbatim\\b", options: []) else { return text }
        var spans: [(range: Range<String.Index>, value: String)] = []
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let bm = beginRe.firstMatch(in: text, range: NSRange(searchFrom..<text.endIndex, in: text)),
              let br = Range(bm.range, in: text) {
            var chosen: Range<String.Index>?
            for m in candRe.matches(in: text, range: NSRange(br.upperBound..<text.endIndex, in: text)) {
                guard let wordRange = Range(m.range(at: 1), in: text), let candRange = Range(m.range, in: text)
                else { continue }
                if endLike(String(text[wordRange])) { chosen = candRange; break }
            }
            guard let candRange = chosen else { break }
            var contentStart = br.upperBound
            while contentStart < candRange.lowerBound, "!.?".contains(text[contentStart]) {
                contentStart = text.index(after: contentStart)
            }
            let value = String(text[contentStart..<candRange.lowerBound]).trimmingCharacters(in: contentTrim)
            spans.append((br.lowerBound..<candRange.upperBound, value))
            searchFrom = candRange.upperBound
        }
        guard !spans.isEmpty else { return text }
        return tokenizer.spliceAbsorbing(
            text, spans: spans, type: .verbatim, dedup: false,
            foldBracketedTerminators: false, collapseTrailingTerminator: true)
    }

    // phoneticKey is a vowel-blind consonant skeleton ("end" → "53"). A prefix match accepts both the
    // vowel-swap "and" ("53") and the dropped-final-consonant "en" ("5", Parakeet's real mishear), while
    // "send"/"bend"/"lend" ("253"/"153"/"453") fail the prefix and "in"/"an" fail the Levenshtein confirm.
    private static let endPhoneticKey = FuzzyCorrector.phoneticKey("end")
    private static func endLike(_ word: String) -> Bool {
        let w = word.lowercased()
        let key = FuzzyCorrector.phoneticKey(w)
        return !key.isEmpty && endPhoneticKey.hasPrefix(key) && FuzzyCorrector.levenshtein(w, "end") <= 1
    }

    // Unclosed span: protect to end of utterance (fail-closed — a shielded span never reaches the LLM).
    // The literal "begin verbatim" marker is tokenized WITH the content, so the tell survives the LLM
    // (the gate only guarantees nonce tokens; plain text next to a token could be reworded away).
    private static func replaceUnterminated(_ text: String, _ tokenizer: Tokenizer) -> String {
        guard let re = RegexCache.regex("(?i)\(beginTrigger)", options: []),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return text }
        let edgeTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        // Same marker-glued-terminator rule as replacePairs: "begin verbatim. rest" drops the pause
        // period; "begin verbatim .config" (space first) keeps it as content.
        var contentStart = r.upperBound
        while contentStart < text.endIndex, "!.?".contains(text[contentStart]) {
            contentStart = text.index(after: contentStart)
        }
        let content = text[contentStart...].trimmingCharacters(in: edgeTrim)
        guard !content.isEmpty else { return text }
        let marker = String(text[r])
        let token = tokenizer.tokenize("\(marker) \(content)", type: .verbatim)
        let prefix = String(text[..<r.lowerBound]).trimmingCharacters(in: edgeTrim)
        return prefix.isEmpty ? token : "\(prefix) \(token)"
    }
}
