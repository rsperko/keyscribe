import Foundation
import KeyScribeKit

enum BBPluginFiles {
    static let names = ["package.json", "server.ts", "keyscribe.ts", "app.tsx", "PLUGIN_OVERVIEW.md"]

    static let sources: [String: String]? = {
        var found: [String: String] = [:]
        for name in names {
            let dot = name.lastIndex(of: ".")!
            let base = String(name[..<dot])
            let ext = String(name[name.index(after: dot)...])
            guard let text = ConnectorResources.text(named: base, extension: ext, subdirectory: "BBPlugin") else { return nil }
            found[name] = text
        }
        return found
    }()

    static func version(for sources: [String: String]) -> String {
        ConnectorResources.version(for: names.map { "\($0)\n\(sources[$0] ?? "")" }.joined(separator: "\n"))
    }

    static func manifest(_ text: String, id: String) -> String {
        guard var manifest = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return text }
        manifest["name"] = "bb-plugin-\(id)"
        var bb = manifest["bb"] as? [String: Any] ?? [:]
        bb["name"] = Branding.appName
        bb["description"] = "Lets \(Branding.appName) read aloud the replies to what you dictate to bb threads, say what a thread waits on, and know which thread you are looking at."
        manifest["bb"] = bb
        return ConnectorResources.json(manifest)
    }

    static func written(_ sources: [String: String], id: String) -> [String: String] {
        sources.reduce(into: [:]) { files, entry in files[entry.key] = entry.key == "package.json" ? manifest(entry.value, id: id) : entry.value }
    }

    static func config(agentsDir: URL, instance: String, installation: String, version: String) -> String {
        ConnectorResources.json([
            "protocol": AgentBridgeCodec.protocolVersion, "socketPath": agentsDir.appendingPathComponent("bridge.sock").path,
            "tokenPath": agentsDir.appendingPathComponent("token").path, "readyPath": agentsDir.appendingPathComponent("ready.json").path,
            "installation": installation, "instance": instance, "version": version, "appName": Branding.appName,
        ])
    }

    static func problem(status: Int32, stdout: Data, stderr: String) -> String? {
        guard status != 0 else { return nil }
        struct Failed: Decodable {
            struct Problem: Decodable { var code: String?; var message: String? }
            var error: Problem?
        }
        if let message = (try? JSONDecoder().decode(Failed.self, from: stdout))?.error?.message, !message.isEmpty { return message }
        let said = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "bb did not say why." : String(said.prefix(300))
    }

    static func notInstalled(stdout: Data) -> Bool {
        struct Failed: Decodable {
            struct Problem: Decodable { var code: String? }
            var error: Problem?
        }
        return (try? JSONDecoder().decode(Failed.self, from: stdout))?.error?.code == "plugin_not_found"
    }

    struct Listed: Equatable {
        var enabled: Bool
        var status: String
        var detail: String?
    }

    static func listed(_ stdout: Data, id: String, folder: String) -> Listed?? {
        struct Plugins: Decodable {
            struct Plugin: Decodable {
                var id: String
                var enabled: Bool?
                var status: String?
                var statusDetail: String?
                var source: String?
            }
            var plugins: [Plugin]
        }
        guard let plugins = try? JSONDecoder().decode(Plugins.self, from: stdout) else { return nil }
        guard let plugin = plugins.plugins.first(where: { $0.id == id }), plugin.source == "path:\(folder)" else { return .some(nil) }
        return .some(Listed(enabled: plugin.enabled ?? true, status: plugin.status ?? "", detail: plugin.statusDetail))
    }
}

@MainActor
final class BBPluginConnector: AgentConnector {
    typealias Run = BBHost.Run

    let kind = BBHost.kind
    let defaultFolder: URL
    let id: String
    private let agentsDir: URL
    private let sources: [String: String]?
    private let isExecutable: (String) -> Bool
    private let run: Run
    private let home: URL

    init(
        agentsDir: URL, pluginName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        sources: [String: String]? = BBPluginFiles.sources,
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        run: @escaping Run = { try await HostCLI.run($0, subcommand: $1, input: $2, environment: $3, timeout: .seconds(120)) }
    ) {
        self.agentsDir = agentsDir
        id = pluginName
        self.home = home
        self.sources = sources
        self.isExecutable = isExecutable
        self.run = run
        defaultFolder = home.appendingPathComponent(".bb", isDirectory: true)
    }

    private var pluginDir: URL { agentsDir.appendingPathComponent("bb-plugin", isDirectory: true) }
    private var configURL: URL { pluginDir.appendingPathComponent("keyscribe.json") }

    var isBundled: Bool { sources != nil }
    var bundledVersion: String? { sources.map(BBPluginFiles.version) }

    func hasFiles(in target: ConnectorTarget) -> Bool { FileManager.default.fileExists(atPath: pluginDir.path) }

    func manualUninstall(for target: ConnectorTarget) -> [String] {
        let bb = ShellWord.path(target.folder.appendingPathComponent("bin/bb").path, home: home.path)
        return ["\(bb) plugin remove \(id)", "rm -r \(ShellWord.path(pluginDir.path, home: home.path))"]
    }

    func recognizes(folder: URL) -> Bool { ConnectorFolders.contains(any: ["bin/bb", "thread-storage"], in: folder) }

    func locateTool() -> String? {
        let tool = defaultFolder.appendingPathComponent("bin/bb").path
        return isExecutable(tool) ? tool : nil
    }

    private func filesCurrent(_ sources: [String: String], target: ConnectorTarget, installation: String) -> Bool {
        let expected = BBPluginFiles.config(
            agentsDir: agentsDir, instance: target.folder.path, installation: installation, version: BBPluginFiles.version(for: sources))
        guard String(decoding: FileManager.default.contents(atPath: configURL.path) ?? Data(), as: UTF8.self) == expected else { return false }
        return BBPluginFiles.written(sources, id: id).allSatisfy { name, text in
            (try? String(contentsOf: pluginDir.appendingPathComponent(name), encoding: .utf8)) == text
        }
    }

    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
        guard let sources else { return .unavailable }
        let config = FileManager.default.contents(atPath: configURL.path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if target.removing { return config == nil ? .status(.notInstalled) : .removalUnfinished(nil) }
        guard let installation = target.installation, let config else { return .status(.notInstalled) }
        let installed = config["version"] as? String ?? ""
        let listing = try? await output(tool, ["plugin", "list", "--json"], subcommand: "plugin list", target: target)
        guard let listing, listing.status == 0, let found = BBPluginFiles.listed(listing.stdout, id: id, folder: pluginDir.path) else {
            return .status(.unknown)
        }
        guard let plugin = found else { return .status(.notInstalled) }
        if !plugin.enabled || plugin.status == "disabled" { return .status(.disabled) }
        if ["error", "incompatible", "needs-configuration", "degraded"].contains(plugin.status) {
            return .broken("bb reports the plugin as \(plugin.status.replacingOccurrences(of: "-", with: " "))\(plugin.detail.map { ": \($0)" } ?? ".")")
        }
        if plugin.status == "running", let detail = plugin.detail, detail.hasPrefix("reload failed:") {
            return .broken("bb kept the plugin\u{2019}s earlier version running: \(detail)")
        }
        return filesCurrent(sources, target: target, installation: installation) ? .status(.ready) : .status(.outdated(installed: installed))
    }

    func install(tool: String, target: ConnectorTarget) async throws {
        guard let sources else { throw AgentConnectorError(message: copy.unavailable) }
        guard let installation = target.installation else { throw AgentConnectorError(message: copy.noReason) }
        let files = BBPluginFiles.written(sources, id: id).map { ($0.key, $0.value) } + [(
            "keyscribe.json",
            BBPluginFiles.config(agentsDir: agentsDir, instance: target.folder.path, installation: installation, version: BBPluginFiles.version(for: sources))
        )]
        let folder = pluginDir
        let failure: String? = await Task.detached {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic) }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { throw AgentConnectorError(message: failure) }
        let listing = try await output(tool, ["plugin", "list", "--json"], subcommand: "plugin list", target: target)
        if let problem = BBPluginFiles.problem(status: listing.status, stdout: listing.stdout, stderr: listing.stderr) {
            throw AgentConnectorError(message: problem)
        }
        if case .some(.some) = BBPluginFiles.listed(listing.stdout, id: id, folder: folder.path) {
            try await call(tool, ["plugin", "reload", id, "--json"], subcommand: "plugin reload", target: target)
        } else {
            try await call(tool, ["plugin", "install", folder.path, "--yes", "--json"], subcommand: "plugin install", target: target)
        }
    }

    func update(tool: String, target: ConnectorTarget) async throws {
        try await install(tool: tool, target: target)
    }

    func uninstall(tool: String, target: ConnectorTarget) async throws {
        let output = try await output(tool, ["plugin", "remove", id, "--json"], subcommand: "plugin remove", target: target)
        if !BBPluginFiles.notInstalled(stdout: output.stdout),
           let problem = BBPluginFiles.problem(status: output.status, stdout: output.stdout, stderr: output.stderr) {
            throw AgentConnectorError(message: problem)
        }
        let folder = pluginDir
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

    private func call(_ tool: String, _ arguments: [String], subcommand: String, target: ConnectorTarget) async throws {
        let output = try await output(tool, arguments, subcommand: subcommand, target: target)
        if let problem = BBPluginFiles.problem(status: output.status, stdout: output.stdout, stderr: output.stderr) {
            throw AgentConnectorError(message: problem)
        }
    }

    private func output(_ tool: String, _ arguments: [String], subcommand: String, target: ConnectorTarget) async throws -> HostCLI.Output {
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "BB_TELEMETRY": "false", "BB_DATA_DIR": target.folder.path]
        do {
            return try await run([tool] + arguments, subcommand, nil, environment)
        } catch {
            throw AgentConnectorError(message: "bb \(subcommand) did not finish: \(error)")
        }
    }

    let copy = AgentConnectorCopy(
        help: "With a small plugin installed in bb, \(Branding.appName) lists the threads bb runs, sends what you say to them through bb\u{2019}s own command, queued behind any turn already running, and hears how they answer and what they stop to ask you; each bb window tells the plugin which thread it shows, so dictation goes to the thread you are looking at. Every thread connects on its own unless you disconnect it. \(Branding.appName) runs nothing of bb\u{2019}s until you connect bb. If bb loses the plugin, dictation still reaches its threads by name, but replies are not read aloud and \(Branding.appName) no longer knows which thread is in front until you reinstall it.",
        reloadHint: "",
        uninstallTitle: "Uninstall the plugin from bb?",
        uninstallMessage: "\(Branding.appName) stops listing bb threads and sending to them. Your conversation names, disconnected conversations and other \(Branding.appName) settings are kept.",
        toolNotFoundLabel: "bb not found",
        toolNotFoundAdvice: "Install bb, then come back here. \(Branding.appName) looks for bb in its usual folder.",
        unavailable: "This copy of \(Branding.appName) is missing its bb plugin. Reinstall \(Branding.appName) to add it.",
        disabledLabel: "Turned off in bb",
        disabledAdvice: "Turn the plugin back on in bb\u{2019}s settings.",
        removalUnfinishedAdvice: "The plugin was uninstalled in \(Branding.appName), but its files are still in place. Its threads no longer report. Finish uninstalling it, then install it again if you want it back.",
        listUnreadable: "bb didn\u{2019}t answer, so the plugin couldn\u{2019}t be checked. Open bb to check it.",
        noReason: "bb did not say why.",
        manualUninstallLead: "To remove the plugin from bb, run these in a terminal:",
        manualUninstallAfterDisconnect: "Disconnected from \(Branding.appName). Run these in a terminal to finish uninstalling:",
        stillConnected: { count in
            count == 1
                ? "The plugin was removed outside \(Branding.appName), so 1 bb thread is still connected until bb restarts the plugin."
                : "The plugin was removed outside \(Branding.appName), so \(count) bb threads are still connected until bb restarts the plugin."
        },
        setupTitle: "Plugin", describesUse: false,
        purpose: "Dictate to the bb thread you are looking at and hear its replies read aloud.")
}
