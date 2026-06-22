import Foundation

// Repairs proper nouns / identifiers the STT split or mangled, snapping them to a dictionary term
// ("charge bee" → "ChargeBee"). Opt-in per mode (commands.fuzzyCorrection) and deliberately timid:
// the dictionary is a *hint*, never authoritative (design.md §4.2), so we only touch distinctive
// terms (≥4 normalized chars), demand a small edit distance, and require Soundex agreement before
// allowing the looser distance. A pure casing/spacing fix (same normalized form) is always safe.
// Bias-less engines (Moonshine) benefit most; bias-capable engines rarely need it.
public enum FuzzyCorrector {
    public static func apply(_ text: String, terms: [String]) -> String {
        let canonical = canonicalize(terms)
        guard !canonical.isEmpty else { return text }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        var out: [String] = []
        var i = 0
        while i < tokens.count {
            var replaced = false
            for span in stride(from: min(2, tokens.count - i), through: 1, by: -1) {
                let window = Array(tokens[i..<i + span])
                let core = window.map(stripPunct).joined()
                let norm = normalize(core)
                guard norm.count >= 4 else { continue }
                // Multi-token windows only snap on an exact normalized match (a split/spacing fix like
                // "charge bee" → "ChargeBee"); fuzzy distance is single-token only, so a short glue
                // word ("to kubernetes") can never be merged away.
                guard let term = bestMatch(norm, in: canonical, allowFuzzy: span == 1),
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

    private struct Term { let canonical: String; let norm: String }

    private static func canonicalize(_ terms: [String]) -> [Term] {
        var seen = Set<String>()
        var result: [Term] = []
        for term in terms {
            let canonical = term.trimmingCharacters(in: .whitespaces)
            let norm = normalize(canonical)
            guard norm.count >= 4, seen.insert(norm).inserted else { continue }
            result.append(Term(canonical: canonical, norm: norm))
        }
        return result
    }

    private static func bestMatch(_ norm: String, in terms: [Term], allowFuzzy: Bool) -> Term? {
        var best: Term?
        var bestDistance = Int.max
        for term in terms {
            if term.norm == norm { return term }                                   // casing/spacing only
            guard allowFuzzy else { continue }
            let distance = levenshtein(norm, term.norm)
            let cap = norm.count >= 8 ? 2 : 1
            let allowed = soundex(norm) == soundex(term.norm) ? cap + 1 : cap
            if distance <= allowed && distance < bestDistance {
                bestDistance = distance
                best = term
            }
        }
        return best
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
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

    static func soundex(_ s: String) -> String {
        let letters = Array(s.uppercased().unicodeScalars.filter { ("A"..."Z").contains(Character($0)) }.map(Character.init))
        guard let first = letters.first else { return "" }
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
        var result = String(first)
        var lastCode = code(first)
        for c in letters.dropFirst() {
            let current = code(c)
            if let current, current != lastCode { result.append(current) }
            if c != "H" && c != "W" { lastCode = current }
        }
        return String((result + "000").prefix(4))
    }
}

public struct FuzzyStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.fuzzy
    public let terms: [String]
    public init(terms: [String]) { self.terms = terms }
    public func run(_ context: inout PipelineContext) {
        context.text = FuzzyCorrector.apply(context.text, terms: terms)
    }
}
