import Foundation
import KeyScribeKit

struct AgentNameStore {
    static let fileName = "names.json"
    static let schemaVersion = 1

    enum Loaded: Equatable {
        case names([String: String], remembered: [String: RememberedName] = [:])
        case unavailable(String)
    }

    private struct File: Codable {
        var schemaVersion: Int
        var names: [String: String]
        var remembered: [String: RememberedName]?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case names, remembered
        }
    }

    let directory: URL

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
        return .names(file.names, remembered: file.remembered ?? [:])
    }

    func save(_ names: [String: String], remembered: [String: RememberedName]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(schemaVersion: Self.schemaVersion, names: names, remembered: remembered.isEmpty ? nil : remembered)).write(to: url, options: .atomic)
    }
}
