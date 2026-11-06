import Foundation
import KeyScribeKit
import Security

enum AgentBridgeToken {
    static func loadOrCreate(in dir: URL) throws -> String {
        let url = dir.appendingPathComponent("token")
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        guard FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }
}

struct ClaudeConnectorInstaller {
    struct InstallError: Error, Equatable {
        var command: [String]
        var status: Int32
        var output: String
    }

    let agentsDir: URL
    let pluginName: String
    let claude: String
    let socketPath: String
    let tokenPath: String
    let readyPath: String
    let script: String
    let run: ([String]) -> (Int32, String)

    static let installationFile = AgentInstallationRecord.file(for: AgentKind.claude.id)

    static func currentInstallation(in agentsDir: URL) -> String? {
        AgentInstallationRecord.current(agent: AgentKind.claude.id, in: agentsDir)
    }

    var marketplaceName: String { "\(pluginName)-local" }
    var marketplaceDir: URL { Self.marketplaceDir(in: agentsDir) }

    static func marketplaceDir(in agentsDir: URL) -> URL {
        agentsDir.appendingPathComponent("claude-connector", isDirectory: true)
    }

    static func manualUninstall(pluginName: String) -> [String] {
        [
            "claude plugin uninstall \(pluginName)@\(pluginName)-local --scope user",
            "claude plugin marketplace remove \(pluginName)-local",
        ]
    }
    private var pluginId: String { "\(pluginName)@\(marketplaceName)" }

    static func pluginName(for variant: AppVariant) -> String { variant.connectorSlug }

    func install() throws {
        try writeFiles(installation: UUID().uuidString)
        try claudeCommand(["plugin", "marketplace", "add", marketplaceDir.path])
        try claudeCommand(["plugin", "install", pluginId, "--scope", "user"])
    }

    func update() throws {
        try writeFiles(installation: Self.currentInstallation(in: agentsDir) ?? UUID().uuidString)
        try claudeCommand(["plugin", "marketplace", "update", marketplaceName])
        try claudeCommand(["plugin", "update", pluginId])
    }

    static func wasRemoved(in agentsDir: URL) -> Bool {
        AgentInstallationRecord.wasRemoved(agent: AgentKind.claude.id, in: agentsDir)
    }

    static func disable(in agentsDir: URL) throws {
        try AgentInstallationRecord.disable(agent: AgentKind.claude.id, in: agentsDir)
    }

    func uninstall() throws {
        try Self.disable(in: agentsDir)
        let failures = [
            attempt(["plugin", "uninstall", pluginId, "--scope", "user"]),
            attempt(["plugin", "marketplace", "remove", marketplaceName]),
        ].compactMap { $0 }
        let plugins = try listed(["plugin", "list", "--json"]) { $0["scope"] as? String == "user" ? $0["id"] as? String : nil }
        let marketplaces = try listed(["plugin", "marketplace", "list", "--json"]) { $0["name"] as? String }
        let leftOver = [pluginId, marketplaceName].filter { plugins.contains($0) || marketplaces.contains($0) }
        guard leftOver.isEmpty else {
            throw failures.first ?? InstallError(
                command: [claude, "plugin", "marketplace", "list", "--json"], status: 0,
                output: "Claude Code still lists \(leftOver.joined(separator: " and ")).")
        }
        try? FileManager.default.removeItem(at: marketplaceDir)
    }

    private func attempt(_ args: [String]) -> InstallError? {
        do {
            try claudeCommand(args)
            return nil
        } catch {
            return error as? InstallError
        }
    }

    private func listed(_ args: [String], _ name: ([String: Any]) -> String?) throws -> Set<String> {
        let argv = [claude] + args
        let (status, output) = run(argv)
        guard status == 0,
              let entries = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        else { throw InstallError(command: argv, status: status, output: output) }
        return Set(entries.compactMap(name))
    }

    private func claudeCommand(_ args: [String]) throws {
        let argv = [claude] + args
        let (status, output) = run(argv)
        guard status == 0 else { throw InstallError(command: argv, status: status, output: output) }
    }

    private func writeFiles(installation: String) throws {
        try AgentInstallationRecord.record(installation: installation, agent: AgentKind.claude.id, in: agentsDir)
        let plugin = marketplaceDir.appendingPathComponent(pluginName, isDirectory: true)
        let files: [(URL, String)] = [
            (marketplaceDir.appendingPathComponent(".claude-plugin/marketplace.json"), ClaudeConnectorFiles.marketplaceJSON(name: marketplaceName, plugin: pluginName)),
            (plugin.appendingPathComponent(".claude-plugin/plugin.json"), ClaudeConnectorFiles.pluginJSON(name: pluginName, version: ClaudeConnectorFiles.version(for: script))),
            (plugin.appendingPathComponent("hooks/hooks.json"), ClaudeConnectorFiles.hooksJSON),
            (plugin.appendingPathComponent("hooks/register.js"), ClaudeConnectorFiles.installedScript(script, installation: installation)),
            (plugin.appendingPathComponent("keyscribe.json"), ClaudeConnectorFiles.configJSON(socketPath: socketPath, tokenPath: tokenPath, readyPath: readyPath, installation: installation)),
        ]
        for (url, text) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }
}

enum ClaudeConnectorFiles {
    static let registerJS: String? = ConnectorResources.text(named: "register", extension: "js")
    static let version: String? = registerJS.map(version(for:))

    static func script(searching bundles: [URL]) -> String? {
        ConnectorResources.text(named: "register", extension: "js", searching: bundles)
    }

    static func version(for script: String) -> String { ConnectorResources.version(for: script) }

    static func json(_ object: [String: Any]) -> String { ConnectorResources.json(object) }

    static func marketplaceJSON(name: String, plugin: String) -> String {
        json([
            "name": name,
            "description": "\(Branding.appName) voice connector for Claude Code",
            "owner": ["name": Branding.appName],
            "plugins": [["name": plugin, "source": "./\(plugin)", "description": "Lets \(Branding.appName) send what you say to this session."]],
        ])
    }

    static func pluginJSON(name: String, version: String) -> String {
        json([
            "name": name,
            "version": version,
            "description": "Lets \(Branding.appName) send what you say to this Claude Code session.",
            "author": ["name": Branding.appName],
        ])
    }

    static func installedScript(_ script: String, installation: String) -> String {
        script.replacingOccurrences(of: "let loadedFrom = null", with: "let loadedFrom = \"\(installation)\"")
    }

    static let hooksJSON = json(["description": "Voice connector", "modules": ["./register.js"]])

    static func configJSON(socketPath: String, tokenPath: String, readyPath: String, installation: String) -> String {
        json([
            "protocol": AgentBridgeCodec.protocolVersion, "socketPath": socketPath, "tokenPath": tokenPath, "readyPath": readyPath,
            "installation": installation,
        ])
    }
}
