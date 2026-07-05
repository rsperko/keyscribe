import Foundation

// Repairs proper nouns / identifiers the STT split or mangled, snapping them to a dictionary term
// ("charge bee" → "ChargeBee"). Used as per-engine dictionary recovery and deliberately timid:
// the dictionary is a *hint*, never authoritative (design.md §4.2), so we only touch distinctive
// terms (≥4 normalized chars) and never rewrite across more than 2 edits. A pure casing/spacing fix
// (same normalized form) is always safe and needs no phonetic check. Every *fuzzy* (non-exact) snap
// requires phonetic agreement as a NECESSARY gate, not a bonus — otherwise a common word one edit
// from a term but distinct in sound ("lava"→"Java", "dust"→"Rust") gets swallowed, the classic
// edit-distance false-positive band. Agreement then buys one edit beyond the bare cap (ceiling 2),
// so a plausible mishearing ("sellery"→"Celery") still recovers.
public enum FuzzyCorrector {
    // Canonicalized dictionary, with each term's phonetic key precomputed once. Built when the stage
    // is constructed (per mode/config generation) so a dictation never re-normalizes or re-keys the
    // whole dictionary, and never recomputes a term's phonetic key per input token.
    public struct Prepared: Sendable {
        fileprivate let terms: [Term]
        fileprivate let byNorm: [String: Term]            // O(1) casing/spacing match
        fileprivate let byLength: [Int: [Int]]            // normalized length → term indices, ascending
        public var isEmpty: Bool { terms.isEmpty }
    }

    public static func prepare(_ terms: [String]) -> Prepared {
        let canonical = canonicalize(terms)
        var byNorm: [String: Term] = [:]
        var byLength: [Int: [Int]] = [:]
        for (i, term) in canonical.enumerated() {
            byNorm[term.norm] = term
            byLength[term.norm.count, default: []].append(i)
        }
        return Prepared(terms: canonical, byNorm: byNorm, byLength: byLength)
    }

    public static func apply(_ text: String, prepared: Prepared) -> String {
        guard !prepared.isEmpty else { return text }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        var out: [String] = []
        var i = 0
        while i < tokens.count {
            var replaced = false
            for span in stride(from: min(2, tokens.count - i), through: 1, by: -1) {
                let window = Array(tokens[i..<i + span])
                // A ⟦SN:…⟧ nonce is opaque (design.md §4.2): never fuzzy-snap a window touching one, else a
                // token fragment ("VERB") could be rewritten to a dictionary term and corrupt the span.
                if window.contains(where: { $0.contains(SentinelText.open) }) { continue }
                // A snap keeps only alphanumerics (→ the canonical term), the inter-token spaces it
                // deliberately merges away, and outer-edge punctuation. Any other dictated character
                // inside a token — interior punctuation ("git-hub", "spring,boot"), a clause comma
                // between two tokens ("spring, boot"), or a LiveEdits control char ("git\nhub") — would
                // be silently deleted, so a window carrying such content is left untouched.
                if wouldDeleteInteriorContent(window) { continue }
                let core = window.map(stripPunct).joined()
                let norm = normalize(core)
                guard norm.count >= 4 else { continue }
                // Multi-token windows only snap on an exact normalized match (a split/spacing fix like
                // "charge bee" → "ChargeBee"); fuzzy distance is single-token only, so a short glue
                // word ("to kubernetes") can never be merged away.
                guard let term = bestMatch(norm, in: prepared, allowFuzzy: span == 1),
                      term.norm != norm || term.canonical != core else {
                    continue
                }
                out.append(leadingPunct(window.first!) + term.canonical + trailingPunct(window.last!))
                i += span
                replaced = true
                break
            }
            if !replaced { out.append(tokens[i]); i += 1 }
        }
        return out.joined(separator: " ")
    }

    fileprivate struct Term: Sendable { let canonical: String; let norm: String; let key: String }

    private static func canonicalize(_ terms: [String]) -> [Term] {
        var seen = Set<String>()
        var result: [Term] = []
        for term in terms {
            let canonical = term.trimmingCharacters(in: .whitespaces)
            let norm = normalize(canonical)
            guard norm.count >= 4, seen.insert(norm).inserted else { continue }
            result.append(Term(canonical: canonical, norm: norm, key: phoneticKey(norm)))
        }
        return result
    }

    private static func bestMatch(_ norm: String, in prepared: Prepared, allowFuzzy: Bool) -> Term? {
        if let exact = prepared.byNorm[norm] { return exact }                       // casing/spacing only
        guard allowFuzzy else { return nil }
        let normKey = phoneticKey(norm)
        let allowed = norm.count >= 6 ? 2 : 1
        var candidateIndices: [Int] = []
        for len in (norm.count - allowed)...(norm.count + allowed) where len >= 0 {
            if let bucket = prepared.byLength[len] { candidateIndices.append(contentsOf: bucket) }
        }
        candidateIndices.sort()
        var best: Term?
        var bestDistance = Int.max
        for idx in candidateIndices {
            let term = prepared.terms[idx]
            guard term.key == normKey else { continue }
            let distance = levenshtein(norm, term.norm)
            guard distance <= allowed, distance < bestDistance else { continue }
            bestDistance = distance
            best = term
        }
        return best
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func isAlphanumeric(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    // True when snapping the window would delete a dictated character. `normalize` keeps only
    // alphanumerics and the output re-emits just the outer-edge punctuation (leadingPunct of the first
    // token, trailingPunct of the last), so strip each token's preserved outer edge and report any
    // remaining non-alphanumeric content.
    private static func wouldDeleteInteriorContent(_ window: [String]) -> Bool {
        for (idx, token) in window.enumerated() {
            var lo = token.startIndex
            var hi = token.endIndex
            if idx == 0 { lo = token.index(lo, offsetBy: leadingPunct(token).count) }
            if idx == window.count - 1 { hi = token.index(hi, offsetBy: -trailingPunct(token).count) }
            if lo < hi, token[lo..<hi].contains(where: { !isAlphanumeric($0) }) { return true }
        }
        return false
    }

    private static let punctSet = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")
    private static func stripPunct(_ token: String) -> String {
        token.trimmingCharacters(in: punctSet)
    }
    private static func leadingPunct(_ token: String) -> String {
        String(token.prefix { $0.unicodeScalars.allSatisfy(punctSet.contains) })
    }
    private static func trailingPunct(_ token: String) -> String {
        String(token.reversed().prefix { $0.unicodeScalars.allSatisfy(punctSet.contains) }.reversed())
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    // A first-letter-coded consonant skeleton. Unlike Soundex — which keeps the leading letter
    // literal, truncates to four chars, and so (a) misses a mis-heard leading consonant that is
    // phonetically equivalent (soft C ≡ S, both group 2) and (b) collides long terms — every letter
    // including the first is coded, nothing is truncated, and vowels (plus H/W/Y) separate consonant
    // runs so a repeated code across a vowel survives. Grouping follows Soundex's well-tuned consonant
    // classes, so common ASR confusions (PH≡F, C/K/S, B/P/V, D/T, M/N) share a key. Used only as a
    // necessary phonetic gate, never as proof of a match — the edit-distance check still decides.
    static func phoneticKey(_ s: String) -> String {
        func code(_ c: Character) -> Character? {
            switch c {
            case "B", "F", "P", "V": return "1"
            case "C", "G", "J", "K", "Q", "S", "X", "Z": return "2"
            case "D", "T": return "3"
            case "L": return "4"
            case "M", "N": return "5"
            case "R": return "6"
            default: return nil
            }
        }
        var result = ""
        var lastCode: Character?
        for scalar in s.uppercased().unicodeScalars where ("A"..."Z").contains(Character(scalar)) {
            if let current = code(Character(scalar)) {
                if current != lastCode { result.append(current) }
                lastCode = current
            } else {
                lastCode = nil
            }
        }
        return result
    }
}

public struct FuzzyStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.fuzzy
    private let prepared: FuzzyCorrector.Prepared
    public init(terms: [String]) { self.prepared = FuzzyCorrector.prepare(terms) }
    public func apply(_ context: inout PipelineContext) {
        context.text = FuzzyCorrector.apply(context.text, prepared: prepared)
    }
}
