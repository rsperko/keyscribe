import CryptoKit
import Foundation
import KeyScribeKit

enum BBSidebarSwitch: String, CaseIterable {
    case experiment, rowMetadata

    var read: [String] {
        switch self {
        case .experiment: ["settings", "show", "--json"]
        case .rowMetadata: ["thread-list", "prefs", "get", "showRowMetadata", "--json"]
        }
    }

    var readSubcommand: String { self == .experiment ? "settings show" : "thread-list prefs get" }
    var setSubcommand: String { self == .experiment ? "settings experiment" : "thread-list prefs set" }

    func set(_ on: Bool) -> [String] {
        switch self {
        case .experiment: ["settings", "experiment", "threadRowMetadata", on ? "true" : "false", "--json"]
        case .rowMetadata: ["thread-list", "prefs", "set", "showRowMetadata", on ? "true" : "false", "--json"]
        }
    }

    func isOn(_ stdout: Data) -> Bool? {
        guard let object = BBPluginFiles.json(stdout) else { return nil }
        switch self {
        case .experiment: return (object["experiments"] as? [String: Any])?["threadRowMetadata"] as? Bool
        case .rowMetadata: return object["key"] as? String == "showRowMetadata" ? object["value"] as? Bool : nil
        }
    }
}

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

    static func json(_ stdout: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] }

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
    let id: String
    private let agentsDir: URL
    private let sources: [String: String]?
    private let isExecutable: (String) -> Bool
    private let run: Run
    private let home: URL
    private let find: @MainActor () async -> [BBBuild]
    private let isOpen: @MainActor (BBBuild) -> Bool
    private(set) var builds: [BBBuild] = []
    private var preferred: BBBuild?
    private var added: [String: BBBuild] = [:]
    private let isDataFolder: (String) -> Bool
    private let describe: (String) -> BBBuild?

    init(
        agentsDir: URL, pluginName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        sources: [String: String]? = BBPluginFiles.sources,
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        run: @escaping Run = { try await HostCLI.run($0, subcommand: $1, input: $2, environment: $3, timeout: .seconds(120)) },
        find: (@MainActor () async -> [BBBuild])? = nil,
        isOpen: @escaping @MainActor (BBBuild) -> Bool = BBBuildFinder.isOpen,
        isDataFolder: @escaping (String) -> Bool = BBBuildFinder.isDataFolder,
        describe: ((String) -> BBBuild?)? = nil
    ) {
        self.isDataFolder = isDataFolder
        self.describe = describe ?? { [path = home.path] in BBBuildFinder.describe(folder: $0, home: path) }
        self.agentsDir = agentsDir
        id = pluginName
        self.home = home
        self.sources = sources
        self.isExecutable = isExecutable
        self.run = run
        self.find = find ?? {
            let apps = BBBuildFinder.runningApps
            let path = home.path
            let declared = ToolEnvironment.shared.folder(BBBuilds.dataFolderKey).map { [$0] } ?? []
            return await Task.detached { BBBuildFinder.find(home: path, apps: apps, also: declared) }.value
        }
        self.isOpen = isOpen
    }

    private var usualFolder: URL { home.appendingPathComponent(BBBuilds.usualFolder, isDirectory: true) }

    var defaultFolder: URL { preferred.map { URL(fileURLWithPath: $0.folder, isDirectory: true) } ?? usualFolder }

    var foundFolders: [URL] { builds.map { URL(fileURLWithPath: $0.folder, isDirectory: true) } }

    func rediscover() async {
        builds = await find()
        preferred = BBBuilds.preferred(builds, open: isOpen, home: ConnectorFolders.canonical(home).path)
    }

    func name(of folder: URL) -> String? { (builds.first { $0.folder == folder.path } ?? added[folder.path])?.name }

    private func pluginDir(_ folder: URL) -> URL {
        guard ConnectorFolders.canonical(folder) != ConnectorFolders.canonical(usualFolder) else { return agentsDir.appendingPathComponent("bb-plugin", isDirectory: true) }
        let digest = SHA256.hash(data: Data(ConnectorFolders.canonical(folder).path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return agentsDir.appendingPathComponent("bb-plugin-\(digest)", isDirectory: true)
    }

    private func configURL(_ folder: URL) -> URL { pluginDir(folder).appendingPathComponent("keyscribe.json") }

    var isBundled: Bool { sources != nil }
    var bundledVersion: String? { sources.map(BBPluginFiles.version) }

    func hasFiles(in target: ConnectorTarget) -> Bool { FileManager.default.fileExists(atPath: pluginDir(target.folder).path) }

    func manualUninstall(for target: ConnectorTarget) -> [String] {
        let bb = ShellWord.path(target.folder.appendingPathComponent(BBBuilds.launcherPath).path, home: home.path)
        return ["\(bb) plugin remove \(id)", "rm -r \(ShellWord.path(pluginDir(target.folder).path, home: home.path))"]
    }

    func recognizes(folder: URL) -> Bool {
        let path = ConnectorFolders.canonical(folder).path
        guard isDataFolder(path) else { return false }
        if let build = describe(path) { added[path] = build }
        return true
    }

    var folderVariable: String? { BBBuilds.dataFolderKey }

    func findTool(in folder: URL, chosen: String?) -> ToolSearch.Result {
        let place = ToolSearch.Place(path: folder.appendingPathComponent(BBBuilds.launcherPath).path, source: .usual)
        return ToolSearch.Result(tool: isExecutable(place.path) ? place : nil, searched: [place])
    }


    private func filesCurrent(_ sources: [String: String], target: ConnectorTarget, installation: String) -> Bool {
        let expected = BBPluginFiles.config(
            agentsDir: agentsDir, instance: target.folder.path, installation: installation, version: BBPluginFiles.version(for: sources))
        guard String(decoding: FileManager.default.contents(atPath: configURL(target.folder).path) ?? Data(), as: UTF8.self) == expected else { return false }
        let plugin = pluginDir(target.folder)
        return BBPluginFiles.written(sources, id: id).allSatisfy { name, text in
            (try? String(contentsOf: plugin.appendingPathComponent(name), encoding: .utf8)) == text
        }
    }

    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
        guard let sources else { return .unavailable }
        let plugin = pluginDir(target.folder)
        let config = FileManager.default.contents(atPath: configURL(target.folder).path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if target.removing { return config == nil ? .status(.notInstalled) : .removalUnfinished(nil) }
        guard let installation = target.installation, let config else { return .status(.notInstalled) }
        let installed = config["version"] as? String ?? ""
        let listing = try? await output(tool, ["plugin", "list", "--json"], subcommand: "plugin list", target: target)
        guard let listing, listing.status == 0, let found = BBPluginFiles.listed(listing.stdout, id: id, folder: plugin.path) else {
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
        let folder = pluginDir(target.folder)
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
        await showNamesInSidebar(tool, target: target)
    }

    private func sidebarURL(_ folder: URL) -> URL { pluginDir(folder).appendingPathComponent("sidebar.json") }

    private func turnedOn(_ target: ConnectorTarget) -> [BBSidebarSwitch]? {
        guard let data = FileManager.default.contents(atPath: sidebarURL(target.folder).path),
              let names = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["turnedOn"] as? [String]
        else { return nil }
        return names.compactMap(BBSidebarSwitch.init(rawValue:))
    }

    private func showNamesInSidebar(_ tool: String, target: ConnectorTarget) async {
        guard turnedOn(target) == nil else { return }
        var states: [BBSidebarSwitch: Bool] = [:]
        for item in BBSidebarSwitch.allCases {
            guard let read = try? await output(tool, item.read, subcommand: item.readSubcommand, target: target), read.status == 0,
                  let on = item.isOn(read.stdout)
            else { return }
            states[item] = on
        }
        var changed: [BBSidebarSwitch] = []
        for item in BBSidebarSwitch.allCases where states[item] == false {
            if (try? await call(tool, item.set(true), subcommand: item.setSubcommand, target: target)) != nil { changed.append(item) }
        }
        let record = try? JSONSerialization.data(withJSONObject: ["turnedOn": changed.map(\.rawValue)])
        try? record?.write(to: sidebarURL(target.folder), options: .atomic)
    }

    func undoesOnUninstall(in target: ConnectorTarget) -> Bool { !(turnedOn(target) ?? []).isEmpty }

    func uninstall(tool: String, target: ConnectorTarget, undoing: Bool) async throws {
        if undoing {
            for item in turnedOn(target) ?? [] { try? await call(tool, item.set(false), subcommand: item.setSubcommand, target: target) }
        }
        try await uninstall(tool: tool, target: target)
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
        let folder = pluginDir(target.folder)
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
        let environment = BBBuildFinder.environment(folder: target.folder.path, home: home.path)
        do {
            return try await run([tool] + arguments, subcommand, nil, environment)
        } catch {
            throw AgentConnectorError(message: "bb \(subcommand) did not finish: \(error)")
        }
    }

    let copy = AgentConnectorCopy(
        help: "With a small plugin installed in bb, \(Branding.appName) lists the threads bb runs, sends what you say to them through bb\u{2019}s own command, into a turn already running the way typing in bb would, and hears how they answer and what they stop to ask you; each bb window tells the plugin which thread it shows, so dictation goes to the thread you are looking at. Every thread connects on its own unless you disconnect it. \(Branding.appName) runs nothing of bb\u{2019}s until you connect bb. If bb loses the plugin, dictation still reaches its threads by name, but replies are not read aloud and \(Branding.appName) no longer knows which thread is in front until you reinstall it.",
        reloadHint: "",
        uninstallTitle: "Uninstall the plugin from bb?",
        uninstallMessage: "\(Branding.appName) stops listing bb threads and sending to them. bb, its threads, your conversation names and disconnections, and other \(Branding.appName) settings are kept.",
        toolNotFoundLabel: "bb not found",
        toolNotFoundAdvice: "Install bb and open it once, or add its data folder with Add Folder\u{2026}. \(Branding.appName) finds bb from the command bb sets up in its data folder when it opens.",
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
        setupTitle: "Plugin",
        purpose: "Dictate to the bb thread you are looking at and hear its replies read aloud.",
        installNote: "To show the name to say for each thread, it turns on bb\u{2019}s thread row details (Organize \u{25B8} Rows \u{25B8} Metadata, which bb still calls experimental); a thread whose bb title already says its name shows nothing extra.",
        undoOnUninstallLabel: "Uninstall and Turn Off Row Details",
        undoOnUninstallNote: "\(Branding.appName) turned on bb\u{2019}s thread row details to show thread names. Choose whether to turn them back off; other plugins also draw there.",
        folderNoun: "data folder",
        foldersHelp: "A data folder is where a bb build keeps its threads and the bb command it sets up. \(Branding.appName) lists the usual folder (~/.bb), each hidden folder in your home folder that holds a bb command, the folder a running bb declares, and BB_DATA_DIR from your login shell. If your bb keeps its data somewhere else, choose Add Folder\u{2026}; each build is connected and removed on its own.")
}
