import Foundation

public enum AliasDiscovery {
    public static let defaultThreshold = 0.65
    static let maxWindowTokens = 3

    public struct Occurrence: Sendable, Equatable {
        public let entry: Int
        public let range: Range<String.Index>
        public let score: Double
    }

    public struct Finding: Sendable, Equatable {
        public let phrase: String
        public let key: String
        public let score: Double
        public let occurrences: [Occurrence]
    }

    public static func find(
        target: String, in texts: [String], dictionary: [String] = [], threshold: Double = defaultThreshold
    ) -> [Finding] {
        let targetNorm = FuzzyCorrector.normalize(target)
        guard !targetNorm.isEmpty else { return [] }
        let protectedNorms = Set(([target] + dictionary).map(FuzzyCorrector.normalize).filter { !$0.isEmpty })
        let prepared = Target(targetNorm)
        var scores: [String: Double] = [:]
        func cachedScore(_ norm: String) -> Double {
            if let known = scores[norm] { return known }
            let value = score(norm, target: prepared)
            scores[norm] = value
            return value
        }
        var groups: [String: (phrase: String, score: Double, occurrences: [Occurrence])] = [:]
        for (entry, text) in texts.enumerated() {
            if Task.isCancelled { return [] }
            for match in matches(
                in: text, targetLength: targetNorm.count, protectedNorms: protectedNorms, threshold: threshold,
                score: cachedScore
            ) {
                let occurrence = Occurrence(entry: entry, range: match.range, score: match.score)
                if var group = groups[match.key] {
                    group.score = max(group.score, match.score)
                    group.occurrences.append(occurrence)
                    groups[match.key] = group
                } else {
                    groups[match.key] = (match.phrase, match.score, [occurrence])
                }
            }
        }
        return groups
            .map { Finding(phrase: $0.value.phrase, key: $0.key, score: $0.value.score, occurrences: $0.value.occurrences) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.occurrences.count != $1.occurrences.count { return $0.occurrences.count > $1.occurrences.count }
                return $0.key < $1.key
            }
    }

    struct Target {
        let norm: String
        let latin: [UInt8]?
        let sound: [UInt8]
        let key: String

        init(_ norm: String) {
            self.norm = norm
            latin = FuzzyCorrector.latinized(norm).map { Array($0.utf8) }
            sound = latin.map(AliasDiscovery.phoneticSpelling) ?? []
            key = FuzzyCorrector.phoneticKey(norm)
        }
    }

    static func score(_ heard: String, target: String) -> Double {
        score(heard, target: Target(target))
    }

    static func score(_ heard: String, target: Target) -> Double {
        guard let targetLatin = target.latin, let heardLatin = FuzzyCorrector.latinized(heard).map({ Array($0.utf8) }) else {
            return similarity(heard, target.norm)
        }
        let a = phoneticSpelling(heardLatin), b = target.sound
        let sound = 1 - weightedDistance(a, b) / Double(max(a.count, b.count, 1))
        let combined = 0.5 * similarity(heardLatin, targetLatin) + 0.5 * sound
        // The same consonant skeleton is evidence the spelling alone undersells: "Croydon" is four edits from
        // "Kryten" yet sounds like it. Such a candidate is judged on sound.
        guard !target.key.isEmpty, FuzzyCorrector.phoneticKey(heard) == target.key else { return combined }
        return max(combined, sound)
    }

    private struct Token {
        let core: String
        let norm: String
        let range: Range<String.Index>
        let hasLeadingPunctuation: Bool
        let hasTrailingPunctuation: Bool
        let breaksWindows: Bool
    }

    private struct Match {
        let key: String
        let phrase: String
        let range: Range<String.Index>
        let score: Double
        let tokens: Range<Int>
    }

    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            var lo = index, hi = end
            while lo < hi, text[lo].unicodeScalars.allSatisfy(edgePunctuation.contains) { lo = text.index(after: lo) }
            while hi > lo, text[text.index(before: hi)].unicodeScalars.allSatisfy(edgePunctuation.contains) {
                hi = text.index(before: hi)
            }
            let raw = text[index..<end]
            let core = String(text[lo..<hi])
            let norm = FuzzyCorrector.normalize(core)
            result.append(Token(
                core: core, norm: norm, range: lo..<hi,
                hasLeadingPunctuation: lo != index, hasTrailingPunctuation: hi != end,
                breaksWindows: norm.isEmpty || raw.contains(SentinelText.open)))
            index = end
        }
        return result
    }

    private static func windows(_ tokens: [Token]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for start in tokens.indices {
            for length in 1...maxWindowTokens where start + length <= tokens.count {
                let span = start..<(start + length)
                guard span.allSatisfy({ !tokens[$0].breaksWindows }) else { break }
                let joinsCleanly = span.allSatisfy { i in
                    (i == span.lowerBound || !tokens[i].hasLeadingPunctuation)
                        && (i == span.upperBound - 1 || !tokens[i].hasTrailingPunctuation)
                }
                guard joinsCleanly else { break }
                result.append(span)
            }
        }
        return result
    }

    private static func matches(
        in text: String, targetLength: Int, protectedNorms: Set<String>, threshold: Double,
        score: (String) -> Double
    ) -> [Match] {
        let tokens = tokens(in: text)
        let spans = windows(tokens)
        let joined = spans.map { span in span.map { tokens[$0].norm }.joined() }
        var protected = Set<Int>()
        for (span, norm) in zip(spans, joined) where protectedNorms.contains(norm) { protected.formUnion(span) }
        let lowest = Double(targetLength) * 0.5, highest = Double(targetLength) * 1.6 + 1
        var candidates: [Match] = []
        for (span, norm) in zip(spans, joined) {
            guard !span.contains(where: protected.contains) else { continue }
            guard Double(norm.count) >= lowest, Double(norm.count) <= highest else { continue }
            let value = score(norm)
            guard value >= threshold else { continue }
            let cores = span.map { tokens[$0].core }
            candidates.append(Match(
                key: cores.joined(separator: " ").lowercased(), phrase: cores.joined(separator: " "),
                range: tokens[span.lowerBound].range.lowerBound..<tokens[span.upperBound - 1].range.upperBound,
                score: value, tokens: span))
        }
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.tokens.count != $1.tokens.count { return $0.tokens.count < $1.tokens.count }
            return $0.tokens.lowerBound < $1.tokens.lowerBound
        }
        var taken = Set<Int>()
        var kept: [Match] = []
        for candidate in candidates where !candidate.tokens.contains(where: taken.contains) {
            taken.formUnion(candidate.tokens)
            kept.append(candidate)
        }
        return kept.sorted { $0.tokens.lowerBound < $1.tokens.lowerBound }
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return 1 - Double(FuzzyCorrector.levenshtein(a, b)) / Double(longest)
    }

    private static func similarity(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[b.count]) / Double(longest)
    }

    private static let soundRewrites: [(from: [UInt8], to: [UInt8])] = [
        ("tion", "SHN"), ("sion", "ZHN"), ("igh", "AI"),
        ("ph", "F"), ("gh", "G"), ("ck", "K"), ("qu", "KW"), ("sh", "SH"), ("ch", "CH"), ("th", "TH"),
        ("wh", "W"), ("ce", "SE"), ("ci", "SI"), ("cy", "SY"), ("ge", "JE"), ("gi", "JI"), ("ee", "I"),
        ("ea", "I"), ("oo", "U"), ("ou", "AU"), ("ow", "AU"), ("ai", "EI"), ("ay", "EI"),
        ("x", "KS"), ("c", "K"), ("q", "K"), ("z", "S"), ("y", "I"),
    ].map { (Array($0.0.utf8), Array($0.1.utf8)) }

    static func phoneticSpelling(_ latin: String) -> String {
        String(decoding: phoneticSpelling(Array(latin.utf8)), as: UTF8.self)
    }

    static func phoneticSpelling(_ letters: [UInt8]) -> [UInt8] {
        var spelled: [UInt8] = []
        spelled.reserveCapacity(letters.count + 4)
        func append(_ byte: UInt8) {
            if spelled.last != byte { spelled.append(byte) }
        }
        var i = 0
        while i < letters.count {
            if let rewrite = soundRewrites.first(where: { rewrite in
                i + rewrite.from.count <= letters.count
                    && rewrite.from.indices.allSatisfy { letters[i + $0] == rewrite.from[$0] }
            }) {
                rewrite.to.forEach(append)
                i += rewrite.from.count
            } else {
                append(uppercased(letters[i]))
                i += 1
            }
        }
        return spelled
    }

    private static func uppercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ? byte - 32 : byte
    }

    private static func isVowel(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "A") || byte == UInt8(ascii: "E") || byte == UInt8(ascii: "I")
            || byte == UInt8(ascii: "O") || byte == UInt8(ascii: "U")
    }

    private static let soundClasses: [UInt8] = (0...UInt8.max).map { byte in
        if isVowel(byte) { return UInt8(ascii: "V") }
        guard byte < 128 else { return byte }
        return FuzzyCorrector.phoneticKey(String(UnicodeScalar(byte))).utf8.first ?? byte
    }

    private static func insertionCost(_ byte: UInt8) -> Double { isVowel(byte) ? 0.5 : 1 }

    private static func substitutionCost(_ a: UInt8, _ b: UInt8) -> Double {
        if a == b { return 0 }
        if isVowel(a), isVowel(b) { return 0.4 }
        if soundClasses[Int(a)] == soundClasses[Int(b)] { return 0.5 }
        return 1
    }

    static func weightedDistance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var previous = [0.0]
        previous.reserveCapacity(b.count + 1)
        for c in b { previous.append(previous.last! + insertionCost(c)) }
        var current = [Double](repeating: 0, count: b.count + 1)
        for x in a {
            current[0] = previous[0] + insertionCost(x)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + insertionCost(x),
                    current[j] + insertionCost(y),
                    previous[j] + substitutionCost(x, y))
            }
            swap(&previous, &current)
        }
        return previous.last!
    }
}

extension AliasDiscovery {
    public static func separatingHandled(
        _ findings: [Finding], in texts: [String], target: String, stages: (Int) -> [any PipelineStage]
    ) -> (open: [Finding], handled: [Finding]) {
        func output(_ text: String, entry: Int) -> [String] {
            var context = PipelineContext(text: text)
            for stage in stages(entry) { stage.apply(&context) }
            return normalizedWords(context.bareReplacement?.text ?? context.text)
        }
        var outputs: [Int: [String]] = [:]
        func currentOutput(_ entry: Int) -> [String] {
            if let cached = outputs[entry] { return cached }
            let words = output(texts[entry], entry: entry)
            outputs[entry] = words
            return words
        }
        var open: [Finding] = [], handled: [Finding] = []
        for finding in findings {
            if Task.isCancelled { break }
            let fixedEverywhere = finding.occurrences.allSatisfy { occurrence in
                var heardCorrectly = texts[occurrence.entry]
                heardCorrectly.replaceSubrange(occurrence.range, with: target)
                return currentOutput(occurrence.entry) == output(heardCorrectly, entry: occurrence.entry)
            }
            if fixedEverywhere { handled.append(finding) } else { open.append(finding) }
        }
        return (open, handled)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { FuzzyCorrector.normalize(String($0)) }.filter { !$0.isEmpty }
    }
}
