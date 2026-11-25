import Foundation
import KeyScribeKit

enum UltimateConnectorFiles {
    static let names = ["server.ts", "keyscribe.ts", "page.ts", "web.solid.tsx", "web.tsx", "README.md"]
    static let configName = "keyscribe.json"
    static let writeOrder = [configName, "keyscribe.ts", "page.ts", "web.solid.tsx", "web.tsx", "README.md", "server.ts"]
    private static let extensionLine = "const extension = 'keyscribe'"

    static let sources: [String: String]? = {
        var found: [String: String] = [:]
        for name in names {
            let dot = name.lastIndex(of: ".")!
            guard let text = ConnectorResources.text(
                named: String(name[..<dot]), extension: String(name[name.index(after: dot)...]), subdirectory: "UltimateConnector")
            else { return nil }
            found[name] = text
        }
        return found
    }()

    static func version(for sources: [String: String]) -> String {
        ConnectorResources.version(for: names.map { "\($0)\n\(sources[$0] ?? "")" }.joined(separator: "\n"))
    }

    static func written(_ sources: [String: String], id: String) -> [String: String] {
        sources.reduce(into: [:]) { files, entry in
            files[entry.key] = entry.key.hasPrefix("web.")
                ? entry.value.replacingOccurrences(of: extensionLine, with: "const extension = '\(id)'") : entry.value
        }
    }

    static func config(agentsDir: URL, setup: URL, id: String, installation: String, version: String) -> String {
        ConnectorResources.json([
            "protocol": AgentBridgeCodec.protocolVersion, "socketPath": agentsDir.appendingPathComponent("bridge.sock").path,
            "tokenPath": agentsDir.appendingPathComponent("token").path, "readyPath": agentsDir.appendingPathComponent("ready.json").path,
            "installation": installation, "setup": ConnectorFolders.canonical(setup).path, "version": version, "appName": Branding.appName,
            "plugin": id,
        ])
    }
}

@MainActor
final class UltimateConnector: AgentConnector {
    let kind = UltimateHost.kind
    let id: String
    private let agentsDir: URL
    private let home: URL
    private let sources: [String: String]?
    private let silentProject: @Sendable (URL) async -> String?

    init(
        agentsDir: URL, pluginName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        sources: [String: String]? = UltimateConnectorFiles.sources,
        silentProject: @escaping @Sendable (URL) async -> String? = { await UltimateHost.silentProject(setup: $0.path) }
    ) {
        self.agentsDir = agentsDir
        id = pluginName
        self.home = home
        self.sources = sources
        self.silentProject = silentProject
    }

    var isBundled: Bool { sources != nil }
    var bundledVersion: String? { sources.map(UltimateConnectorFiles.version) }
    var defaultFolder: URL { home.appendingPathComponent(UltimateProjects.setupFolderName, isDirectory: true) }

    func extensionFolder(_ setup: URL) -> URL {
        setup.appendingPathComponent(UltimateProjects.extensionsFolder, isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    private func configURL(_ setup: URL) -> URL { extensionFolder(setup).appendingPathComponent(UltimateConnectorFiles.configName) }

    func hasFiles(in target: ConnectorTarget) -> Bool { FileManager.default.fileExists(atPath: extensionFolder(target.folder).path) }

    func manualUninstall(for target: ConnectorTarget) -> [String] {
        ["rm -r \(ShellWord.path(extensionFolder(target.folder).path, home: home.path))"]
    }

    func recognizes(folder: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return UltimateProjects.isSetupFolder(name: folder.lastPathComponent, contents: contents)
    }

    func findTool(in folder: URL, chosen: String?) -> ToolSearch.Result? { nil }

    private func expected(_ sources: [String: String], target: ConnectorTarget, installation: String) -> [String: String] {
        var files = UltimateConnectorFiles.written(sources, id: id)
        files[UltimateConnectorFiles.configName] = UltimateConnectorFiles.config(
            agentsDir: agentsDir, setup: target.folder, id: id, installation: installation, version: UltimateConnectorFiles.version(for: sources))
        return files
    }

    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
        guard let sources else { return .unavailable }
        let folder = extensionFolder(target.folder)
        let settingsURL = target.folder.appendingPathComponent(UltimateProjects.settingsFile)
        let config = configURL(target.folder)
        let id = id
        let read = await Task.detached { () -> (config: Data?, settings: Data?, settingsExists: Bool) in
            let exists = FileManager.default.fileExists(atPath: settingsURL.path)
            return (FileManager.default.contents(atPath: config.path), exists ? FileManager.default.contents(atPath: settingsURL.path) : nil, exists)
        }.value
        let installed = read.config.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if target.removing { return installed == nil && !FileManager.default.fileExists(atPath: folder.path) ? .status(.notInstalled) : .removalUnfinished(nil) }
        guard let installation = target.installation, let config = installed else { return .status(.notInstalled) }
        if read.settingsExists, read.settings == nil { return .unconfirmed(Self.unreadableSettings) }
        switch UltimateProjects.turnedOff(read.settings, extension: id) {
        case .some(true): return .status(.disabled)
        case .none: return .unconfirmed(Self.unreadableSettings)
        case .some(false): break
        }
        let files = expected(sources, target: target, installation: installation)
        let current = await Task.detached {
            files.allSatisfy { name, text in (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) == text }
        }.value
        guard current else { return .status(.outdated(installed: config["version"] as? String ?? "")) }
        if let project = await silentProject(target.folder) { return .broken(Self.notAnswering(project)) }
        return .status(.ready)
    }

    static func notAnswering(_ project: String) -> String {
        "Ultimate is running \(project), but the extension there isn\u{2019}t answering. Ultimate\u{2019}s status line names the extension problem."
    }

    private static let unreadableSettings =
        "Ultimate\u{2019}s settings.json couldn\u{2019}t be read, so \(Branding.appName) can\u{2019}t tell whether the extension is turned off. Fix the file, then choose Try Again."

    func install(tool: String, target: ConnectorTarget) async throws {
        guard let sources else { throw AgentConnectorError(message: copy.unavailable) }
        guard let installation = target.installation else { throw AgentConnectorError(message: copy.noReason) }
        let files = expected(sources, target: target, installation: installation)
        let folder = extensionFolder(target.folder)
        let failure: String? = await Task.detached {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where files[name] == nil {
                    try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
                for name in UltimateConnectorFiles.writeOrder {
                    guard let text = files[name] else { continue }
                    try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { throw AgentConnectorError(message: failure) }
    }

    func update(tool: String, target: ConnectorTarget) async throws { try await install(tool: tool, target: target) }

    func uninstall(tool: String, target: ConnectorTarget) async throws { try await remove(target) }

    func uninstallWithoutTool(target: ConnectorTarget) async throws { try await remove(target) }

    private func remove(_ target: ConnectorTarget) async throws {
        let folder = extensionFolder(target.folder)
        let failure: String? = await Task.detached {
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            do {
                try FileManager.default.removeItem(at: folder)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { throw AgentConnectorError(message: failure) }
    }

    let copy = AgentConnectorCopy(
        help: "With a small extension installed in Ultimate, \(Branding.appName) lists @ultimate, your standing agents, branches, subagents and side chats in every project Ultimate runs, sends what you say to them as your own message, into a turn already running the way typing in Ultimate would, and hears how they answer and what they stop to ask you; each open Ultimate page reports the writable message box that receives typing, so dictation reaches a side chat when it covers the main composer. Ultimate loads the extension into every project on this Mac, and every writable conversation connects on its own unless you disconnect it. \(Branding.appName) runs nothing of Ultimate\u{2019}s until you connect it.",
        reloadHint: "",
        uninstallTitle: "Uninstall the extension from Ultimate?",
        uninstallMessage: "\(Branding.appName) stops listing Ultimate conversations and sending to them. Ultimate, its conversations, your conversation names and disconnections, and other \(Branding.appName) settings are kept.",
        toolNotFoundLabel: "",
        toolNotFoundAdvice: "",
        unavailable: "This copy of \(Branding.appName) is missing its Ultimate extension. Reinstall \(Branding.appName) to add it.",
        disabledLabel: "Turned off in Ultimate",
        disabledAdvice: "Turn the extension back on in Ultimate\u{2019}s Extensions panel.",
        removalUnfinishedAdvice: "The extension was uninstalled in \(Branding.appName), but its files are still in place. Its conversations no longer report. Finish uninstalling it, then install it again if you want it back.",
        listUnreadable: "Ultimate\u{2019}s user folder couldn\u{2019}t be read, so the extension couldn\u{2019}t be checked.",
        noReason: "Ultimate did not say why.",
        manualUninstallAfterDisconnect: "Disconnected from \(Branding.appName). Run this in a terminal to finish uninstalling:",
        stillConnected: { count in
            count == 1
                ? "The extension was removed outside \(Branding.appName), so 1 Ultimate conversation is still connected until Ultimate reloads its extensions."
                : "The extension was removed outside \(Branding.appName), so \(count) Ultimate conversations are still connected until Ultimate reloads its extensions."
        },
        setupTitle: "Extension",
        purpose: "Dictate to the Ultimate conversation you are looking at and hear its replies read aloud.",
        installNote: "Ultimate loads the extension at once, in every project it runs on this Mac; nothing restarts.",
        undoOnUninstallLabel: "",
        undoOnUninstallNote: "",
        folderNoun: "user folder",
        foldersHelp: "A user folder is where Ultimate keeps your settings, extensions and every project\u{2019}s state: ~/.ultimate, or the .ultimate folder in the home ULTIMATE_USER_HOME names. If you run Ultimate with its own user folder, choose Add Folder\u{2026}.")
}
