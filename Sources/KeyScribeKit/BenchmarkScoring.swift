import Foundation

// Pure scoring for the offline STT benchmark (dev tool, driven by `KeyScribe --benchmark`). WER is
// word-level edit distance over case/punctuation-normalized tokens; term recall measures whether
// recognition bias actually recovered the dictionary terms a clip was meant to exercise.
public enum BenchmarkScoring {
    public static func tokens(_ s: String) -> [String] {
        let mapped = String(String.UnicodeScalarView(
            s.lowercased().unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? scalar : " "
            }))
        return mapped.split(separator: " ").map(String.init)
    }

    // Word error rate = (substitutions + insertions + deletions) / reference word count.
    public static func wer(reference: String, hypothesis: String) -> Double {
        let r = tokens(reference)
        let h = tokens(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(editDistance(r, h)) / Double(r.count)
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    // Fraction of non-blank bias terms that appear (case-insensitively) in the hypothesis. Returns 1
    // when there are no terms to find (nothing to recover → vacuously complete).
    public static func termRecall(terms: [String], in hypothesis: String) -> Double {
        let wanted = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return 1 }
        let hits = wanted.filter { hypothesis.range(of: $0, options: .caseInsensitive) != nil }.count
        return Double(hits) / Double(wanted.count)
    }

    // Harm-side counterpart to termRecall: how many bias terms surfaced in the hypothesis (same
    // case-insensitive containment) that were NOT in the reference — i.e. the dictionary put a term
    // into the output that was never spoken. On a distractor clip (reference has no dictionary term)
    // every such fire is a false accept.
    public static func termFalseFires(terms: [String], reference: String, hypothesis: String) -> Int {
        let wanted = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return wanted.filter {
            hypothesis.range(of: $0, options: .caseInsensitive) != nil
                && reference.range(of: $0, options: .caseInsensitive) == nil
        }.count
    }

    // Classifies each false fire (see termFalseFires) into two kinds. A fire is ORTHOGRAPHIC when the fired
    // term, whitespace-collapsed and lowercased, is contained in the whitespace-collapsed lowercased
    // reference — the speaker said those words and the dictionary only snapped their spacing/casing
    // ("text field" spoken, "TextField" emitted). It is a SUBSTITUTION when the term's collapsed form is
    // absent from the reference — different words the dictionary put in the speaker's mouth ("review" →
    // "Redis"). Substitution is the disqualifying class; orthographic snaps are the dictionary working as
    // intended. ortho + subst == termFalseFires.
    public static func termFalseFireBreakdown(
        terms: [String], reference: String, hypothesis: String
    ) -> (orthographic: Int, substitution: Int) {
        let wanted = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let collapsedRef = collapsed(reference)
        var ortho = 0, subst = 0
        for t in wanted {
            let fires = hypothesis.range(of: t, options: .caseInsensitive) != nil
                && reference.range(of: t, options: .caseInsensitive) == nil
            guard fires else { continue }
            if collapsedRef.contains(collapsed(t)) { ortho += 1 } else { subst += 1 }
        }
        return (ortho, subst)
    }

    private static func collapsed(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}
