import Foundation
import TOMLKit

// A named set of words and replacements that the modes listing it in `shared_vocabularies` use: between Global
// and a mode's own vocabulary (mode-only overrides shared, shared overrides Global). One file per vocabulary
// under `vocabularies/`, its id the file name, so a rename keeps every mode's reference.
public struct SharedVocabulary: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var words: [String]
    public var rules: [ReplacementsSet.Rule]

    public init(
        id: String, name: String, words: [String] = [], rules: [ReplacementsSet.Rule] = [],
        schemaVersion: Int = SharedVocabularyStore.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.words = words
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name, words, rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = ""
        name = try c.decode(String.self, forKey: .name)
        words = try c.decodeIfPresent([String].self, forKey: .words) ?? []
        rules = try c.decodeIfPresent([ReplacementsSet.Rule].self, forKey: .rules) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(name, forKey: .name)
        try c.encode(words, forKey: .words)
        try c.encode(rules, forKey: .rules)
    }

    public var replacementRules: [ReplacementRule] { rules.toReplacementRules().map { $0.from(.shared(id)) } }
}

public enum SharedVocabularyStore {
    public static let currentSchemaVersion = 1
    public static let directoryName = "vocabularies"

    public struct LoadFailure: Equatable, Sendable {
        public let id: String
        public let error: ConfigError
    }

    public struct LoadResult: Sendable {
        public let vocabularies: [SharedVocabulary]
        public let failures: [LoadFailure]
    }

    public static func directory(in supportDir: URL) -> URL {
        supportDir.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func decode(from toml: String, id: String) throws -> SharedVocabulary {
        var vocabulary = try ConfigDecode.table(toml, supportedVersion: currentSchemaVersion) { table in
            try TOMLDecoder().decode(SharedVocabulary.self, from: table)
        }
        vocabulary.id = id
        return vocabulary
    }

    public static func unknownKeys(in toml: String) -> [UnknownConfigKey] {
        ConfigKeyCheck.unknownKeys(SharedVocabulary.self, in: toml, supportedVersion: currentSchemaVersion)
    }

    public static func load(in dir: URL) -> LoadResult {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return LoadResult(vocabularies: [], failures: [])
        }
        var vocabularies: [SharedVocabulary] = []
        var failures: [LoadFailure] = []
        for url in files.filter({ $0.pathExtension == "toml" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = url.deletingPathExtension().lastPathComponent
            do {
                let toml: String
                do { toml = try String(contentsOf: url, encoding: .utf8) }
                catch { throw ConfigError.unreadableFile(error.localizedDescription) }
                vocabularies.append(try decode(from: toml, id: id))
            } catch {
                failures.append(LoadFailure(id: id, error: (error as? ConfigError) ?? .invalid("\(error)")))
            }
        }
        return LoadResult(vocabularies: vocabularies, failures: failures)
    }

    public static func write(_ vocabulary: SharedVocabulary, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ConfigEncode.toml(vocabulary).write(to: fileURL(id: vocabulary.id, in: dir), atomically: true, encoding: .utf8)
    }

    public static func delete(id: String, from dir: URL) throws {
        try FileManager.default.removeItem(at: fileURL(id: id, in: dir))
    }

    public static func fileURL(id: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(id).toml")
    }

    public static func nameProblem(_ name: String, among existing: [SharedVocabulary], renaming id: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a name." }
        if trimmed.caseInsensitiveCompare("Global") == .orderedSame {
            return "\u{201C}Global\u{201D} is the vocabulary every mode can use. Choose another name."
        }
        if let taken = existing.first(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "A shared vocabulary is already named \u{201C}\(taken.name)\u{201D}."
        }
        return nil
    }

    // A file name from the name, never one already in use.
    public static func newId(for name: String, existing: Set<String>) -> String {
        let slug = name.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.joined(separator: "-")
        let base = slug.isEmpty ? "vocabulary" : slug
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
