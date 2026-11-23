import Foundation
import KeyScribeKit

struct ExtensionAgent: Sendable {
    let kind: AgentKind
    let rule: AgentProcesses.Rule
    var keepsPluginName = false
    let extraFolders: @Sendable (_ home: URL) -> [String]
    let minimumVersion: [Int]
    let version: @Sendable (_ output: String) -> [Int]?
    let turnedOff: @Sendable (TurnedOffQuery) async -> TurnedOff
    let recognizedFiles: [String]
    let wording: Wording

    struct Wording: Sendable {
        var disabledAdvice: String
        var updateStep: String
        var minimumReason: String?
        var alsoSearched: [String] = []
        var foldersHelp: String?
    }

    var toolProgram: String { rule.command }

    func folderName(plugin: String) -> String { keepsPluginName ? plugin : "\(plugin)-\(kind.id)" }

    func isSupported(_ version: [Int]) -> Bool {
        version.lexicographicallyPrecedes(minimumVersion) == false
    }

    static func describe(_ version: [Int]) -> String { version.map(String.init).joined(separator: ".") }
}

extension AgentConnectorCopy {
    static func extensionAgent(_ agent: ExtensionAgent) -> AgentConnectorCopy {
        let kind = agent.kind
        let wording = agent.wording
        let name = kind.displayName
        let app = Branding.appName
        let places = ["a running conversation", "your login shell\u{2019}s PATH", "its own PATH", "the usual install folders"] + wording.alsoSearched
        let searched = places.dropLast().joined(separator: ", ") + ", and " + places[places.count - 1]
        let unloadEach: String
        let unloadOne: String
        let unloadMany: String
        let reloadHint: String
        if let reload = kind.reloadCommand {
            reloadHint = "Already running \(name) here? Run \(reload) in each open conversation."
            unloadEach = "run \(reload) in each open conversation or restart it"
            unloadOne = "run \(reload) in it or restart it"
            unloadMany = "run \(reload) in each one or restart them"
        } else if let resume = kind.resumeCommand {
            reloadHint = "Already running \(name) here? Quit each open conversation and reopen it with \(resume) to connect it."
            unloadEach = "quit each open conversation and reopen it with \(resume)"
            unloadOne = "quit it and reopen it with \(resume)"
            unloadMany = "quit them and reopen them with \(resume)"
        } else {
            reloadHint = "Already running \(name) here? Restart each open conversation to connect it."
            unloadEach = "restart each open conversation"
            unloadOne = "restart it"
            unloadMany = "restart them"
        }
        return AgentConnectorCopy(
            help: "\(app) reaches \(name) through a small extension installed in the folder \(name) loads its configuration from. Installed means the extension is in place; each conversation using this folder then connects on its own, unless you disconnect it.",
            reloadHint: reloadHint,
            uninstallTitle: "Uninstall the \(kind.connectorName) from this folder?",
            uninstallMessage: "\(name) conversations using this folder disconnect now, and new ones will not connect. Work you already sent may still finish. Each open conversation unloads the connector when you \(unloadOne). Other folders stay connected. The folder, its conversations, your conversation names and disconnections, and other \(app) settings are kept.",
            toolNotFoundLabel: "\(name) not found",
            toolNotFoundAdvice: "Install \(name), or choose the \(agent.toolProgram) command yourself. \(app) looked for it in \(searched).",
            toolNotWorkingLabel: "\(name) not working",
            unavailable: "This copy of \(app) is missing its \(kind.connectorName). Reinstall \(app) to connect \(name).",
            disabledLabel: "Turned off in \(name)",
            disabledAdvice: wording.disabledAdvice,
            removalUnfinishedAdvice: "The connector was uninstalled in \(app), but its folder is still in \(name)\u{2019}s extensions. Its conversations no longer connect. Finish uninstalling it, then install it again if you want it back.",
            listUnreadable: "\(name)\u{2019}s extensions folder could not be read.",
            noReason: "\(name) did not say why.",
            manualUninstallAfterDisconnect: "Disconnected from \(app). Delete the connector\u{2019}s folder in a terminal to finish uninstalling, then \(unloadEach):",
            stillConnected: { count in
                count == 1
                    ? "The connector was removed outside \(app), so 1 open conversation is still connected and keeps receiving what you say until you \(unloadOne)."
                    : "The connector was removed outside \(app), so \(count) open conversations are still connected and keep receiving what you say until you \(unloadMany)."
            },
            toolTooOldLabel: "\(name) too old",
            toolTooOldAdvice: { found in
                "\(name) \(found) is older than \(ExtensionAgent.describe(agent.minimumVersion)), the oldest version the connector supports\(wording.minimumReason.map { ": \($0)" } ?? ""). \(wording.updateStep), then come back here."
            },
            foldersHelp: wording.foldersHelp)
    }
}

enum TurnedOff: Equatable, Sendable {
    case no
    case yes
    case unknown(String)
}

struct TurnedOffQuery: Sendable {
    let setupFolder: URL
    let pluginDir: URL
    let home: URL
    let run: @Sendable (_ arguments: [String]) async -> ToolCLI.Ran
}

struct ExtensionConnectorInstaller {
    let agent: ExtensionAgent
    let setupFolder: URL
    let pluginName: String
    let socketPath: String
    let tokenPath: String
    let readyPath: String
    let script: String
    let surfaces: ConnectorSurfaces

    static func pluginDir(in setupFolder: URL, pluginName: String) -> URL {
        setupFolder.appendingPathComponent("extensions", isDirectory: true).appendingPathComponent(pluginName, isDirectory: true)
    }

    var pluginDir: URL { Self.pluginDir(in: setupFolder, pluginName: agent.folderName(plugin: pluginName)) }
    var scriptURL: URL { pluginDir.appendingPathComponent("index.ts") }
    var configURL: URL { pluginDir.appendingPathComponent("keyscribe.json") }

    static func manualUninstall(pluginDir: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["rm -r \(ShellWord.path(pluginDir.path, home: home))"]
    }

    private func config(installation: String) -> String {
        ExtensionConnectorFiles.configJSON(
            socketPath: socketPath, tokenPath: tokenPath, readyPath: readyPath, installation: installation, plugin: pluginName,
            version: ExtensionConnectorFiles.version(for: script, surfaces: surfaces), surfaces: surfaces)
    }

    private func installedScript(_ installation: String) -> String {
        ExtensionConnectorFiles.installedScript(
            script, installation: installation, configPath: configURL.path, agent: agent.kind.id,
            version: ExtensionConnectorFiles.version(for: script, surfaces: surfaces))
    }

    func install(installation: String) throws {
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let files: [(URL, String)] = [
            (scriptURL, installedScript(installation)),
            (configURL, config(installation: installation)),
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
        guard let installation, version == ExtensionConnectorFiles.version(for: script, surfaces: surfaces), config["installation"] as? String == installation,
              String(decoding: data, as: UTF8.self) == self.config(installation: installation),
              (try? String(contentsOf: scriptURL, encoding: .utf8)) == installedScript(installation)
        else { return .other(version: version) }
        return .current
    }

}

enum ExtensionConnectorFiles {
    static let indexTS: String? = ConnectorResources.text(named: "index", extension: "ts")

    static func version(for script: String, surfaces: ConnectorSurfaces) -> String {
        ConnectorResources.version(for: script + "\n" + surfaces.fingerprint)
    }

    static func installedScript(_ script: String, installation: String, configPath: String, agent: String, version: String) -> String {
        script
            .replacingOccurrences(of: "const configPath: string | null = null", with: "const configPath: string | null = \(quoted(configPath))")
            .replacingOccurrences(of: "const loadedFrom: string | null = null", with: "const loadedFrom: string | null = \(quoted(installation))")
            .replacingOccurrences(of: "const installedFor: string | null = null", with: "const installedFor: string | null = \(quoted(agent))")
            .replacingOccurrences(of: "const builtVersion: string | null = null", with: "const builtVersion: string | null = \(quoted(version))")
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func configJSON(
        socketPath: String, tokenPath: String, readyPath: String, installation: String, plugin: String, version: String,
        surfaces: ConnectorSurfaces
    ) -> String {
        ConnectorResources.json([
            "protocol": AgentBridgeCodec.protocolVersion, "socketPath": socketPath, "tokenPath": tokenPath, "readyPath": readyPath,
            "installation": installation, "plugin": plugin, "version": version, "appName": Branding.appName,
        ].merging(surfaces.configFields) { own, _ in own })
    }
}

@MainActor
final class ExtensionConnector: AgentConnector {
    let agent: ExtensionAgent
    let defaultFolder: URL
    private let version: @Sendable (String) async -> ToolCheck
    private let tools: ToolEnvironment
    private let agentsDir: URL
    private let pluginName: String
    private let script: String?
    private let home: URL
    private let surfaces: ConnectorSurfaces

    init(
        agent: ExtensionAgent,
        version: (@Sendable (String) async -> ToolCheck)? = nil,
        tools: ToolEnvironment = .shared,
        agentsDir: URL, pluginName: String, surfaces: ConnectorSurfaces, script: String? = ExtensionConnectorFiles.indexTS,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.agent = agent
        self.surfaces = surfaces
        self.version = version ?? { [id = agent.kind.id] in await tools.check(tool: $0, agent: id) }
        self.tools = tools
        self.agentsDir = agentsDir
        self.pluginName = pluginName
        self.script = script
        self.home = home
        defaultFolder = agent.rule.defaultFolder(home: home)
        copy = .extensionAgent(agent)
    }

    var kind: AgentKind { agent.kind }
    let copy: AgentConnectorCopy
    var isBundled: Bool { script != nil }
    var bundledVersion: String? { script.map { ExtensionConnectorFiles.version(for: $0, surfaces: surfaces) } }

    func hasFiles(in target: ConnectorTarget) -> Bool {
        FileManager.default.fileExists(atPath: pluginDir(in: target).path)
    }

    func manualUninstall(for target: ConnectorTarget) -> [String] {
        ExtensionConnectorInstaller.manualUninstall(pluginDir: pluginDir(in: target))
    }

    private func pluginDir(in target: ConnectorTarget) -> URL {
        ExtensionConnectorInstaller.pluginDir(in: target.folder, pluginName: agent.folderName(plugin: pluginName))
    }

    func recognizes(folder: URL) -> Bool {
        ConnectorFolders.contains(any: agent.recognizedFiles, in: folder)
    }

    var toolProgram: String? { agent.toolProgram }

    var folderVariable: String? { agent.rule.setupVariable }

    func findTool(in folder: URL, chosen: String?) -> ToolSearch.Result? {
        tools.search(program: agent.toolProgram, agent: kind.id, setup: folder.path, chosen: chosen, extra: agent.extraFolders(home))
    }

    func checkTool(_ tool: String) async -> ToolCheck? { await version(tool) }

    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
        guard let installer = installer(for: target) else { return .unavailable }
        let working = await self.version(tool)
        guard case .working(let text) = working, let version = agent.version(text) else { return .toolNotWorking(working) }
        guard agent.isSupported(version) else { return .toolTooOld(ExtensionAgent.describe(version)) }
        let installed = await Task.detached { installer.installed(installation: target.removing ? nil : target.installation) }.value
        if installed != .absent, target.removing { return .removalUnfinished(nil) }
        guard target.installation != nil, !target.removing else { return .status(.notInstalled) }
        switch installed {
        case .absent: return .status(.notInstalled)
        case .other(let version): return .status(.outdated(installed: version))
        case .current:
            switch await agent.turnedOff(query(tool: tool, target: target, installer: installer)) {
            case .no: return .status(.ready)
            case .yes: return .status(.disabled)
            case .unknown(let reason): return .unconfirmed(reason)
            }
        }
    }

    func install(tool: String, target: ConnectorTarget) async throws {
        guard let installation = target.installation else { throw AgentConnectorError(message: copy.noReason) }
        try await perform(target) { try $0.install(installation: installation) }
    }

    func update(tool: String, target: ConnectorTarget) async throws { try await install(tool: tool, target: target) }
    func uninstall(tool: String, target: ConnectorTarget) async throws { try await perform(target) { try $0.uninstall() } }

    private func query(tool: String, target: ConnectorTarget, installer: ExtensionConnectorInstaller) -> TurnedOffQuery {
        let unset = agent.rule.profileVariables.flatMap { ["-u", $0] }
        let variable = agent.rule.setupVariable
        let setup = unset + (target.isDefault ? ["-u", variable] : ["\(variable)=\(target.folder.path)"])
        let (tools, kind) = (tools, kind.id)
        return TurnedOffQuery(
            setupFolder: target.folder, pluginDir: installer.pluginDir, home: home,
            run: { arguments in await tools.run(["/usr/bin/env"] + setup + [tool] + arguments, tool: tool, agent: kind) })
    }

    private func installer(for target: ConnectorTarget) -> ExtensionConnectorInstaller? {
        guard let script else { return nil }
        return ExtensionConnectorInstaller(
            agent: agent, setupFolder: target.folder, pluginName: pluginName,
            socketPath: agentsDir.appendingPathComponent("bridge.sock").path,
            tokenPath: agentsDir.appendingPathComponent("token").path,
            readyPath: agentsDir.appendingPathComponent("ready.json").path,
            script: script, surfaces: surfaces)
    }

    private func perform(_ target: ConnectorTarget, _ action: @escaping @Sendable (ExtensionConnectorInstaller) throws -> Void) async throws {
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
}
