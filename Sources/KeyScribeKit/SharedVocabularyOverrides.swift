import Foundation

// Where a shared entry does not take effect in a mode that uses its vocabulary: the mode's own different word or
// rule, or (in a hand-edited order) a vocabulary listed before it, decides there instead.
public enum SharedVocabularyOverrides {
    public enum Source: Equatable, Sendable {
        case mode
        case shared(id: String, name: String)
    }

    public struct Override: Equatable, Sendable {
        public let modeId: String
        public let modeName: String
        public let by: Source
        public let entry: SharedVocabularyMove.Entry

        public init(modeId: String, modeName: String, by: Source, entry: SharedVocabularyMove.Entry) {
            self.modeId = modeId
            self.modeName = modeName
            self.by = by
            self.entry = entry
        }
    }

    public static func of(
        _ entry: SharedVocabularyMove.Entry, in vocabulary: SharedVocabulary, modes: [Mode], shared: [SharedVocabulary]
    ) -> [Override] {
        modes.filter { $0.hasOwnVocabulary && $0.sharedVocabularies.contains(vocabulary.id) }.compactMap { mode in
            if let own = match(entry, words: mode.dictionary.words, rules: mode.replacements.rules) {
                return differs(own, entry) ? Override(modeId: mode.id, modeName: mode.name, by: .mode, entry: own) : nil
            }
            for earlier in VocabularyMerge.using(mode, shared) {
                if earlier.id == vocabulary.id { return nil }
                if let theirs = match(entry, words: earlier.words, rules: earlier.rules) {
                    return differs(theirs, entry)
                        ? Override(modeId: mode.id, modeName: mode.name, by: .shared(id: earlier.id, name: earlier.name), entry: theirs)
                        : nil
                }
            }
            return nil
        }
    }

    private static func match(
        _ entry: SharedVocabularyMove.Entry, words: [String], rules: [ReplacementsSet.Rule]
    ) -> SharedVocabularyMove.Entry? {
        switch entry {
        case .word(let word):
            let key = SharedVocabularyConflicts.wordKey(word)
            return words.first { SharedVocabularyConflicts.wordKey($0) == key }.map { .word($0) }
        case .rule(let rule):
            let key = SharedVocabularyConflicts.ruleKey(rule)
            return rules.first { SharedVocabularyConflicts.ruleKey($0) == key }.map { .rule($0) }
        }
    }

    private static func differs(_ a: SharedVocabularyMove.Entry, _ b: SharedVocabularyMove.Entry) -> Bool {
        switch (a, b) {
        case let (.word(x), .word(y)): x != y
        case let (.rule(x), .rule(y)): x.replace != y.replace || x.wholeDictation != y.wholeDictation
        default: true
        }
    }
}
