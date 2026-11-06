import Foundation
import KeyScribeKit

enum PiCLI {
    static let minimumVersion = [1, 4, 0]

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        listing: (URL) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
    ) -> String? {
        let nodeVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nvm = listing(nodeVersions).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nodeVersions.appendingPathComponent($0).appendingPathComponent("bin").path }
        let managers = [".volta/bin", ".bun/bin", ".npm-global/bin"].map { home.appendingPathComponent($0).path }
        return ToolCLI.locate(named: "pi", environment: environment, home: home, alsoIn: nvm + managers, isExecutable: isExecutable)
    }

    static func run(_ argv: [String], timeout: TimeInterval = 30, environment: [String: String] = ProcessInfo.processInfo.environment) -> (Int32, String) {
        var environment = environment
        if let program = argv.first {
            let bin = (program as NSString).deletingLastPathComponent
            environment["PATH"] = ([bin] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        }
        return ToolCLI.run(argv, timeout: timeout, environment: environment)
    }

    static func version(in output: String) -> [Int]? {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            guard let word = words.last, words.count == 1 || (words.count == 2 && words[0] == "pi") else { continue }
            let numeric = word.hasPrefix("v") ? word.dropFirst() : word
            let core = numeric.prefix { $0.isNumber || $0 == "." }
            guard !core.isEmpty, core.endIndex == numeric.endIndex || numeric[core.endIndex] == "-" else { continue }
            let parts = core.split(separator: ".").map { Int($0) }
            guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { continue }
            var version = parts.compactMap { $0 }
            while version.count < minimumVersion.count { version.append(0) }
            return version
        }
        return nil
    }

    static func isSupported(_ version: [Int]) -> Bool {
        version.lexicographicallyPrecedes(minimumVersion) == false
    }

    static func describe(_ version: [Int]) -> String { version.map(String.init).joined(separator: ".") }
}

struct PiConnectorInstaller {
    let extensionsDir: URL
    let agentsDir: URL
    let pluginName: String
    let socketPath: String
    let tokenPath: String
    let readyPath: String
    let script: String

    static let installationFile = AgentInstallationRecord.file(for: AgentKind.pi.id)

    static func defaultExtensionsDir(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let agentDir = environment["PI_CODING_AGENT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".pi/agent", isDirectory: true)
        return agentDir.appendingPathComponent("extensions", isDirectory: true)
    }

    static func pluginDir(in extensionsDir: URL, pluginName: String) -> URL {
        extensionsDir.appendingPathComponent(pluginName, isDirectory: true)
    }

    var pluginDir: URL { Self.pluginDir(in: extensionsDir, pluginName: pluginName) }
    var scriptURL: URL { pluginDir.appendingPathComponent("index.ts") }
    var configURL: URL { pluginDir.appendingPathComponent("keyscribe.json") }

    static func currentInstallation(in agentsDir: URL) -> String? {
        AgentInstallationRecord.current(agent: AgentKind.pi.id, in: agentsDir)
    }

    static func wasRemoved(in agentsDir: URL) -> Bool {
        AgentInstallationRecord.wasRemoved(agent: AgentKind.pi.id, in: agentsDir)
    }

    static func disable(in agentsDir: URL) throws {
        try AgentInstallationRecord.disable(agent: AgentKind.pi.id, in: agentsDir)
    }

    static func manualUninstall(pluginDir: URL) -> [String] {
        ["rm -r \((pluginDir.path as NSString).abbreviatingWithTildeInPath)"]
    }

    func install() throws {
        try writeFiles(installation: UUID().uuidString)
    }

    func update() throws {
        try writeFiles(installation: Self.currentInstallation(in: agentsDir) ?? UUID().uuidString)
    }

    func uninstall() throws {
        try Self.disable(in: agentsDir)
        guard FileManager.default.fileExists(atPath: pluginDir.path) else { return }
        try FileManager.default.removeItem(at: pluginDir)
    }

    enum Installed: Equatable {
        case absent
        case current
        case other(version: String)
    }

    func installed() -> Installed {
        guard FileManager.default.fileExists(atPath: scriptURL.path), let data = FileManager.default.contents(atPath: configURL.path),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .absent }
        let version = config["version"] as? String ?? ""
        guard version == PiConnectorFiles.version(for: script), config["installation"] as? String == Self.currentInstallation(in: agentsDir),
              (try? String(contentsOf: scriptURL, encoding: .utf8)) == PiConnectorFiles.installedScript(script, installation: config["installation"] as? String ?? "", configPath: configURL.path)
        else { return .other(version: version) }
        return .current
    }

    private func writeFiles(installation: String) throws {
        try AgentInstallationRecord.record(installation: installation, agent: AgentKind.pi.id, in: agentsDir)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let files: [(URL, String)] = [
            (scriptURL, PiConnectorFiles.installedScript(script, installation: installation, configPath: configURL.path)),
            (configURL, PiConnectorFiles.configJSON(
                socketPath: socketPath, tokenPath: tokenPath, readyPath: readyPath, installation: installation, plugin: pluginName,
                version: PiConnectorFiles.version(for: script))),
        ]
        for (url, text) in files {
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }
}

enum PiConnectorFiles {
    static let indexTS: String? = ConnectorResources.text(named: "index", extension: "ts")
    static let version: String? = indexTS.map(version(for:))

    static func version(for script: String) -> String { ConnectorResources.version(for: script) }

    static func installedScript(_ script: String, installation: String, configPath: String) -> String {
        script
            .replacingOccurrences(of: "const configPath: string | null = null", with: "const configPath: string | null = \(quoted(configPath))")
            .replacingOccurrences(of: "const loadedFrom: string | null = null", with: "const loadedFrom: string | null = \(quoted(installation))")
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func configJSON(socketPath: String, tokenPath: String, readyPath: String, installation: String, plugin: String, version: String) -> String {
        ConnectorResources.json([
            "protocol": AgentBridgeCodec.protocolVersion, "socketPath": socketPath, "tokenPath": tokenPath, "readyPath": readyPath,
            "installation": installation, "plugin": plugin, "version": version,
            "environmentKeys": TerminalRoutes.environmentKeys.sorted(),
        ])
    }
}

@MainActor
final class PiConnector: AgentConnector {
    let kind = AgentKind.pi
    private let locate: () -> String?
    private let run: @Sendable ([String]) -> (Int32, String)
    private let agentsDir: URL
    private let extensionsDir: URL
    private let pluginName: String
    private let script: String?

    init(
        locate: @escaping () -> String? = { PiCLI.locate() },
        run: @escaping @Sendable ([String]) -> (Int32, String) = { PiCLI.run($0) },
        agentsDir: URL, extensionsDir: URL = PiConnectorInstaller.defaultExtensionsDir(), pluginName: String,
        script: String? = PiConnectorFiles.indexTS
    ) {
        self.locate = locate
        self.run = run
        self.agentsDir = agentsDir
        self.extensionsDir = extensionsDir
        self.pluginName = pluginName
        self.script = script
    }

    private var pluginDir: URL { PiConnectorInstaller.pluginDir(in: extensionsDir, pluginName: pluginName) }
    private var knownVersion: (tool: String, modified: Date?, version: [Int])?
    var isBundled: Bool { script != nil }
    var hasFiles: Bool { FileManager.default.fileExists(atPath: pluginDir.path) }
    var wasRemoved: Bool { PiConnectorInstaller.wasRemoved(in: agentsDir) }
    var manualUninstall: [String] { PiConnectorInstaller.manualUninstall(pluginDir: pluginDir) }

    func locateTool() -> String? { locate() }

    func check(tool: String) async -> AgentConnectorModel.State {
        guard let installer = installer() else { return .unavailable }
        let modified = (try? FileManager.default.attributesOfItem(atPath: tool))?[.modificationDate] as? Date
        let version: [Int]
        if let known = knownVersion, known.tool == tool, known.modified == modified {
            version = known.version
        } else {
            let run = run
            let (status, output) = await Task.detached { run([tool, "--version"]) }.value
            guard status == 0, let found = PiCLI.version(in: output) else {
                return .failed(Self.trimmed(output.isEmpty ? "pi --version did not answer." : output))
            }
            version = found
            knownVersion = (tool, modified, found)
        }
        guard PiCLI.isSupported(version) else { return .toolTooOld(PiCLI.describe(version)) }
        let installed = await Task.detached { installer.installed() }.value
        if installed != .absent, wasRemoved { return .removalUnfinished(nil) }
        switch installed {
        case .absent: return .status(.notInstalled)
        case .current: return .status(.ready)
        case .other(let version): return .status(.outdated(installed: version))
        }
    }

    func install(tool: String) async throws { try await perform { try $0.install() } }
    func update(tool: String) async throws { try await perform { try $0.update() } }
    func uninstall(tool: String) async throws { try await perform { try $0.uninstall() } }
    func disable() throws { try PiConnectorInstaller.disable(in: agentsDir) }

    private func installer() -> PiConnectorInstaller? {
        guard let script else { return nil }
        return PiConnectorInstaller(
            extensionsDir: extensionsDir, agentsDir: agentsDir, pluginName: pluginName,
            socketPath: agentsDir.appendingPathComponent("bridge.sock").path,
            tokenPath: agentsDir.appendingPathComponent("token").path,
            readyPath: agentsDir.appendingPathComponent("ready.json").path,
            script: script)
    }

    private func perform(_ action: @escaping @Sendable (PiConnectorInstaller) throws -> Void) async throws {
        guard let installer = installer() else { throw AgentConnectorError(message: copy.unavailable) }
        let failure: String? = await Task.detached {
            do {
                try action(installer)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { throw AgentConnectorError(message: failure) }
    }

    private nonisolated static func trimmed(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    let copy = AgentConnectorCopy(
        help: "\(Branding.appName) reaches Pi through a small extension installed for your user account. Installed means the extension is in place; each session then connects on its own.",
        reloadHint: "Already running Pi? Run /reload once in each open session. New sessions connect on their own.",
        uninstallTitle: "Uninstall the Pi connector?",
        uninstallMessage: "Open Pi sessions disconnect now, and new ones will not connect. Work you already sent may still finish. Each open session unloads the connector when you run /reload in it or restart it. Your conversation names and other \(Branding.appName) settings are kept.",
        noSessions: "No Pi sessions are running.",
        toolNotFoundLabel: "Pi not found",
        toolNotFoundAdvice: "Install Pi, then come back here. \(Branding.appName) looks for the pi command on your PATH, in the usual install folders, and under Node version managers.",
        unavailable: "This copy of \(Branding.appName) is missing its Pi connector. Reinstall \(Branding.appName) to connect Pi.",
        disabledLabel: "Turned off in Pi",
        disabledAdvice: "Turn the extension back on in Pi.",
        removalUnfinishedAdvice: "The connector was uninstalled in \(Branding.appName), but its folder is still in Pi\u{2019}s extensions. Its sessions no longer connect. Finish uninstalling it, then install it again if you want it back.",
        listUnreadable: "Pi\u{2019}s extensions folder could not be read.",
        noReason: "Pi did not say why.",
        manualUninstallLead: "To remove the connector from Pi, delete its folder in a terminal, then run /reload in each open session or restart it:",
        manualUninstallAfterDisconnect: "Disconnected from \(Branding.appName). Delete the connector\u{2019}s folder in a terminal to finish uninstalling, then run /reload in each open session or restart it:",
        stillConnected: { count in
            count == 1
                ? "The connector was removed outside \(Branding.appName), so 1 open session is still connected and keeps receiving what you say until you run /reload in it or restart it."
                : "The connector was removed outside \(Branding.appName), so \(count) open sessions are still connected and keep receiving what you say until you run /reload in each one or restart them."
        },
        toolTooOldLabel: "Pi too old",
        toolTooOldAdvice: { found in
            "Pi \(found) is older than \(PiCLI.describe(PiCLI.minimumVersion)), the first version the connector works with. Update Pi, then come back here."
        })
}
