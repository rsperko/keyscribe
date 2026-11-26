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

    public static func normalizedWer(reference: String, hypothesis: String) -> Double {
        let r = canonicalTokens(reference)
        let h = canonicalTokens(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(editDistance(r, h)) / Double(r.count)
    }

    static func canonicalTokens(_ s: String) -> [String] {
        let spelled = tokens(spokenForms(s)).map { americanSpelling[$0] ?? $0 }
        return numbersAsDigits(spelled)
    }

    private static func spokenForms(_ s: String) -> String {
        var text = s.lowercased()
        let rules: [(String, String)] = [
            (#"(?<![a-z])([ap])\.m\.?(?![a-z])"#, "$1m"),
            (#"(\d)\s*(am|pm)(?![a-z])"#, "$1 $2"),
            (#"(\d),(?=\d{3})"#, "$1"),
            (#"([$£€])\s*(\d+(?:\.\d+)?)"#, "$2 $1"),
            (#"%"#, " percent "),
            (#"(\d{1,2}):(\d{2})"#, "$1$2"),
            (#"(\d)\.(?=\d)"#, "$1 point "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
            .replacingOccurrences(of: "$", with: "dollars")
            .replacingOccurrences(of: "£", with: "pounds")
            .replacingOccurrences(of: "€", with: "euros")
    }

    private static let ordinalWords: [String: String] = [
        "first": "one", "second": "two", "third": "three", "fourth": "four", "fifth": "five",
        "sixth": "six", "seventh": "seven", "eighth": "eight", "ninth": "nine", "tenth": "ten",
        "eleventh": "eleven", "twelfth": "twelve", "thirteenth": "thirteen", "fourteenth": "fourteen",
        "fifteenth": "fifteen", "sixteenth": "sixteen", "seventeenth": "seventeen",
        "eighteenth": "eighteen", "nineteenth": "nineteen", "twentieth": "twenty",
        "thirtieth": "thirty", "fortieth": "forty", "fiftieth": "fifty", "sixtieth": "sixty",
        "seventieth": "seventy", "eightieth": "eighty", "ninetieth": "ninety",
        "hundredth": "hundred", "thousandth": "thousand",
    ]

    private static let numberForms: Set<SpokenNumber.Form> = [.whole, .grouped, .digits]

    private static func numbersAsDigits(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            if let digits = ordinalDigits(words[i]) {
                out.append(digits)
                i += 1
                continue
            }
            let run = SpokenNumber.read(words[i...], forms: numberForms)
            let length = run?.words ?? 0
            if length > 0, i + length < words.count, let cardinal = ordinalWords[words[i + length]],
               let ordinal = SpokenNumber.read(Array(words[i..<(i + length)] + [cardinal])[...], forms: numberForms),
               ordinal.words == length + 1, let value = ordinal.value {
                out.append("\(value)th")
                i += length + 1
            } else if let run, let value = run.value {
                out.append(String(value))
                i += run.words
            } else if length > 0 {
                out.append(contentsOf: words[i..<(i + length)])
                i += length
            } else if let cardinal = ordinalWords[words[i]],
                      let value = SpokenNumber.read([cardinal][...], forms: numberForms)?.value {
                out.append("\(value)th")
                i += 1
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out
    }

    private static func ordinalDigits(_ word: String) -> String? {
        for suffix in ["st", "nd", "rd", "th"] where word.hasSuffix(suffix) {
            let digits = word.dropLast(2)
            if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) {
                return "\(value)th"
            }
        }
        return nil
    }

    private static let americanSpelling: [String: String] = {
        let plain = ["", "s", "ed", "ing", "er", "ers"]
        let stems: [(british: String, american: String, endings: [String])] = [
            ("colour", "color", plain + ["ful", "less"]),
            ("favour", "favor", plain + ["ite", "ites", "able"]),
            ("neighbour", "neighbor", plain + ["hood", "hoods", "ing"]),
            ("honour", "honor", plain + ["able"]),
            ("labour", "labor", plain),
            ("behaviour", "behavior", plain + ["al"]),
            ("humour", "humor", plain),
            ("flavour", "flavor", plain),
            ("harbour", "harbor", plain),
            ("centre", "center", ["", "s", "d"]),
            ("metre", "meter", ["", "s"]),
            ("litre", "liter", ["", "s"]),
            ("theatre", "theater", ["", "s"]),
            ("organis", "organiz", ["e", "es", "ed", "ing", "er", "ers", "ation", "ations"]),
            ("realis", "realiz", ["e", "es", "ed", "ing", "ation"]),
            ("recognis", "recogniz", ["e", "es", "ed", "ing"]),
            ("analys", "analyz", ["e", "es", "ed", "ing"]),
            ("apologis", "apologiz", ["e", "es", "ed", "ing"]),
            ("prioritis", "prioritiz", ["e", "es", "ed", "ing", "ation"]),
            ("summaris", "summariz", ["e", "es", "ed", "ing"]),
            ("customis", "customiz", ["e", "es", "ed", "ing", "ation"]),
            ("minimis", "minimiz", ["e", "es", "ed", "ing"]),
            ("maximis", "maximiz", ["e", "es", "ed", "ing"]),
            ("authoris", "authoriz", ["e", "es", "ed", "ing", "ation"]),
            ("emphasis", "emphasiz", ["e", "es", "ed", "ing"]),
            ("normalis", "normaliz", ["e", "es", "ed", "ing", "ation"]),
            ("cancell", "cancel", ["ed", "ing", "ation"]),
            ("travell", "travel", ["ed", "ing", "er", "ers"]),
            ("labell", "label", ["ed", "ing"]),
            ("modell", "model", ["ed", "ing"]),
            ("fuell", "fuel", ["ed", "ing"]),
            ("catalogue", "catalog", ["", "s"]),
            ("dialogue", "dialog", ["", "s"]),
            ("programme", "program", ["", "s"]),
            ("defence", "defense", [""]),
            ("offence", "offense", [""]),
            ("grey", "gray", ["", "s"]),
            ("cheque", "check", ["", "s"]),
            ("aluminium", "aluminum", [""]),
            ("jewellery", "jewelry", [""]),
            ("judgement", "judgment", ["", "s"]),
            ("ageing", "aging", [""]),
            ("sceptical", "skeptical", [""]),
            ("artefact", "artifact", ["", "s"]),
        ]
        var table = ["dollar": "dollars", "euro": "euros"]
        for stem in stems {
            for ending in stem.endings {
                table[stem.british + ending] = stem.american + ending
            }
        }
        return table
    }()

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
