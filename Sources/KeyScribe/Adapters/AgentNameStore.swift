import Foundation
import KeyScribeKit

struct AgentNameStore {
    static let fileName = "names.json"
    static let schemaVersion = 1

    struct Chosen: Codable, Equatable {
        var id: String
        var name: String?
    }

    enum Loaded: Equatable {
        case names([String: String], remembered: [String: RememberedName] = [:], excluded: Set<String> = [], chosen: Chosen? = nil)
        case unavailable(String)
    }

    private struct File: Codable {
        var schemaVersion: Int
        var names: [String: String]
        var remembered: [String: RememberedName]?
        var excluded: [String]?
        var chosen: Chosen?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case names, remembered, excluded, chosen
        }
    }

    let directory: URL
    var legacyAgent = ""

    var url: URL { directory.appendingPathComponent(Self.fileName) }

    func load() -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .names([:]) }
        guard let data = try? Data(contentsOf: url) else { return .unavailable("\(Self.fileName) could not be opened.") }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            return .unavailable("\(Self.fileName) is not in a form \(Branding.appName) can read.")
        }
        guard file.schemaVersion <= Self.schemaVersion else {
            return .unavailable("\(Self.fileName) was saved by a newer version of \(Branding.appName).")
        }
        let migrated: (String) -> String = { key in
            AgentSessionID.split(key) == nil && !self.legacyAgent.isEmpty ? AgentSessionID.make(agent: self.legacyAgent, native: key) : key
        }
        let names = Dictionary(file.names.map { (migrated($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        let remembered = Dictionary((file.remembered ?? [:]).map { key, saved in
            var named = saved
            if named.agent.isEmpty { named.agent = AgentSessionID.agent(of: key) ?? legacyAgent }
            return (migrated(key), named)
        }, uniquingKeysWith: { first, _ in first })
        let chosen = file.chosen.map { Chosen(id: migrated($0.id), name: $0.name) }
        return .names(names, remembered: remembered, excluded: Set((file.excluded ?? []).map(migrated)), chosen: chosen)
    }

    func save(_ names: [String: String], remembered: [String: RememberedName], excluded: Set<String> = [], chosen: Chosen?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = File(
            schemaVersion: Self.schemaVersion, names: names, remembered: remembered.isEmpty ? nil : remembered,
            excluded: excluded.isEmpty ? nil : excluded.sorted(), chosen: chosen)
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}
