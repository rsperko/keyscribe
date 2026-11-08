import Foundation
import TOMLKit

public struct DictionarySet: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var words: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case words
    }

    public init(schemaVersion: Int = 1, words: [String] = []) {
        self.schemaVersion = schemaVersion
        self.words = words
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        words = try c.decodeIfPresent([String].self, forKey: .words) ?? []
    }

    public func adding(word: String) -> DictionarySet {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        var copy = self
        if let index = copy.words.firstIndex(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            guard copy.words[index] != trimmed else { return self }
            copy.words[index] = trimmed
        } else {
            copy.words.append(trimmed)
        }
        return copy
    }

    public func removing(word: String) -> DictionarySet {
        var copy = self
        copy.words.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
        return copy
    }
}

public struct ReplacementsSet: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var rules: [Rule]

    public struct Rule: Codable, Equatable, Sendable {
        public var heard: String
        public var replace: String
        public var regex: Bool
        public var wholeDictation: Bool
        public init(heard: String, replace: String, regex: Bool, wholeDictation: Bool = false) {
            self.heard = heard
            self.replace = replace
            self.regex = regex
            self.wholeDictation = wholeDictation
        }

        enum CodingKeys: String, CodingKey {
            case heard, replace, regex
            case wholeDictation = "whole_dictation"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            heard = try c.decode(String.self, forKey: .heard)
            replace = try c.decode(String.self, forKey: .replace)
            regex = try c.decodeIfPresent(Bool.self, forKey: .regex) ?? false
            wholeDictation = try c.decodeIfPresent(Bool.self, forKey: .wholeDictation) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(heard, forKey: .heard)
            try c.encode(replace, forKey: .replace)
            try c.encode(regex, forKey: .regex)
            if wholeDictation { try c.encode(true, forKey: .wholeDictation) }
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rules
    }

    public init(schemaVersion: Int = 1, rules: [Rule] = []) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }

    public func toRules() -> [ReplacementRule] { rules.toReplacementRules() }

    // Correction surface (design.md §4.7): add a literal heard→replace rule, ignoring blanks. Re-adding
    // an existing literal `heard` (case-insensitive) updates that rule in place — dropping the new
    // correction would silently discard the user's intent, and appending would accumulate duplicates.
    public func addingLiteral(heard: String, replace: String) -> ReplacementsSet {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return self }
        var copy = self
        var rule = Rule(heard: h, replace: replace, regex: false)
        if let i = copy.rules.firstIndex(where: { !$0.regex && $0.heard.caseInsensitiveCompare(h) == .orderedSame }) {
            rule.wholeDictation = copy.rules[i].wholeDictation
            copy.rules[i] = rule
        } else {
            copy.rules.append(rule)
        }
        return copy
    }

    // Regex counterpart: same update-in-place, matched by `heard` case-sensitively (regex patterns are).
    public func addingRegex(heard: String, replace: String) -> ReplacementsSet {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return self }
        var copy = self
        var rule = Rule(heard: h, replace: replace, regex: true)
        if let i = copy.rules.firstIndex(where: { $0.regex && $0.heard == h }) {
            rule.wholeDictation = copy.rules[i].wholeDictation
            copy.rules[i] = rule
        } else {
            copy.rules.append(rule)
        }
        return copy
    }

    // An update in place keeps the saved rule's scope unless the caller sets one: a correction that only
    // changes the text must not let a command rule start acting inside sentences.
    public func adding(_ rules: [Rule]) -> ReplacementsSet {
        rules.reduce(self) { $0.adding(heard: $1.heard, replace: $1.replace, regex: $1.regex, wholeDictation: $1.wholeDictation) }
    }

    public func adding(heard: String, replace: String, regex: Bool, wholeDictation: Bool? = nil) -> ReplacementsSet {
        var copy = regex ? addingRegex(heard: heard, replace: replace) : addingLiteral(heard: heard, replace: replace)
        guard let wholeDictation else { return copy }
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = copy.rules.firstIndex(where: {
            $0.regex == regex && (regex ? $0.heard == h : $0.heard.caseInsensitiveCompare(h) == .orderedSame)
        }) {
            copy.rules[i].wholeDictation = wholeDictation
        }
        return copy
    }

    public func replacing(_ original: Rule, with updated: Rule) -> ReplacementsSet {
        let heard = updated.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, let index = rules.firstIndex(of: original) else { return self }
        let replacement = Rule(heard: heard, replace: updated.replace, regex: updated.regex, wholeDictation: updated.wholeDictation)
        guard !rules.indices.contains(where: {
            $0 != index && Self.sameIdentity(rules[$0], replacement)
        }) else { return self }
        var copy = self
        copy.rules[index] = replacement
        return copy
    }

    public func reordering(_ orderedRules: [Rule]) -> ReplacementsSet {
        var remaining = orderedRules.filter { candidate in rules.contains(candidate) }
        guard remaining.count > 1 else { return self }
        var copy = self
        copy.rules = rules.map { rule in
            guard orderedRules.contains(rule), !remaining.isEmpty else { return rule }
            return remaining.removeFirst()
        }
        return copy
    }

    private static func sameIdentity(_ lhs: Rule, _ rhs: Rule) -> Bool {
        guard lhs.regex == rhs.regex else { return false }
        return lhs.regex ? lhs.heard == rhs.heard : lhs.heard.caseInsensitiveCompare(rhs.heard) == .orderedSame
    }
}

extension [ReplacementsSet.Rule] {
    public func toReplacementRules() -> [ReplacementRule] {
        map { ReplacementRule(heard: $0.heard, replace: $0.replace, isRegex: $0.regex, wholeDictation: $0.wholeDictation) }
    }
}

public enum VocabularyMerge {
    // Mode-only over shared over Global. Among shared vocabularies the one the mode lists first wins; Settings
    // asks the user to settle a real conflict, so the order only decides a hand-edited one.
    public static func words(global: [String], shared: [[String]], local: [String], includeGlobal: Bool) -> [String] {
        let sharedWords = shared.reversed().reduce([String]()) { below, above in
            words(global: below, local: above, includeGlobal: true)
        }
        let base = includeGlobal ? words(global: global, local: sharedWords, includeGlobal: true) : sharedWords
        return words(global: base, local: local, includeGlobal: true)
    }

    public static func rules(
        global: [ReplacementRule], shared: [[ReplacementRule]], local: [ReplacementRule], includeGlobal: Bool
    ) -> [ReplacementRule] {
        let sharedRules = shared.reduce([ReplacementRule]()) { above, below in
            rules(global: below, local: above, includeGlobal: true)
        }
        let base = includeGlobal ? rules(global: global, local: sharedRules, includeGlobal: true) : sharedRules
        return rules(global: base, local: local, includeGlobal: true)
    }

    // What one mode uses, from Global, the shared vocabularies it lists, and its own entries.
    public static func words(for mode: Mode?, global: [String], shared: [SharedVocabulary]) -> [String] {
        guard let mode else { return global }
        return words(
            global: global, shared: using(mode, shared).map(\.words), local: mode.dictionary.words,
            includeGlobal: mode.dictionary.includeGlobal)
    }

    public static func rules(for mode: Mode?, global: ReplacementsSet, shared: [SharedVocabulary]) -> [ReplacementRule] {
        let globalRules = global.toRules().map { $0.from(.global) }
        guard let mode else { return globalRules }
        return rules(
            global: globalRules, shared: using(mode, shared).map(\.replacementRules),
            local: mode.replacements.toRules().map { $0.from(.mode(mode.id)) },
            includeGlobal: mode.replacements.includeGlobal)
    }

    // An entry a mode uses but does not list itself; `source` is the shared vocabulary's id, or nil for Global.
    public struct Included<Value: Equatable & Sendable>: Equatable, Sendable {
        public let value: Value
        public let source: String?

        public init(value: Value, source: String?) {
            self.value = value
            self.source = source
        }
    }

    // What a mode inherits, only the entries in effect there, in the order the merge decides them.
    public static func included(
        in mode: Mode, globalWords: [String], global: ReplacementsSet, shared: [SharedVocabulary]
    ) -> (words: [Included<String>], rules: [Included<ReplacementsSet.Rule>]) {
        let using = using(mode, shared)
        var seenWords = Set(mode.dictionary.words.map(wordKey))
        var words: [Included<String>] = []
        let wordLayers = using.map { ($0.words, Optional($0.id)) } + (mode.dictionary.includeGlobal ? [(globalWords, nil)] : [])
        for (layer, source) in wordLayers {
            for word in layer where seenWords.insert(wordKey(word)).inserted {
                words.append(.init(value: word, source: source))
            }
        }
        func ruleKey(_ rule: ReplacementsSet.Rule) -> String { key(rule.toReplacementRule()) }
        var seenRules = Set(mode.replacements.rules.map(ruleKey))
        var rules: [Included<ReplacementsSet.Rule>] = []
        let ruleLayers = using.map { ($0.rules, Optional($0.id)) } + (mode.replacements.includeGlobal ? [(global.rules, nil)] : [])
        for (layer, source) in ruleLayers {
            for rule in layer where seenRules.insert(ruleKey(rule)).inserted {
                rules.append(.init(value: rule, source: source))
            }
        }
        return (words, rules)
    }

    public static func using(_ mode: Mode, _ shared: [SharedVocabulary]) -> [SharedVocabulary] {
        mode.sharedVocabularies.compactMap { id in shared.first { $0.id == id } }
    }

    public static func words(global: [String], local: [String], includeGlobal: Bool) -> [String] {
        var seen = Set<String>()
        let uniqueLocal = local.filter { seen.insert(wordKey($0)).inserted }
        guard includeGlobal else { return uniqueLocal }
        let localByKey = Dictionary(uniqueKeysWithValues: uniqueLocal.map { (wordKey($0), $0) })
        seen.removeAll()
        var merged: [String] = []
        for word in global {
            let key = wordKey(word)
            guard seen.insert(key).inserted else { continue }
            merged.append(localByKey[key] ?? word)
        }
        for word in uniqueLocal where seen.insert(wordKey(word)).inserted {
            merged.append(word)
        }
        return merged
    }

    private static func wordKey(_ word: String) -> String {
        word.folding(options: .caseInsensitive, locale: nil)
    }

    public static func rules(
        global: [ReplacementRule], local: [ReplacementRule], includeGlobal: Bool
    ) -> [ReplacementRule] {
        guard includeGlobal else { return local }
        let overridden = Set(local.map(key))
        return local + global.filter { !overridden.contains(key($0)) }
    }

    private static func key(_ rule: ReplacementRule) -> String {
        rule.isRegex ? "r:\(rule.heard)" : "l:\(rule.heard.lowercased())"
    }
}

public enum DictionaryStore {
    public static let currentSchemaVersion = 1
    public static let fileName = "dictionary.toml"

    public static func decode(from toml: String) throws -> DictionarySet {
        try ConfigDecode.table(toml, supportedVersion: currentSchemaVersion) {
            try TOMLDecoder().decode(DictionarySet.self, from: $0)
        }
    }

    public static func unknownKeys(in toml: String) -> [UnknownConfigKey] {
        ConfigKeyCheck.unknownKeys(DictionarySet.self, in: toml, supportedVersion: currentSchemaVersion)
    }

    public static func load(supportDir: URL) -> ConfigLoad<DictionarySet> {
        ConfigLoad.read(supportDir.appendingPathComponent(fileName), decode: decode)
    }

    public static func loadOrDefault(supportDir: URL) -> DictionarySet {
        if case .loaded(let set) = load(supportDir: supportDir) { return set }
        return DictionarySet()
    }

    public static func write(_ set: DictionarySet, to supportDir: URL) throws {
        try writeVocabulary(ConfigEncode.toml(set), fileName: fileName, to: supportDir)
    }
}

public enum ReplacementsStore {
    public static let currentSchemaVersion = 1
    public static let fileName = "replacements.toml"

    public static func decode(from toml: String) throws -> ReplacementsSet {
        try ConfigDecode.table(toml, supportedVersion: currentSchemaVersion) {
            try TOMLDecoder().decode(ReplacementsSet.self, from: $0)
        }
    }

    public static func unknownKeys(in toml: String) -> [UnknownConfigKey] {
        ConfigKeyCheck.unknownKeys(ReplacementsSet.self, in: toml, supportedVersion: currentSchemaVersion)
    }

    public static func load(supportDir: URL) -> ConfigLoad<ReplacementsSet> {
        ConfigLoad.read(supportDir.appendingPathComponent(fileName), decode: decode)
    }

    public static func loadOrDefault(supportDir: URL) -> ReplacementsSet {
        if case .loaded(let set) = load(supportDir: supportDir) { return set }
        return ReplacementsSet()
    }

    public static func write(_ set: ReplacementsSet, to supportDir: URL) throws {
        try writeVocabulary(ConfigEncode.toml(set), fileName: fileName, to: supportDir)
    }
}

private func writeVocabulary(_ toml: String, fileName: String, to supportDir: URL) throws {
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try toml.write(to: supportDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
}
