import Foundation

public enum VocabularyProposal: Equatable, Sendable {
    case word(String)
    case replacement(heard: String, replace: String, regex: Bool)
}

public struct VocabularyScope: Equatable, Sendable {
    public struct Local: Equatable, Sendable {
        public var words: [String]
        public var rules: [ReplacementsSet.Rule]
        public var includeGlobalWords: Bool
        public var includeGlobalRules: Bool

        public init(
            words: [String] = [], rules: [ReplacementsSet.Rule] = [],
            includeGlobalWords: Bool = true, includeGlobalRules: Bool = true
        ) {
            self.words = words
            self.rules = rules
            self.includeGlobalWords = includeGlobalWords
            self.includeGlobalRules = includeGlobalRules
        }
    }

    public var globalWords: [String]
    public var globalRules: [ReplacementsSet.Rule]
    public var local: Local?

    public init(globalWords: [String] = [], globalRules: [ReplacementsSet.Rule] = [], local: Local? = nil) {
        self.globalWords = globalWords
        self.globalRules = globalRules
        self.local = local
    }
}

public struct VocabularyAnalysis: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case addWord
        case addReplacement
        case updateWord(currentWord: String)
        case updateReplacement(currentReplace: String)
        case noChange(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case wordAlreadyListed
        case wordCoveredByGlobal
        case replacementAlreadyListed
        case replacementCoveredByGlobal
    }

    public struct Advisory: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case overridesGlobal
        }

        public let kind: Kind
        public let message: String

        public init(kind: Kind, message: String) {
            self.kind = kind
            self.message = message
        }
    }

    public let action: Action
    public let advisories: [Advisory]

    public init(action: Action, advisories: [Advisory] = []) {
        self.action = action
        self.advisories = advisories
    }
}

public enum VocabularyAdvisor {
    public static func analyze(_ proposal: VocabularyProposal, in scope: VocabularyScope) -> VocabularyAnalysis {
        switch proposal {
        case .word(let word):
            return analyzeWord(word, in: scope)
        case .replacement(let heard, let replace, let regex):
            return analyzeReplacement(heard: heard, replace: replace, isRegex: regex, in: scope)
        }
    }

    private static func analyzeWord(_ word: String, in scope: VocabularyScope) -> VocabularyAnalysis {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return VocabularyAnalysis(action: .addWord) }
        func action(for words: [String]) -> VocabularyAnalysis.Action? {
            guard let existing = words.first(where: {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }) else { return nil }
            return existing == trimmed
                ? .noChange(.wordAlreadyListed)
                : .updateWord(currentWord: existing)
        }
        if let local = scope.local {
            if let action = action(for: local.words) { return VocabularyAnalysis(action: action) }
            if local.includeGlobalWords, scope.globalWords.contains(trimmed) {
                return VocabularyAnalysis(action: .noChange(.wordCoveredByGlobal))
            }
            return VocabularyAnalysis(action: .addWord)
        }
        if let action = action(for: scope.globalWords) { return VocabularyAnalysis(action: action) }
        return VocabularyAnalysis(action: .addWord)
    }

    private static func analyzeReplacement(
        heard: String, replace: String, isRegex: Bool, in scope: VocabularyScope
    ) -> VocabularyAnalysis {
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return VocabularyAnalysis(action: .addReplacement) }
        func identityMatches(_ rule: ReplacementsSet.Rule) -> Bool {
            rule.regex == isRegex && sameIdentity(rule.heard, trimmed, isRegex: isRegex)
        }

        let targetRules = scope.local?.rules ?? scope.globalRules
        if let existing = targetRules.first(where: identityMatches) {
            if existing.replace == replace {
                return VocabularyAnalysis(action: .noChange(.replacementAlreadyListed))
            }
            return VocabularyAnalysis(action: .updateReplacement(currentReplace: existing.replace))
        }
        if let local = scope.local, local.includeGlobalRules,
           let global = scope.globalRules.first(where: identityMatches) {
            if global.replace == replace {
                return VocabularyAnalysis(action: .noChange(.replacementCoveredByGlobal))
            }
            return VocabularyAnalysis(action: .addReplacement, advisories: [VocabularyAnalysis.Advisory(
                kind: .overridesGlobal,
                message: "Overrides the global replacement for “\(global.heard)”, which currently becomes \(quoted(global.replace)).")])
        }
        return VocabularyAnalysis(action: .addReplacement)
    }

    private static func sameIdentity(_ a: String, _ b: String, isRegex: Bool) -> Bool {
        isRegex ? a == b : a.caseInsensitiveCompare(b) == .orderedSame
    }

    private static func quoted(_ text: String) -> String {
        text.isEmpty ? "nothing" : "“\(ReplacementAuthoring.preview(for: text).text)”"
    }
}
