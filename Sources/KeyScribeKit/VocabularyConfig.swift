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

    // Correction surface (design.md §4.7): add a term, ignoring blanks and case-insensitive dups.
    public func adding(word: String) -> DictionarySet {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !words.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return self }
        var copy = self
        copy.words.append(trimmed)
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
        public init(heard: String, replace: String, regex: Bool) {
            self.heard = heard
            self.replace = replace
            self.regex = regex
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            heard = try c.decode(String.self, forKey: .heard)
            replace = try c.decode(String.self, forKey: .replace)
            regex = try c.decodeIfPresent(Bool.self, forKey: .regex) ?? false
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

    // Correction surface (design.md §4.7): add a literal heard→replace rule, ignoring blanks and
    // case-insensitive duplicates of an existing literal rule's `heard`.
    public func addingLiteral(heard: String, replace: String) -> ReplacementsSet {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty,
              !rules.contains(where: { !$0.regex && $0.heard.caseInsensitiveCompare(h) == .orderedSame })
        else { return self }
        var copy = self
        copy.rules.append(Rule(heard: h, replace: replace, regex: false))
        return copy
    }

    // The regex-rule counterpart: dedup by `heard` (case-sensitive — regex patterns are), keyed like
    // VocabularyMerge so a repeated correction-panel add can't accumulate identical rules that all run
    // per dictation. First-write-wins, mirroring addingLiteral.
    public func addingRegex(heard: String, replace: String) -> ReplacementsSet {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty,
              !rules.contains(where: { $0.regex && $0.heard == h })
        else { return self }
        var copy = self
        copy.rules.append(Rule(heard: h, replace: replace, regex: true))
        return copy
    }

    public func adding(heard: String, replace: String, regex: Bool) -> ReplacementsSet {
        regex ? addingRegex(heard: heard, replace: replace) : addingLiteral(heard: heard, replace: replace)
    }
}

extension [ReplacementsSet.Rule] {
    public func toReplacementRules() -> [ReplacementRule] {
        map { ReplacementRule(heard: $0.heard, replace: $0.replace, isRegex: $0.regex) }
    }
}

public enum VocabularyMerge {
    public static func words(global: [String], local: [String], includeGlobal: Bool) -> [String] {
        let combined = includeGlobal ? global + local : local
        var seen = Set<String>()
        return combined.filter { seen.insert($0).inserted }
    }

    public static func rules(
        global: [ReplacementRule], local: [ReplacementRule], includeGlobal: Bool
    ) -> [ReplacementRule] {
        guard includeGlobal else { return local }
        let overridden = Set(local.map(key))
        return global.filter { !overridden.contains(key($0)) } + local
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

    public static func load(supportDir: URL) -> ConfigLoad<DictionarySet> {
        ConfigLoad.read(supportDir.appendingPathComponent(fileName), decode: decode)
    }

    public static func loadOrDefault(supportDir: URL) -> DictionarySet {
        if case .loaded(let set) = load(supportDir: supportDir) { return set }
        return DictionarySet()
    }

    public static func write(_ set: DictionarySet, to supportDir: URL) throws {
        try writeVocabulary(TOMLEncoder().encode(set), fileName: fileName, to: supportDir)
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

    public static func load(supportDir: URL) -> ConfigLoad<ReplacementsSet> {
        ConfigLoad.read(supportDir.appendingPathComponent(fileName), decode: decode)
    }

    public static func loadOrDefault(supportDir: URL) -> ReplacementsSet {
        if case .loaded(let set) = load(supportDir: supportDir) { return set }
        return ReplacementsSet()
    }

    public static func write(_ set: ReplacementsSet, to supportDir: URL) throws {
        try writeVocabulary(TOMLEncoder().encode(set), fileName: fileName, to: supportDir)
    }
}

private func writeVocabulary(_ toml: String, fileName: String, to supportDir: URL) throws {
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try toml.write(to: supportDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
}
