import Foundation

// Where the shared vocabularies a mode uses disagree, and what attaching one changes about Global. A mode's own
// word or rule already decides, so it is never a disagreement. A disagreement is settled by the user with an
// entry of the mode's own rather than by any hidden order; every change that could create one is checked
// against the state it would leave, in every mode it reaches.
public enum SharedVocabularyConflicts {
    public struct Option: Equatable, Sendable {
        public let entry: SharedVocabularyMove.Entry
        public let sources: [String]

        public init(entry: SharedVocabularyMove.Entry, sources: [String]) {
            self.entry = entry
            self.sources = sources
        }
    }

    public struct Competition: Equatable, Sendable {
        public let key: String
        public let phrase: String
        public let options: [Option]

        public init(key: String, phrase: String, options: [Option]) {
            self.key = key
            self.phrase = phrase
            self.options = options
        }

        public var spelling: Bool { key.hasPrefix("w:") }
    }

    public struct Change: Equatable, Sendable {
        public let current: SharedVocabularyMove.Entry
        public let proposed: SharedVocabularyMove.Entry

        public init(current: SharedVocabularyMove.Entry, proposed: SharedVocabularyMove.Entry) {
            self.current = current
            self.proposed = proposed
        }
    }

    public struct Introduced: Equatable, Sendable {
        public let modeId: String
        public let modeName: String
        public let competition: Competition
    }

    // Disagreements present after a change that were not there before, so an old one left in hand-edited files
    // never blocks an unrelated save.
    public static func introduced(
        modesBefore: [Mode], sharedBefore: [SharedVocabulary], modesAfter: [Mode], sharedAfter: [SharedVocabulary]
    ) -> [Introduced] {
        modesAfter.filter(\.hasOwnVocabulary).flatMap { mode in
            let before = modesBefore.first { $0.id == mode.id }.map { competitions(in: $0, shared: sharedBefore) } ?? []
            return competitions(in: mode, shared: sharedAfter).filter { !before.contains($0) }.map {
                Introduced(modeId: mode.id, modeName: mode.name, competition: $0)
            }
        }
    }

    public static func competitions(in mode: Mode, shared: [SharedVocabulary]) -> [Competition] {
        let using = VocabularyMerge.using(mode, shared)
        let ownWords = Set(mode.dictionary.words.map(wordKey))
        let ownRules = Set(mode.replacements.rules.map(ruleKey))
        var groups: [(key: String, options: [Option])] = []
        func add(_ entry: SharedVocabularyMove.Entry, key: String, source: String, same: (SharedVocabularyMove.Entry) -> Bool) {
            guard let g = groups.firstIndex(where: { $0.key == key }) else {
                groups.append((key, [Option(entry: entry, sources: [source])]))
                return
            }
            if let o = groups[g].options.firstIndex(where: { same($0.entry) }) {
                let option = groups[g].options[o]
                if !option.sources.contains(source) {
                    groups[g].options[o] = Option(entry: option.entry, sources: option.sources + [source])
                }
            } else {
                groups[g].options.append(Option(entry: entry, sources: [source]))
            }
        }
        for vocabulary in using {
            for word in vocabulary.words where !ownWords.contains(wordKey(word)) {
                add(.word(word), key: "w:" + wordKey(word), source: vocabulary.name) { $0 == .word(word) }
            }
            for rule in vocabulary.rules where !ownRules.contains(ruleKey(rule)) {
                add(.rule(rule), key: ruleKey(rule), source: vocabulary.name) {
                    guard case .rule(let other) = $0 else { return false }
                    return other.replace == rule.replace && other.wholeDictation == rule.wholeDictation
                }
            }
        }
        return groups.filter { $0.options.count > 1 }.map { group in
            let phrase = switch group.options[0].entry {
            case .word(let word): word
            case .rule(let rule): rule.heard
            }
            return Competition(key: group.key, phrase: phrase, options: group.options)
        }
    }

    // What attaching a vocabulary changes about Global's output in a mode, for entries nothing else decides there.
    public static func globalChanges(
        attaching vocabulary: SharedVocabulary, to mode: Mode, shared: [SharedVocabulary], global: ReplacementsSet,
        globalWords: [String]
    ) -> [Change] {
        let others = VocabularyMerge.using(mode, shared).filter { $0.id != vocabulary.id }
        var decidedWords = Set(mode.dictionary.words.map(wordKey))
        var decidedRules = Set(mode.replacements.rules.map(ruleKey))
        for other in others {
            decidedWords.formUnion(other.words.map(wordKey))
            decidedRules.formUnion(other.rules.map(ruleKey))
        }
        var changes: [Change] = []
        if mode.dictionary.includeGlobal {
            for word in vocabulary.words where !decidedWords.contains(wordKey(word)) {
                if let theirs = globalWords.first(where: { wordKey($0) == wordKey(word) }), theirs != word {
                    changes.append(Change(current: .word(theirs), proposed: .word(word)))
                }
            }
        }
        if mode.replacements.includeGlobal {
            for rule in vocabulary.rules where !decidedRules.contains(ruleKey(rule)) {
                if let theirs = global.rules.first(where: { ruleKey($0) == ruleKey(rule) }),
                   theirs.replace != rule.replace || theirs.wholeDictation != rule.wholeDictation {
                    changes.append(Change(current: .rule(theirs), proposed: .rule(rule)))
                }
            }
        }
        return changes
    }

    static func wordKey(_ word: String) -> String {
        word.folding(options: .caseInsensitive, locale: nil)
    }

    static func ruleKey(_ rule: ReplacementsSet.Rule) -> String {
        rule.regex ? "r:\(rule.heard)" : "l:\(rule.heard.lowercased())"
    }
}
