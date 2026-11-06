import Foundation

enum AgentInstallationRecord {
    static func file(for agent: String) -> String { "\(agent)-installation.json" }

    static func current(agent: String, in agentsDir: URL) -> String? {
        guard let record = read(agent: agent, in: agentsDir) else { return nil }
        return record["installation"] as? String
    }

    static func wasRemoved(agent: String, in agentsDir: URL) -> Bool {
        guard let record = read(agent: agent, in: agentsDir) else { return false }
        return record["installation"] is NSNull
    }

    static func disable(agent: String, in agentsDir: URL) throws {
        try record(installation: nil, agent: agent, in: agentsDir)
    }

    static func record(installation: String?, agent: String, in agentsDir: URL) throws {
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let body = try JSONSerialization.data(withJSONObject: ["installation": installation.map { $0 as Any } ?? NSNull()], options: [.sortedKeys])
        try body.write(to: agentsDir.appendingPathComponent(file(for: agent)), options: .atomic)
    }

    private static func read(agent: String, in agentsDir: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: agentsDir.appendingPathComponent(file(for: agent)).path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
