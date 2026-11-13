import CryptoKit
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
    let setupFolder: URL
    let isDefaultSetup: Bool
    let pluginName: String
    let claude: String
    let socketPath: String
    let tokenPath: String
    let readyPath: String
    let script: String
    let surfaces: ConnectorSurfaces
    let run: @Sendable ([String], [String: String]) -> (Int32, String)
    var baseEnvironment: [String: String] = ProcessInfo.processInfo.environment

    static let setupVariable = "CLAUDE_CONFIG_DIR"

    static func defaultSetupFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude", isDirectory: true)
    }

    static func environment(for setupFolder: URL, isDefault: Bool, base: [String: String]) -> [String: String] {
        var environment = base
        environment[setupVariable] = isDefault ? nil : setupFolder.path
        return environment
    }

    var environment: [String: String] { Self.environment(for: setupFolder, isDefault: isDefaultSetup, base: baseEnvironment) }

    var marketplaceName: String { "\(pluginName)-local" }
    var marketplaceDir: URL { Self.marketplaceDir(in: agentsDir, setupFolder: setupFolder) }

    static func marketplaceDir(in agentsDir: URL, setupFolder: URL) -> URL {
        let key = SHA256.hash(data: Data(setupFolder.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return agentsDir.appendingPathComponent("claude-connector", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    static func manualUninstall(
        pluginName: String, setupFolder: URL, isDefault: Bool, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        let prefix = isDefault ? "env -u \(setupVariable) " : "\(setupVariable)=\(ShellWord.path(setupFolder.path, home: home)) "
        return [
            "\(prefix)claude plugin uninstall \(pluginName)@\(pluginName)-local --scope user",
            "\(prefix)claude plugin marketplace remove \(pluginName)-local",
        ]
    }

    private var pluginId: String { "\(pluginName)@\(marketplaceName)" }

    static func pluginName(for variant: AppVariant) -> String { variant.connectorSlug }

    func install(installation: String) throws {
        try writeFiles(installation: installation)
        try claudeCommand(["plugin", "marketplace", "add", marketplaceDir.path])
        try claudeCommand(["plugin", "install", pluginId, "--scope", "user"])
    }

    func update(installation: String) throws {
        try writeFiles(installation: installation)
        try claudeCommand(["plugin", "marketplace", "update", marketplaceName])
        try claudeCommand(["plugin", "update", pluginId, "--scope", "user"])
    }

    func uninstall() throws {
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
        let (status, output) = run(argv, environment)
        guard status == 0,
              let entries = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        else { throw InstallError(command: argv, status: status, output: output) }
        return Set(entries.compactMap(name))
    }

    private func claudeCommand(_ args: [String]) throws {
        let argv = [claude] + args
        let (status, output) = run(argv, environment)
        guard status == 0 else { throw InstallError(command: argv, status: status, output: output) }
    }

    private func writeFiles(installation: String) throws {
        let plugin = marketplaceDir.appendingPathComponent(pluginName, isDirectory: true)
        let files: [(URL, String)] = [
            (marketplaceDir.appendingPathComponent(".claude-plugin/marketplace.json"), ClaudeConnectorFiles.marketplaceJSON(name: marketplaceName, plugin: pluginName)),
            (plugin.appendingPathComponent(".claude-plugin/plugin.json"), ClaudeConnectorFiles.pluginJSON(name: pluginName, version: ClaudeConnectorFiles.version(for: script, surfaces: surfaces))),
            (plugin.appendingPathComponent("hooks/hooks.json"), ClaudeConnectorFiles.hooksJSON),
            (plugin.appendingPathComponent("hooks/register.js"), try ClaudeConnectorFiles.installedScript(script, installation: installation, surfaces: surfaces)),
            (plugin.appendingPathComponent("keyscribe.json"), ClaudeConnectorFiles.configJSON(
                socketPath: socketPath, tokenPath: tokenPath, readyPath: readyPath, installation: installation,
                version: ClaudeConnectorFiles.version(for: script, surfaces: surfaces), surfaces: surfaces)),
        ]
        for (url, text) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }
}

enum ClaudeConnectorFiles {
    static let registerJS: String? = ConnectorResources.text(named: "register", extension: "js")

    static func script(searching bundles: [URL]) -> String? {
        ConnectorResources.text(named: "register", extension: "js", searching: bundles)
    }

    static func version(for script: String, surfaces: ConnectorSurfaces) -> String {
        ConnectorResources.version(for: script + "\n" + surfaces.fingerprint)
    }

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

    struct ReaderMissing: LocalizedError {
        var errorDescription: String? { "This copy of \(Branding.appName) has a damaged Claude Code connector, so it was not installed." }
    }

    static func installedScript(_ script: String, installation: String, surfaces: ConnectorSurfaces) throws -> String {
        try reading(surfaces.environmentKeys, in: script)
            .replacingOccurrences(of: "let loadedFrom = null", with: "let loadedFrom = \"\(installation)\"")
            .replacingOccurrences(of: "const appLabel = null", with: "const appLabel = \(literal(Branding.appName))")
    }

    private static let readerStart = "async function readEnvironment($) {\n"
    private static let readerEnd = "    return {}\n  }\n}\n"

    static func environmentReader(_ keys: [String]) -> String {
        let keys = keys.filter(AgentSurfaces.isPlainName)
        return readerStart
            + "  const keys = [\(keys.map { "\"\($0)\"" }.joined(separator: ", "))]\n"
            + "  try {\n"
            + "    const reads = await Promise.all([\n"
            + keys.map { "      $.env.get(\"\($0)\").catch(() => undefined),\n" }.joined()
            + "    ])\n"
            + "    return Object.fromEntries(keys.map((key, index) => [key, reads[index]]))\n"
            + "  } catch (err) {\n"
            + readerEnd
    }

    static func packagedReader(in script: String) -> String? {
        guard let start = script.range(of: readerStart), let end = script.range(of: readerEnd, range: start.upperBound..<script.endIndex)
        else { return nil }
        return String(script[start.lowerBound..<end.upperBound])
    }

    private static func reading(_ keys: [String], in script: String) throws -> String {
        guard let packaged = packagedReader(in: script) else { throw ReaderMissing() }
        return script.replacingOccurrences(of: packaged, with: environmentReader(keys))
    }

    private static func literal(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static let hooksJSON = json(["description": "Voice connector", "modules": ["./register.js"]])

    static func configJSON(
        socketPath: String, tokenPath: String, readyPath: String, installation: String, version: String, surfaces: ConnectorSurfaces
    ) -> String {
        json([
            "protocol": AgentBridgeCodec.protocolVersion, "socketPath": socketPath, "tokenPath": tokenPath, "readyPath": readyPath,
            "installation": installation, "version": version,
        ].merging(surfaces.configFields) { own, _ in own })
    }
}
