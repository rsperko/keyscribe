import CryptoKit
import Foundation
import KeyScribeKit

@MainActor
final class CodexConnector: AgentConnector {
    typealias Run = @Sendable (_ argv: [String], _ subcommand: String, _ input: Data?, _ environment: [String: String]) async throws -> HostCLI.Output
    typealias ReadTrust = @Sendable (_ home: String, _ pluginId: String) async -> CodexPlugin.Trust?

    nonisolated static let script = ConnectorResources.text(named: "keyscribe-codex", extension: "sh", subdirectory: "CodexConnector")
    nonisolated static let executableName = "keyscribe-codex"

    var keepsConnection: Bool { false }

    let kind = CodexHost.kind
    let id: String
    private let agentsDir: URL
    private let home: URL
    private let script: String?
    private let run: Run
    private let tools: ToolEnvironment
    private let trust: ReadTrust

    init(
        agentsDir: URL, pluginName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, script: String? = CodexConnector.script,
        run: @escaping Run = { try await HostCLI.run($0, subcommand: $1, input: $2, environment: $3, timeout: .seconds(60)) },
        tools: ToolEnvironment = .shared, trust: @escaping ReadTrust = CodexConnector.readTrust
    ) {
        self.agentsDir = agentsDir
        id = pluginName
        self.home = home
        self.script = script
        self.run = run
        self.tools = tools
        self.trust = trust
    }

    nonisolated static func readTrust(home: String, pluginId: String) async -> CodexPlugin.Trust? {
        let client = CodexDaemonClient(socketPath: CodexDaemonClient.socketPath(home: home), onNotification: { _ in }, onClose: {})
        defer { client.close() }
        guard (try? await client.connect(timeout: CodexHost.callTimeout)) != nil,
              let result = try? await client.call("hooks/list", ["cwds": [home]], timeout: CodexHost.callTimeout)
        else { return nil }
        switch CodexPlugin.trust(result, pluginId: pluginId) {
        case .unreadable: return nil
        case let known: return known
        }
    }

    var layout: CodexPlugin.Layout { CodexPlugin.Layout(plugin: id, marketplace: "\(id)-local", title: Branding.appName) }
    private var codexFolder: URL { agentsDir.appendingPathComponent("codex", isDirectory: true) }
    var executable: URL { codexFolder.appendingPathComponent(Self.executableName) }

    func marketplaceFolder(for folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(ConnectorFolders.canonical(folder).path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return codexFolder.appendingPathComponent("home-\(digest)", isDirectory: true)
    }

    func pluginFolder(for folder: URL) -> URL { marketplaceFolder(for: folder).appendingPathComponent(layout.pluginFolder, isDirectory: true) }
    private func titleRecordURL(_ folder: URL) -> URL { marketplaceFolder(for: folder).appendingPathComponent("title-item.json") }
    private func configURL(_ folder: URL) -> URL { folder.appendingPathComponent("config.toml") }

    var isBundled: Bool { script != nil }
    var bundledVersion: String? { script.map { ConnectorResources.version(for: $0) } }
    var defaultFolder: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    var toolProgram: String? { CodexInstall.command }
    var folderVariable: String? { CodexHost.homeVariable }

    func hasFiles(in target: ConnectorTarget) -> Bool { FileManager.default.fileExists(atPath: marketplaceFolder(for: target.folder).path) }

    func recognizes(folder: URL) -> Bool { ConnectorFolders.contains(any: ["config.toml", "auth.json", "sessions"], in: folder) }

    func findTool(in folder: URL, chosen: String?) -> ToolSearch.Result? { CodexInstall.search(in: tools, home: folder.path, chosen: chosen) }

    func runs(tool path: String) -> Bool { CodexInstall.runs(path, in: tools) }

    func checkTool(_ tool: String) async -> ToolCheck? { await tools.check(tool: tool, agent: kind.id) }

    func manualUninstall(for target: ConnectorTarget) -> [String] {
        let codexHome = "\(CodexHost.homeVariable)=\(ShellWord.path(target.folder.path, home: home.path))"
        return [
            "\(codexHome) codex plugin remove \(layout.pluginId)", "\(codexHome) codex plugin marketplace remove \(layout.marketplace)",
            "rm -r \(ShellWord.path(marketplaceFolder(for: target.folder).path, home: home.path))",
        ]
    }

    private func expectedFiles(_ installation: String) -> [String: String] {
        CodexPlugin.files(layout, executable: executable.path, installation: installation)
    }

    private func filled(_ script: String) -> String { Self.filled(script, agentsDir: agentsDir, app: Branding.appName) }

    static func filled(_ script: String, agentsDir: URL, app: String) -> String {
        let escaped = String(String(decoding: (try? JSONEncoder().encode(app)) ?? Data("\"\"".utf8), as: UTF8.self).dropFirst().dropLast())
        return script.replacingOccurrences(of: "__AGENTS_DIR__", with: ShellWord.quoted(agentsDir.path))
            .replacingOccurrences(of: "__APP_NAME__", with: ShellWord.quoted(escaped))
    }

    private func filesCurrent(_ script: String, target: ConnectorTarget, installation: String) -> Bool {
        let marketplace = marketplaceFolder(for: target.folder)
        guard (try? String(contentsOf: executable, encoding: .utf8)) == filled(script) else { return false }
        return expectedFiles(installation).allSatisfy { path, body in (try? String(contentsOf: marketplace.appendingPathComponent(path), encoding: .utf8)) == body }
    }

    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
        guard let script else { return .unavailable }
        if target.removing { return hasFiles(in: target) ? .removalUnfinished(nil) : .status(.notInstalled) }
        guard let installation = target.installation, hasFiles(in: target) else { return .status(.notInstalled) }
        guard let listing = try? await output(tool, ["plugin", "list", "--marketplace", layout.marketplace, "--json"], subcommand: "plugin list", target: target),
              listing.status == 0, let listed = CodexPlugin.installed(listing.stdout, pluginId: layout.pluginId, path: pluginFolder(for: target.folder).path)
        else { return .status(.unknown) }
        switch listed {
        case .absent: return .status(.notInstalled)
        case .disabled: return .status(.disabled)
        case .enabled: break
        }
        guard filesCurrent(script, target: target, installation: installation) else { return .status(.outdated(installed: "")) }
        let config: String?
        do { config = try await Self.read(configURL(target.folder)) } catch { return .broken(Self.titleUnreadable) }
        switch CodexTitleItem.inspect(config) {
        case .present: break
        case .missing: return .broken(Self.needsRepair)
        case .unreadable, .unsupported: return .broken(Self.titleUnreadable)
        }
        switch await trust(target.folder.path, layout.pluginId) {
        case .needsTrust: return .needsUser(Self.needsTrust)
        case .absent: return .broken(Self.hooksNotListed)
        case .trusted, .unreadable, nil: return .status(.ready)
        }
    }

    nonisolated static let needsRepair =
        "The thread-id item was removed from Codex\u{2019}s terminal title, so \(Branding.appName) can\u{2019}t tell which terminal shows which conversation. Choose Update to put it back."
    nonisolated static let titleUnreadable =
        "Codex\u{2019}s config.toml couldn\u{2019}t be read, so \(Branding.appName) can\u{2019}t check the thread-id item in its terminal title."
    nonisolated static let titleNotRemoved =
        "Codex\u{2019}s config.toml has changed in a way \(Branding.appName) can\u{2019}t safely edit, so the thread-id item it added to the terminal title is still there. Remove \u{201C}thread-id\u{201D} from terminal_title under [tui] in config.toml, or put the file back as it was, then uninstall again."
    nonisolated static let hooksNotListed =
        "Codex\u{2019}s app server doesn\u{2019}t list the plugin\u{2019}s hooks, so its turns may not be reported. Choose Update to add the plugin again."
    nonisolated static let needsTrust =
        "Codex won\u{2019}t run the plugin\u{2019}s hooks until you trust them. In Codex, type /hooks and press t to trust all, or press Return to review the events marked for review; a new Codex session also asks when it starts. Then choose Check Again."

    func install(tool: String, target: ConnectorTarget) async throws {
        guard let script else { throw AgentConnectorError(message: copy.unavailable) }
        guard let installation = target.installation else { throw AgentConnectorError(message: copy.noReason) }
        let config = configURL(target.folder)
        let original = try await Self.read(config)
        switch CodexTitleItem.inspect(original) {
        case .unreadable, .unsupported: throw AgentConnectorError(message: Self.titleUnreadable)
        case .present, .missing: break
        }
        let marketplace = marketplaceFolder(for: target.folder)
        let files = expectedFiles(installation).map { (marketplace.appendingPathComponent($0.key), $0.value) }
        let executable = self.executable
        let program = filled(script)
        let failure: String? = await Task.detached {
            do {
                for (url, text) in files {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: url, options: .atomic)
                }
                try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
                let staged = executable.deletingLastPathComponent().appendingPathComponent(".\(executable.lastPathComponent)-\(UUID().uuidString)")
                try Data(program.utf8).write(to: staged)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
                guard rename(staged.path, executable.path) == 0 else {
                    try? FileManager.default.removeItem(at: staged)
                    return String(cString: strerror(errno))
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { throw AgentConnectorError(message: failure) }
        let added = try await output(tool, ["plugin", "marketplace", "add", marketplace.path], subcommand: "plugin marketplace add", target: target)
        if added.status != 0, !Self.mentions((try? await Self.read(config)) ?? nil, marketplace: layout.marketplace, at: marketplace.path) {
            throw AgentConnectorError(message: Self.problem(added))
        }
        try await call(tool, ["plugin", "add", layout.pluginId], subcommand: "plugin add", target: target)
        try await addTitleItem(target)
    }

    private func addTitleItem(_ target: ConnectorTarget) async throws {
        let config = configURL(target.folder)
        let current = try await Self.read(config)
        guard CodexTitleItem.inspect(current) != .present else { return }
        guard let (text, added) = CodexTitleItem.adding(to: current) else { throw AgentConnectorError(message: Self.titleUnreadable) }
        let recordURL = titleRecordURL(target.folder)
        let earlier = FileManager.default.contents(atPath: recordURL.path).flatMap { try? JSONDecoder().decode(CodexTitleItem.Record.self, from: $0) }
        let record = earlier.map { CodexTitleItem.keeping($0, over: added) } ?? added
        let failure: String? = await Task.detached {
            do {
                try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
                do {
                    try Data(text.utf8).write(to: config, options: .atomic)
                } catch {
                    if let earlier { try? JSONEncoder().encode(earlier).write(to: recordURL, options: .atomic) } else { try? FileManager.default.removeItem(at: recordURL) }
                    throw error
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { throw AgentConnectorError(message: failure) }
    }

    func uninstallWithoutTool(target: ConnectorTarget) async throws {
        try await restoreConfig(target)
    }

    private func restoreConfig(_ target: ConnectorTarget) async throws {
        let recordURL = titleRecordURL(target.folder)
        let config = configURL(target.folder)
        let pluginId = layout.pluginId
        let failure: String? = await Task.detached {
            let record = FileManager.default.contents(atPath: recordURL.path).flatMap { try? JSONDecoder().decode(CodexTitleItem.Record.self, from: $0) }
            let current: String?
            do { current = try Self.readNow(config) } catch { return Self.titleUnreadable }
            var restored = current
            if let record {
                guard let removed = CodexTitleItem.removing(from: current, record: record) else { return Self.titleNotRemoved }
                restored = removed
            }
            restored = restored.map { CodexPlugin.forgettingTrust(in: $0, pluginId: pluginId) }
            do {
                if let restored, restored != (current ?? "") { try Data(restored.utf8).write(to: config, options: .atomic) }
                if record != nil { try FileManager.default.removeItem(at: recordURL) }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { throw AgentConnectorError(message: failure) }
    }

    func update(tool: String, target: ConnectorTarget) async throws {
        try await install(tool: tool, target: target)
    }

    func uninstall(tool: String, target: ConnectorTarget) async throws {
        let removed = try await output(tool, ["plugin", "remove", layout.pluginId], subcommand: "plugin remove", target: target)
        let config = configURL(target.folder)
        if removed.status != 0, (try? await Self.read(config))??.contains("\"\(layout.pluginId)\"") == true { throw AgentConnectorError(message: Self.problem(removed)) }
        let marketplace = marketplaceFolder(for: target.folder)
        let left = try await output(tool, ["plugin", "marketplace", "remove", layout.marketplace], subcommand: "plugin marketplace remove", target: target)
        if left.status != 0, Self.mentions((try? await Self.read(config)) ?? nil, marketplace: layout.marketplace, at: marketplace.path) {
            throw AgentConnectorError(message: Self.problem(left))
        }
        try await restoreConfig(target)
        let codexFolder = self.codexFolder
        let executable = self.executable
        let failure: String? = await Task.detached {
            do {
                if FileManager.default.fileExists(atPath: marketplace.path) { try FileManager.default.removeItem(at: marketplace) }
                let others = (try? FileManager.default.contentsOfDirectory(atPath: codexFolder.path))?.filter { $0.hasPrefix("home-") } ?? []
                if others.isEmpty, FileManager.default.fileExists(atPath: executable.path) { try FileManager.default.removeItem(at: executable) }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { throw AgentConnectorError(message: failure) }
    }

    private nonisolated static func read(_ url: URL) async throws -> String? {
        try await Task.detached { try readNow(url) }.value
    }

    private nonisolated static func readNow(_ url: URL) throws -> String? {
        do {
            return String(decoding: try Data(contentsOf: url), as: UTF8.self)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw AgentConnectorError(message: titleUnreadable)
        }
    }

    private nonisolated static func mentions(_ config: String?, marketplace: String, at path: String) -> Bool {
        guard let config else { return false }
        return config.contains("[marketplaces.\(marketplace)]") && config.contains("\"\(path)\"")
    }

    private nonisolated static func problem(_ output: HostCLI.Output) -> String {
        let said = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "Codex did not say why." : String(said.prefix(300))
    }

    private func call(_ tool: String, _ arguments: [String], subcommand: String, target: ConnectorTarget) async throws {
        let output = try await output(tool, arguments, subcommand: subcommand, target: target)
        guard output.status == 0 else { throw AgentConnectorError(message: Self.problem(output)) }
    }

    private func output(_ tool: String, _ arguments: [String], subcommand: String, target: ConnectorTarget) async throws -> HostCLI.Output {
        let environment = tools.runEnvironment(
            tool: tool, agent: kind.id, base: ["HOME": home.path, CodexHost.homeVariable: target.folder.path])
        do {
            return try await run([tool] + arguments, subcommand, nil, environment)
        } catch {
            throw AgentConnectorError(message: "codex \(subcommand) did not finish: \(error)")
        }
    }

    let copy = AgentConnectorCopy(
        help: "With a small plugin installed in Codex, \(Branding.appName) lists the conversations Codex\u{2019}s app server holds, sends what you say to one that is idle, holds it while the conversation is busy or waiting on you, and hears how it answers and what it stops to ask you. Codex runs the plugin\u{2019}s hooks only after you trust them in Codex with /hooks. Conversations in a Codex started with its own settings flags, or in the ChatGPT app, are not on the app server and are not listed.",
        reloadHint: "",
        uninstallTitle: "Uninstall the plugin from Codex?",
        uninstallMessage: "\(Branding.appName) stops listing Codex conversations and sending to them, and removes the thread-id item it added to Codex\u{2019}s terminal title. Codex, its conversations, your conversation names and disconnections, and other \(Branding.appName) settings are kept.",
        toolNotFoundLabel: "Codex not found",
        toolNotFoundAdvice: "Install the Codex command line tool, for example with Homebrew. The codex inside the ChatGPT app reaches only that app and isn\u{2019}t used.",
        unavailable: "This copy of \(Branding.appName) is missing its Codex plugin. Reinstall \(Branding.appName) to add it.",
        disabledLabel: "Turned off in Codex",
        disabledAdvice: "Turn the plugin back on in Codex with /plugins.",
        removalUnfinishedAdvice: "The plugin was uninstalled in \(Branding.appName), but its files are still in place. Finish uninstalling it, then install it again if you want it back.",
        listUnreadable: "Codex didn\u{2019}t answer, so the plugin couldn\u{2019}t be checked.",
        noReason: "Codex did not say why.",
        manualUninstallAfterDisconnect: "Disconnected from \(Branding.appName). Run these in a terminal to finish uninstalling:",
        stillConnected: { _ in "" },
        setupTitle: "Plugin",
        purpose: "Dictate to a Codex conversation by name and hear its replies read aloud.",
        installNote: "Installing also adds the thread-id item to Codex\u{2019}s terminal title ([tui] terminal_title in config.toml), so \(Branding.appName) can tell which terminal shows which conversation. Uninstalling removes only that item.",
        folderNoun: "Codex home",
        foldersHelp: "A Codex home is where Codex keeps its settings and conversations: ~/.codex, or the folder CODEX_HOME names. Each one is connected and removed on its own.")
}
