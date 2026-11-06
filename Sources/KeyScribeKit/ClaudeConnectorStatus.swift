import Foundation

public enum ClaudeConnectorStatus: Equatable, Sendable {
    case notInstalled
    case ready
    case outdated(installed: String)
    case disabled
    case unknown

    private struct Entry: Decodable {
        var id: String
        var version: String?
        var enabled: Bool?
        var scope: String?
    }

    public static func parse(pluginList: Data, pluginId: String, bundledVersion: String) -> ClaudeConnectorStatus {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: pluginList) else { return .unknown }
        guard let entry = entries.first(where: { $0.id == pluginId && $0.scope == "user" }) else { return .notInstalled }
        if entry.enabled == false { return .disabled }
        guard let version = entry.version, version == bundledVersion else { return .outdated(installed: entry.version ?? "") }
        return .ready
    }
}
