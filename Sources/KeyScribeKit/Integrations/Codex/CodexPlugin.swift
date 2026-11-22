import Foundation

public enum CodexPlugin {
    public static let hookTimeout = 3
    public static let hooks: [(event: String, matcher: String?)] = [
        ("UserPromptSubmit", nil), ("PermissionRequest", nil), ("PreToolUse", CodexHookReport.askTool), ("Interrupt", nil), ("Stop", nil),
    ]

    public struct Layout: Equatable, Sendable {
        public var plugin: String
        public var marketplace: String
        public var title: String

        public init(plugin: String, marketplace: String, title: String) {
            self.plugin = plugin
            self.marketplace = marketplace
            self.title = title
        }

        public var pluginId: String { "\(plugin)@\(marketplace)" }
        public var pluginFolder: String { "plugins/\(plugin)" }
    }

    public enum Trust: Equatable, Sendable {
        case trusted, needsTrust, absent, unreadable
    }

    public enum Installed: Equatable, Sendable {
        case enabled, disabled, absent
    }

    public static func files(_ layout: Layout, executable: String, installation: String) -> [String: String] {
        let command = "\(ShellWord.quoted(executable)) hook \(ShellWord.quoted(installation))"
        let hookTable = Dictionary(uniqueKeysWithValues: hooks.map { hook -> (String, Any) in
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": hookTimeout]]]
            if let matcher = hook.matcher { group["matcher"] = matcher }
            return (hook.event, [group])
        })
        let manifest: [String: Any] = [
            "name": layout.plugin, "version": "1.0.0", "description": "Reports Codex turns to \(layout.title).", "mcpServers": "./.mcp.json",
            "hooks": ["hooks": hookTable], "interface": ["displayName": layout.title],
        ]
        let mcp: [String: Any] = [
            "mcpServers": ["read-aloud": ["command": executable, "args": ["mcp", installation], "default_tools_approval_mode": "approve"]],
        ]
        let marketplace: [String: Any] = [
            "name": layout.marketplace, "interface": ["displayName": layout.title],
            "plugins": [[
                "name": layout.plugin, "source": ["source": "local", "path": "./\(layout.pluginFolder)"],
                "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"], "category": "Productivity",
            ]],
        ]
        return [
            ".agents/plugins/marketplace.json": json(marketplace), "\(layout.pluginFolder)/.codex-plugin/plugin.json": json(manifest),
            "\(layout.pluginFolder)/.mcp.json": json(mcp),
        ]
    }

    public static func forgettingTrust(in config: String, pluginId: String) -> String {
        var bytes = Array(config.utf8)
        guard let scan = CodexTOMLScan(bytes) else { return config }
        let ours = { (path: [String]) in path.count >= 3 && path[0] == "hooks" && path[1] == "state" && path[2].hasPrefix(pluginId + ":") }
        let removals = scan.headers.indices.filter { ours(scan.headers[$0].path) }.map { index in
            let header = scan.headers[index]
            let end = scan.entries.filter { $0.section == index }.map(\.lineEnd).max() ?? header.lineEnd
            return header.lineStart..<blankLinesSkipped(from: end, in: bytes)
        }
        guard !removals.isEmpty else { return config }
        for range in removals.reversed() { bytes.removeSubrange(range) }
        guard let after = CodexTOMLScan(bytes), shape(of: after, without: ours) == shape(of: scan, without: ours) else { return config }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func blankLinesSkipped(from start: Int, in bytes: [UInt8]) -> Int {
        var position = start
        while position < bytes.count {
            var cursor = position
            while cursor < bytes.count, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r")].contains(bytes[cursor]) { cursor += 1 }
            guard cursor == bytes.count || bytes[cursor] == UInt8(ascii: "\n") else { return position }
            position = min(cursor + 1, bytes.count)
        }
        return position
    }

    private static func shape(of scan: CodexTOMLScan, without ours: ([String]) -> Bool) -> [[String]] {
        let headers = scan.headers.filter { !ours($0.path) }.map { ["table"] + $0.path }
        let entries = scan.entries.compactMap { entry -> [String]? in
            let section = entry.section.map { scan.headers[$0].path } ?? []
            guard !ours(section) else { return nil }
            let value = scan.tokens[entry.valueToken]
            return ["entry"] + section + ["="] + entry.path + [String(decoding: scan.bytes[value.start..<entry.lineEnd], as: UTF8.self)]
        }
        return headers + entries
    }

    public static func trust(_ result: Data, pluginId: String) -> Trust {
        guard let entries = CodexJSON.object(result)?["data"] as? [[String: Any]] else { return .unreadable }
        let ours = entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.filter { $0["pluginId"] as? String == pluginId }
        guard !ours.isEmpty else { return .absent }
        let states = ours.map { $0["trustStatus"] as? String }
        guard states.allSatisfy({ ["trusted", "managed", "untrusted", "modified"].contains($0 ?? "") }) else { return .unreadable }
        return states.allSatisfy { $0 == "trusted" || $0 == "managed" } ? .trusted : .needsTrust
    }

    public static func installed(_ listing: Data, pluginId: String, path: String) -> Installed? {
        guard let installed = CodexJSON.object(listing)?["installed"] as? [[String: Any]] else { return nil }
        guard let plugin = installed.first(where: { $0["pluginId"] as? String == pluginId }),
              (plugin["source"] as? [String: Any])?["path"] as? String == path
        else { return .absent }
        return CodexJSON.bool(plugin["enabled"]) == false ? .disabled : .enabled
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
