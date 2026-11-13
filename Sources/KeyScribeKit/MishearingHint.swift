import Foundation

// Likely mishearings of dictionary words in one take, shown to the user in History and never sent to an AI
// service: a model accepts a sound-alike it is handed (dictionary_findings.md §6), the user can judge it.
// Uses the History finder's own scoring, and leaves out a phrase a rule or the near match already fixes.
public enum MishearingHint {
    public struct Hint: Sendable, Equatable {
        public let phrase: String
        public let term: String
        public init(phrase: String, term: String) {
            self.phrase = phrase
            self.term = term
        }
    }

    // A hint and the scope its dictionary word lives in, where a fix for it is reviewed.
    public struct Suggestion: Sendable, Equatable {
        public let phrase: String
        public let term: String
        public let origin: ReplacementOrigin
        public init(phrase: String, term: String, origin: ReplacementOrigin) {
            self.phrase = phrase
            self.term = term
            self.origin = origin
        }
    }

    public static let minimumScore = 0.85

    public static func find(heard: String, dictionary: [String], stages: [any PipelineStage]) -> [Hint] {
        let texts = [heard]
        var scored: [(hint: Hint, score: Double)] = []
        for term in dictionary {
            if Task.isCancelled { return [] }
            let findings = AliasDiscovery.find(target: term, in: texts, dictionary: dictionary)
            guard !findings.isEmpty else { continue }
            let open = AliasDiscovery.separatingHandled(findings, in: texts, target: term, stages: { _ in stages }).open
            guard let best = open.first, best.score >= minimumScore, let occurrence = best.occurrences.first else { continue }
            scored.append((Hint(phrase: String(heard[occurrence.range]), term: term), best.score))
        }
        return scored.sorted { $0.score > $1.score }.map(\.hint)
    }
}
