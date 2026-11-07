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
    let setupFolder: URL
    let pluginName: String
    let socketPath: String
    let tokenPath: String
    let readyPath: String
    let script: String


    static func defaultSetupFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".pi/agent", isDirectory: true)
    }

    static func pluginDir(in setupFolder: URL, pluginName: String) -> URL {
        setupFolder.appendingPathComponent("extensions", isDirectory: true).appendingPathComponent(pluginName, isDirectory: true)
    }

    var pluginDir: URL { Self.pluginDir(in: setupFolder, pluginName: pluginName) }
    var scriptURL: URL { pluginDir.appendingPathComponent("index.ts") }
    var configURL: URL { pluginDir.appendingPathComponent("keyscribe.json") }

    static func manualUninstall(pluginDir: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["rm -r \(ShellWord.path(pluginDir.path, home: home))"]
    }

    func install(installation: String) throws {
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

    func uninstall() throws {
        guard FileManager.default.fileExists(atPath: pluginDir.path) else { return }
        try FileManager.default.removeItem(at: pluginDir)
    }

    enum Installed: Equatable {
        case absent
        case current
        case other(version: String)
    }

    func installed(installation: String?) -> Installed {
        guard FileManager.default.fileExists(atPath: scriptURL.path), let data = FileManager.default.contents(atPath: configURL.path),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .absent }
        let version = config["version"] as? String ?? ""
        guard let installation, version == PiConnectorFiles.version(for: script), config["installation"] as? String == installation,
              (try? String(contentsOf: scriptURL, encoding: .utf8)) == PiConnectorFiles.installedScript(script, installation: installation, configPath: configURL.path)
        else { return .other(version: version) }
        return .current
    }

    func turnedOffInPi(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let data = FileManager.default.contents(atPath: setupFolder.appendingPathComponent("settings.json").path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = settings["extensions"] as? [String]
        else { return false }
        return PiExtensionSettings.excludes(entries, pluginDir: pluginDir.path, setupFolder: setupFolder.path, home: home.path)
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
    let defaultFolder: URL
    private let locate: () -> String?
    private let run: @Sendable ([String]) -> (Int32, String)
    private let agentsDir: URL
    private let pluginName: String
    private let script: String?
    private let home: URL

    init(
        locate: @escaping () -> String? = { PiCLI.locate() },
        run: @escaping @Sendable ([String]) -> (Int32, String) = { PiCLI.run($0) },
        agentsDir: URL, pluginName: String, script: String? = PiConnectorFiles.indexTS,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.locate = locate
        self.run = run
        self.agentsDir = agentsDir
        self.pluginName = pluginName
        self.script = script
        self.home = home
        defaultFolder = PiConnectorInstaller.defaultSetupFolder(home: home)
    }

    private var knownVersion: (tool: String, modified: Date?, version: [Int])?
    var isBundled: Bool { script != nil }
    var bundledVersion: String? { script.map(PiConnectorFiles.version(for:)) }

    func hasFiles(in target: ConnectorTarget) -> Bool {
        FileManager.default.fileExists(atPath: PiConnectorInstaller.pluginDir(in: target.folder, pluginName: pluginName).path)
    }

    func manualUninstall(for target: ConnectorTarget) -> [String] {
        PiConnectorInstaller.manualUninstall(pluginDir: PiConnectorInstaller.pluginDir(in: target.folder, pluginName: pluginName))
    }

    func recognizes(folder: URL) -> Bool {
        ConnectorFolders.contains(any: ["settings.json", "auth.json", "models.json", "extensions", "sessions"], in: folder)
    }

    func locateTool() -> String? { locate() }

    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
        guard let installer = installer(for: target) else { return .unavailable }
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
        let home = home
        let (installed, turnedOff) = await Task.detached {
            (installer.installed(installation: target.removing ? nil : target.installation), installer.turnedOffInPi(home: home))
        }.value
        if installed != .absent, target.removing { return .removalUnfinished(nil) }
        guard target.installation != nil, !target.removing else { return .status(.notInstalled) }
        switch installed {
        case .absent: return .status(.notInstalled)
        case .current: return .status(turnedOff ? .disabled : .ready)
        case .other(let version): return .status(.outdated(installed: version))
        }
    }

    func install(tool: String, target: ConnectorTarget) async throws {
        guard let installation = target.installation else { throw AgentConnectorError(message: copy.noReason) }
        try await perform(target) { try $0.install(installation: installation) }
    }

    func update(tool: String, target: ConnectorTarget) async throws { try await install(tool: tool, target: target) }
    func uninstall(tool: String, target: ConnectorTarget) async throws { try await perform(target) { try $0.uninstall() } }

    private func installer(for target: ConnectorTarget) -> PiConnectorInstaller? {
        guard let script else { return nil }
        return PiConnectorInstaller(
            setupFolder: target.folder, pluginName: pluginName,
            socketPath: agentsDir.appendingPathComponent("bridge.sock").path,
            tokenPath: agentsDir.appendingPathComponent("token").path,
            readyPath: agentsDir.appendingPathComponent("ready.json").path,
            script: script)
    }

    private func perform(_ target: ConnectorTarget, _ action: @escaping @Sendable (PiConnectorInstaller) throws -> Void) async throws {
        guard let installer = installer(for: target) else { throw AgentConnectorError(message: copy.unavailable) }
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
        help: "\(Branding.appName) reaches Pi through a small extension installed in the folder Pi loads its configuration from. Installed means the extension is in place; each conversation using this folder then connects on its own, unless you disconnect it.",
        reloadHint: "Already running Pi here? Run /reload once in each open conversation. New conversations connect on their own.",
        uninstallTitle: "Uninstall the Pi connector from this folder?",
        uninstallMessage: "Pi conversations using this folder disconnect now, and new ones will not connect. Work you already sent may still finish. Each open conversation unloads the connector when you run /reload in it or restart it. Other folders stay connected, and your conversation names, disconnected conversations and other \(Branding.appName) settings are kept.",
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
