import Foundation

public typealias ClaudeConnectorStatus = AgentConnectorStatus

extension AgentConnectorStatus {
    private struct ClaudePlugin: Decodable {
        var id: String
        var version: String?
        var enabled: Bool?
        var scope: String?
    }

    public static func parse(pluginList: Data, pluginId: String, bundledVersion: String) -> AgentConnectorStatus {
        guard let entries = try? JSONDecoder().decode([ClaudePlugin].self, from: pluginList) else { return .unknown }
        guard let entry = entries.first(where: { $0.id == pluginId && $0.scope == "user" }) else { return .notInstalled }
        if entry.enabled == false { return .disabled }
        guard let version = entry.version, version == bundledVersion else { return .outdated(installed: entry.version ?? "") }
        return .ready
    }
}
