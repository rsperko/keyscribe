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

    public struct Included: Equatable, Sendable {
        public var name: String
        public var words: [String]
        public var rules: [ReplacementsSet.Rule]

        public init(name: String, words: [String] = [], rules: [ReplacementsSet.Rule] = []) {
            self.name = name
            self.words = words
            self.rules = rules
        }
    }

    public var globalWords: [String]
    public var globalRules: [ReplacementsSet.Rule]
    public var local: Local?
    // The shared vocabularies a mode uses, in the order that decides between them.
    public var shared: [Included]

    public init(
        globalWords: [String] = [], globalRules: [ReplacementsSet.Rule] = [], local: Local? = nil,
        shared: [Included] = []
    ) {
        self.globalWords = globalWords
        self.globalRules = globalRules
        self.local = local
        self.shared = shared
    }
}

extension VocabularyScope {
    public static func of(
        _ mode: Mode, globalWords: [String], globalRules: [ReplacementsSet.Rule], shared: [SharedVocabulary]
    ) -> VocabularyScope {
        VocabularyScope(
            globalWords: globalWords, globalRules: globalRules,
            local: Local(
                words: mode.dictionary.words, rules: mode.replacements.rules,
                includeGlobalWords: mode.dictionary.includeGlobal, includeGlobalRules: mode.replacements.includeGlobal),
            shared: VocabularyMerge.using(mode, shared).map(Included.init))
    }
}

extension VocabularyScope.Included {
    init(_ vocabulary: SharedVocabulary) {
        self.init(name: vocabulary.name, words: vocabulary.words, rules: vocabulary.rules)
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
        case wordCoveredByShared(String)
        case replacementAlreadyListed
        case replacementCoveredByGlobal
        case replacementCoveredByShared(String)
    }

    public struct Advisory: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case overridesGlobal
            case overridesShared
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
            analyzeWord(word, in: scope)
        case .replacement(let heard, let replace, let regex):
            analyzeReplacement(heard: heard, replace: replace, isRegex: regex, in: scope)
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
            func spelling(in words: [String]) -> String? {
                words.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            }
            func overriding(_ theirs: String, from source: String) -> VocabularyAnalysis {
                VocabularyAnalysis(action: .addWord, advisories: [VocabularyAnalysis.Advisory(
                    kind: source == "Global" ? .overridesGlobal : .overridesShared,
                    message: "Overrides the spelling “\(theirs)” from \(source) in this mode.")])
            }
            for included in scope.shared {
                guard let theirs = spelling(in: included.words) else { continue }
                return theirs == trimmed
                    ? VocabularyAnalysis(action: .noChange(.wordCoveredByShared(included.name)))
                    : overriding(theirs, from: included.name)
            }
            if local.includeGlobalWords, let theirs = spelling(in: scope.globalWords) {
                return theirs == trimmed
                    ? VocabularyAnalysis(action: .noChange(.wordCoveredByGlobal))
                    : overriding(theirs, from: "Global")
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
        if scope.local != nil {
            for included in scope.shared {
                guard let inherited = included.rules.first(where: identityMatches) else { continue }
                if inherited.replace == replace {
                    return VocabularyAnalysis(action: .noChange(.replacementCoveredByShared(included.name)))
                }
                return VocabularyAnalysis(action: .addReplacement, advisories: [VocabularyAnalysis.Advisory(
                    kind: .overridesShared,
                    message: "Overrides the replacement for “\(inherited.heard)” from \(included.name), which currently becomes \(quoted(inherited.replace)).")])
            }
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

extension VocabularyScope {
    // The misheard spellings a word is already corrected from: literal rules in effect here whose output is
    // exactly the word. Shown beside the word so teaching it another spelling has an obvious place to start.
    public static func taughtSpellings(of word: String, in rules: [ReplacementsSet.Rule]) -> [String] {
        rules.filter { !$0.regex && $0.replace == word && $0.heard.caseInsensitiveCompare(word) != .orderedSame }
            .map(\.heard)
    }

    public func taughtSpellings(of word: String) -> [String] {
        let rules = local.map { $0.rules + ($0.includeGlobalRules ? globalRules : []) } ?? globalRules
        var seen = Set<String>()
        return Self.taughtSpellings(of: word, in: rules).filter { seen.insert($0.lowercased()).inserted }
    }

    // The rule in this scope's own list that adding `heard` would update in place, matched the way
    // ReplacementsSet.adding matches it.
    public func ownRule(heard: String, regex: Bool) -> ReplacementsSet.Rule? {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        return (local?.rules ?? globalRules).first {
            $0.regex == regex && (regex ? $0.heard == h : $0.heard.caseInsensitiveCompare(h) == .orderedSame)
        }
    }
}
