import CryptoKit
import Foundation
import KeyScribeKit

@MainActor
final class CodexConnector: AgentConnector {
    typealias Run = @Sendable (_ argv: [String], _ subcommand: String, _ input: Data?, _ environment: [String: String]) async throws -> HostCLI.Output
    typealias ReadTrust = @Sendable (_ home: String, _ pluginId: String) async -> CodexPlugin.Trust?

    nonisolated static let script = ConnectorResources.text(named: "keyscribe-codex", extension: "sh", subdirectory: "CodexConnector")
    nonisolated static let executableName = "keyscribe-codex"

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
        case .unreadable, .absent: return nil
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

    func findTool(in folder: URL, chosen: String?) -> ToolSearch.Result { CodexInstall.search(in: tools, home: folder.path, chosen: chosen) }

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

    private func filled(_ script: String) -> String {
        let app = String(String(decoding: (try? JSONEncoder().encode(Branding.appName)) ?? Data("\"\"".utf8), as: UTF8.self).dropFirst().dropLast())
        return script.replacingOccurrences(of: "__AGENTS_DIR__", with: ShellWord.quoted(agentsDir.path)).replacingOccurrences(of: "__APP_NAME__", with: app)
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
        let config = await Self.read(configURL(target.folder))
        switch CodexTitleItem.inspect(config) {
        case .present: break
        case .missing: return .broken(Self.needsRepair)
        case .unreadable, .unsupported: return .broken(Self.titleUnreadable)
        }
        if await trust(target.folder.path, layout.pluginId) == .needsTrust { return .broken(Self.needsTrust) }
        return .status(.ready)
    }

    nonisolated static let needsRepair =
        "The thread-id item was removed from Codex\u{2019}s terminal title, so \(Branding.appName) can\u{2019}t tell which terminal shows which conversation. Choose Update to put it back."
    nonisolated static let titleUnreadable =
        "Codex\u{2019}s config.toml couldn\u{2019}t be read, so \(Branding.appName) can\u{2019}t check the thread-id item in its terminal title."
    nonisolated static let needsTrust =
        "Codex hasn\u{2019}t trusted the plugin\u{2019}s hooks yet. In Codex, type /hooks and trust the \(Branding.appName) hooks."

    func install(tool: String, target: ConnectorTarget) async throws {
        guard let script else { throw AgentConnectorError(message: copy.unavailable) }
        guard let installation = target.installation else { throw AgentConnectorError(message: copy.noReason) }
        let config = configURL(target.folder)
        let original = await Self.read(config)
        switch CodexTitleItem.inspect(original) {
        case .unreadable, .unsupported: throw AgentConnectorError(message: Self.titleUnreadable)
        case .present, .missing: break
        }
        let marketplace = marketplaceFolder(for: target.folder)
        let files = expectedFiles(installation).map { (marketplace.appendingPathComponent($0.key), $0.value) } + [(executable, filled(script))]
        let executable = self.executable
        let failure: String? = await Task.detached {
            do {
                for (url, text) in files {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: url, options: .atomic)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { throw AgentConnectorError(message: failure) }
        let added = try await output(tool, ["plugin", "marketplace", "add", marketplace.path], subcommand: "plugin marketplace add", target: target)
        if added.status != 0, !Self.mentions(await Self.read(config), marketplace: layout.marketplace, at: marketplace.path) {
            throw AgentConnectorError(message: Self.problem(added))
        }
        try await call(tool, ["plugin", "add", layout.pluginId], subcommand: "plugin add", target: target)
        try await addTitleItem(target)
    }

    private func addTitleItem(_ target: ConnectorTarget) async throws {
        let config = configURL(target.folder)
        let current = await Self.read(config)
        guard CodexTitleItem.inspect(current) != .present else { return }
        guard let (text, record) = CodexTitleItem.adding(to: current) else { throw AgentConnectorError(message: Self.titleUnreadable) }
        let recordURL = titleRecordURL(target.folder)
        let failure: String? = await Task.detached {
            do {
                try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
                try Data(text.utf8).write(to: config, options: .atomic)
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
        if removed.status != 0, (await Self.read(config))?.contains("\"\(layout.pluginId)\"") == true { throw AgentConnectorError(message: Self.problem(removed)) }
        let marketplace = marketplaceFolder(for: target.folder)
        let left = try await output(tool, ["plugin", "marketplace", "remove", layout.marketplace], subcommand: "plugin marketplace remove", target: target)
        if left.status != 0, Self.mentions(await Self.read(config), marketplace: layout.marketplace, at: marketplace.path) {
            throw AgentConnectorError(message: Self.problem(left))
        }
        let recordURL = titleRecordURL(target.folder)
        let codexFolder = self.codexFolder
        let executable = self.executable
        let failure: String? = await Task.detached {
            do {
                if let data = FileManager.default.contents(atPath: recordURL.path), let record = try? JSONDecoder().decode(CodexTitleItem.Record.self, from: data) {
                    let current = FileManager.default.contents(atPath: config.path).map { String(decoding: $0, as: UTF8.self) }
                    if let restored = CodexTitleItem.removing(from: current, record: record), restored != current {
                        try Data(restored.utf8).write(to: config, options: .atomic)
                    }
                }
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

    private nonisolated static func read(_ url: URL) async -> String? {
        await Task.detached { FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } }.value
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
        manualUninstallLead: "To remove the plugin from Codex, run these in a terminal:",
        manualUninstallAfterDisconnect: "Disconnected from \(Branding.appName). Run these in a terminal to finish uninstalling:",
        stillConnected: { _ in "" },
        setupTitle: "Plugin",
        purpose: "Dictate to a Codex conversation by name and hear its replies read aloud.",
        installNote: "Installing also adds the thread-id item to Codex\u{2019}s terminal title ([tui] terminal_title in config.toml), so \(Branding.appName) can tell which terminal shows which conversation. Uninstalling removes only that item.",
        folderNoun: "Codex home",
        foldersHelp: "A Codex home is where Codex keeps its settings and conversations: ~/.codex, or the folder CODEX_HOME names. Each one is connected and removed on its own.")
}
