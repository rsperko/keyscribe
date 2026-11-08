import Foundation

// Moving a mode's own word or replacement into a shared vocabulary. The mode starts using the vocabulary, so
// it keeps the entry, and a different entry already in the vocabulary is never overwritten.
public enum SharedVocabularyMove {
    public enum Entry: Equatable, Sendable {
        case word(String)
        case rule(ReplacementsSet.Rule)
    }

    public struct Counts: Equatable, Sendable {
        public let words: Int
        public let rules: Int

        public init(words: Int, rules: Int) {
            self.words = words
            self.rules = rules
        }
    }

    public struct Plan: Equatable, Sendable {
        public let users: [String]
        // What the mode gains besides the moved entry; nil when it already uses the vocabulary.
        public let newlyIncluded: Counts?
        public let conflict: String?
    }

    public static func plan(_ entry: Entry, from mode: Mode, to vocabulary: SharedVocabulary, modes: [Mode]) -> Plan {
        func label(_ mode: Mode) -> String { mode.enabled ? mode.name : "\(mode.name) (disabled)" }
        var users = modes.filter { $0.sharedVocabularies.contains(vocabulary.id) && $0.id != mode.id }.map(label)
        users.append(label(mode))
        let newlyIncluded = mode.sharedVocabularies.contains(vocabulary.id) ? nil : Counts(
            words: vocabulary.words.filter { !same(.word($0), entry) }.count,
            rules: vocabulary.rules.filter { !same(.rule($0), entry) }.count)
        return Plan(users: users, newlyIncluded: newlyIncluded, conflict: conflict(entry, in: vocabulary))
    }

    public static func apply(_ entry: Entry, to vocabulary: inout SharedVocabulary, from mode: inout Mode) {
        switch entry {
        case .word(let word):
            if !vocabulary.words.contains(where: { same(.word($0), entry) }) { vocabulary.words.append(word) }
            mode.dictionary.words.removeAll { $0 == word }
        case .rule(let rule):
            if !vocabulary.rules.contains(rule) { vocabulary.rules.append(rule) }
            mode.replacements.rules.removeAll { $0 == rule }
        }
        if !mode.sharedVocabularies.contains(vocabulary.id) { mode.sharedVocabularies.append(vocabulary.id) }
    }

    private static func conflict(_ entry: Entry, in vocabulary: SharedVocabulary) -> String? {
        switch entry {
        case .word(let word):
            guard let theirs = vocabulary.words.first(where: { same(.word($0), entry) }), theirs != word else { return nil }
            return "\(vocabulary.name) already spells it “\(theirs)”."
        case .rule(let rule):
            guard let theirs = vocabulary.rules.first(where: { same(.rule($0), entry) }), theirs != rule else { return nil }
            return "\(vocabulary.name) already replaces “\(theirs.heard)” with “\(ReplacementAuthoring.preview(for: theirs.replace).text)”."
        }
    }

    // Two entries the merge treats as the same word or the same phrase, whatever they produce.
    private static func same(_ a: Entry, _ b: Entry) -> Bool {
        switch (a, b) {
        case let (.word(x), .word(y)): x.caseInsensitiveCompare(y) == .orderedSame
        case let (.rule(x), .rule(y)):
            x.regex == y.regex && (x.regex ? x.heard == y.heard : x.heard.caseInsensitiveCompare(y.heard) == .orderedSame)
        default: false
        }
    }
}
