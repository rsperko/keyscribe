import Foundation

public enum AliasDiscoveryEvaluation {
    public struct Record: Sendable {
        public let heard: String
        public let reference: String
        public let dictionary: [String]
        public init(heard: String, reference: String, dictionary: [String]) {
            self.heard = heard
            self.reference = reference
            self.dictionary = dictionary
        }
    }

    public enum Label: Equatable {
        case miss(Range<String.Index>)
        case exact(Range<String.Index>)
        case omitted
    }

    public struct TermSummary: Sendable, Equatable {
        public var term: String
        public var occurrences = 0
        public var occurrencesFound = 0
        public var forms = 0
        public var formsFound = 0
        public var missedForms: [String] = []
        public var foundForms: [String] = []
        public var wrongGroups: [String] = []
    }

    public struct Summary: Sendable, Equatable {
        public var occurrences = 0
        public var occurrencesFound = 0
        public var forms = 0
        public var formsFound = 0
        public var notAutoCorrected = 0
        public var notAutoCorrectedFound = 0
        public var negativeRecords = 0
        public var wrongSuggestions = 0
        public var wrongGroups = 0
        public var topThreeHits = 0
        public var topThreeSlots = 0
        public var terms: [TermSummary] = []
    }

    public static func evaluate(
        records: [Record], terms: [String], threshold: Double = AliasDiscovery.defaultThreshold
    ) -> Summary {
        let texts = records.map(\.heard)
        var dictionary: [String] = []
        var seen = Set<String>()
        for word in records.flatMap(\.dictionary) where seen.insert(FuzzyCorrector.normalize(word)).inserted {
            dictionary.append(word)
        }
        var summary = Summary()
        for term in terms {
            let labels = records.map { labels(heard: $0.heard, reference: $0.reference, term: term) }
            let findings = AliasDiscovery.find(target: term, in: texts, dictionary: dictionary, threshold: threshold)
            let prepared = FuzzyCorrector.prepare([term])
            var termSummary = TermSummary(term: term)
            var forms: [String: (text: String, found: Bool)] = [:]
            for (entry, entryLabels) in labels.enumerated() {
                if entryLabels.isEmpty { summary.negativeRecords += 1 }
                for case .miss(let range) in entryLabels {
                    let text = records[entry].heard[range].split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    let found = findings.contains { $0.occurrences.contains { $0.entry == entry && $0.range.overlaps(range) } }
                    termSummary.occurrences += 1
                    if found { termSummary.occurrencesFound += 1 }
                    let autoCorrected = FuzzyCorrector.normalize(FuzzyCorrector.apply(text, prepared: prepared))
                        == FuzzyCorrector.normalize(term)
                    if !autoCorrected {
                        summary.notAutoCorrected += 1
                        if found { summary.notAutoCorrectedFound += 1 }
                    }
                    let key = FuzzyCorrector.normalize(text)
                    forms[key] = (forms[key]?.text ?? text.lowercased(), (forms[key]?.found ?? false) || found)
                }
            }
            var ranked: [Bool] = []
            for finding in findings {
                var correct = false
                var wrong = 0
                for occurrence in finding.occurrences {
                    let entryLabels = labels[occurrence.entry]
                    if entryLabels.contains(where: { if case .miss(let r) = $0 { r.overlaps(occurrence.range) } else { false } }) {
                        correct = true
                    } else if !entryLabels.contains(where: { if case .exact(let r) = $0 { r.overlaps(occurrence.range) } else { false } }) {
                        wrong += 1
                    }
                }
                summary.wrongSuggestions += wrong
                if correct {
                    ranked.append(true)
                } else if wrong > 0 {
                    ranked.append(false)
                    termSummary.wrongGroups.append(finding.phrase)
                }
            }
            if !ranked.isEmpty {
                summary.topThreeSlots += min(3, ranked.count)
                summary.topThreeHits += ranked.prefix(3).filter { $0 }.count
            }
            termSummary.forms = forms.count
            termSummary.formsFound = forms.values.filter(\.found).count
            termSummary.missedForms = forms.values.filter { !$0.found }.map(\.text).sorted()
            termSummary.foundForms = forms.values.filter(\.found).map(\.text).sorted()
            summary.occurrences += termSummary.occurrences
            summary.occurrencesFound += termSummary.occurrencesFound
            summary.forms += termSummary.forms
            summary.formsFound += termSummary.formsFound
            summary.wrongGroups += termSummary.wrongGroups.count
            summary.terms.append(termSummary)
        }
        return summary
    }

    private struct Token {
        let norm: String
        let range: Range<String.Index>
    }

    private static func tokens(_ text: String) -> [Token] {
        let edge = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            var lo = index, hi = end
            while lo < hi, text[lo].unicodeScalars.allSatisfy(edge.contains) { lo = text.index(after: lo) }
            while hi > lo, text[text.index(before: hi)].unicodeScalars.allSatisfy(edge.contains) { hi = text.index(before: hi) }
            let norm = FuzzyCorrector.normalize(String(text[lo..<hi]))
            if !norm.isEmpty { result.append(Token(norm: norm, range: lo..<hi)) }
            index = end
        }
        return result
    }

    private enum Step { case match(Int, Int), edit(Int?, Int?) }

    private static func align(_ a: [String], _ b: [String]) -> [Step] {
        var cost = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { cost[i][0] = i }
        for j in 0...b.count { cost[0][j] = j }
        if !a.isEmpty, !b.isEmpty {
            for i in 1...a.count {
                for j in 1...b.count {
                    cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1, cost[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
        }
        var steps: [Step] = []
        var i = a.count, j = b.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1], cost[i][j] == cost[i - 1][j - 1] {
                steps.append(.match(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + 1 {
                steps.append(.edit(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                steps.append(.edit(i - 1, nil)); i -= 1
            } else {
                steps.append(.edit(nil, j - 1)); j -= 1
            }
        }
        return steps.reversed()
    }

    static func labels(heard: String, reference: String, term: String) -> [Label] {
        let termNorm = FuzzyCorrector.normalize(term)
        guard !termNorm.isEmpty else { return [] }
        let ref = tokens(reference), hyp = tokens(heard)
        var spans: [Range<Int>] = []
        for start in ref.indices {
            var joined = ""
            for end in start..<min(start + 4, ref.count) {
                joined += ref[end].norm
                if joined == termNorm { spans.append(start..<(end + 1)); break }
                if joined.count >= termNorm.count { break }
            }
        }
        guard !spans.isEmpty else { return [] }
        let steps = align(ref.map(\.norm), hyp.map(\.norm))
        var matchedHeard: [Int: Int] = [:]
        var blocks: [(ref: Range<Int>, heard: [Int])] = []
        var refCursor = 0
        var current: (refStart: Int, refEnd: Int, heard: [Int])?
        for step in steps {
            switch step {
            case .match(let r, let h):
                if let block = current { blocks.append((block.refStart..<block.refEnd, block.heard)); current = nil }
                matchedHeard[r] = h
                refCursor = r + 1
            case .edit(let r, let h):
                var block = current ?? (refCursor, refCursor, [])
                if let r { block.refEnd = r + 1; refCursor = r + 1 }
                if let h { block.heard.append(h) }
                current = block
            }
        }
        if let block = current { blocks.append((block.refStart..<block.refEnd, block.heard)) }
        return spans.map { span in
            var heardIndices = span.compactMap { matchedHeard[$0] }
            for block in blocks {
                let touches = block.ref.isEmpty
                    ? (span.lowerBound < block.ref.lowerBound && block.ref.lowerBound < span.upperBound)
                    : block.ref.overlaps(span)
                if touches { heardIndices += block.heard }
            }
            guard let lo = heardIndices.min(), let hi = heardIndices.max() else { return .omitted }
            let range = hyp[lo].range.lowerBound..<hyp[hi].range.upperBound
            let joined = hyp[lo...hi].map(\.norm).joined()
            return joined == termNorm ? .exact(range) : .miss(range)
        }
    }
}
