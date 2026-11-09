import Foundation
import KeyScribeKit

@MainActor
final class ClaudeDiscovery: AgentDiscovery {
    let kind = AgentKind.claude
    private let scanRegistry: @Sendable () -> ClaudeRegistryScanner.Scan
    private let titles: ClaudeTranscriptTitles?
    private let running: (RememberedName) -> Bool
    private let isRunning: @Sendable (Int) -> Bool
    private var lastByFolder: [String: [ClaudeRegistryEntry]] = [:]

    nonisolated static let partialProblem = "Some Claude Code session lists couldn\u{2019}t be read. Conversations seen earlier stay listed."

    init(
        scanEach: @escaping @Sendable () -> ClaudeRegistryScanner.Scan, titles: ClaudeTranscriptTitles? = nil,
        stillRunning: @escaping (RememberedName) -> Bool = ClaudeRegistryScanner.stillRunning,
        isRunning: @escaping @Sendable (Int) -> Bool = ProcessStart.isRunning(pid:)
    ) {
        scanRegistry = scanEach
        self.titles = titles
        running = stillRunning
        self.isRunning = isRunning
    }

    convenience init(
        scan: @escaping @Sendable () -> [ClaudeRegistryEntry]?, titles: ClaudeTranscriptTitles? = nil,
        stillRunning: @escaping (RememberedName) -> Bool = ClaudeRegistryScanner.stillRunning
    ) {
        self.init(
            scanEach: { scan().map { ClaudeRegistryScanner.Scan(entries: $0, unreadable: []) } ?? ClaudeRegistryScanner.Scan(entries: [], unreadable: [Self.unknownFolder]) },
            titles: titles, stillRunning: stillRunning)
    }

    convenience init(
        enrolled: @escaping @Sendable () -> [URL], defaultFolder: URL = ClaudeConnectorInstaller.defaultSetupFolder(),
        processes: @escaping @Sendable () -> AgentProcesses.Found
    ) {
        self.init(scanEach: {
            let running = processes()
            let fromProcesses = running.setups.map { URL(fileURLWithPath: $0, isDirectory: true) }
            var seen: Set<String> = []
            let dirs = ([ConnectorFolders.canonical(defaultFolder)] + enrolled() + fromProcesses).filter { seen.insert($0.path).inserted }
            var found = ClaudeRegistryScanner.scanEach(configDirs: dirs)
            found.processesUnreadable = running.isPartial
            found.folders = fromProcesses.map(\.path)
            return found
        }, titles: ClaudeTranscriptTitles(configDirs: []))
    }

    convenience init(setups: ConnectorSetupRegistry, processes: AgentProcessTable) {
        self.init(enrolled: {
            (setups.setups?.enrolled(agent: AgentKind.claude.id) ?? []).map { URL(fileURLWithPath: $0.folder, isDirectory: true) }
        }, processes: { processes.found(.claude) })
    }

    func scan(rereadingTitles: Bool) async -> AgentScan {
        let (scanRegistry, titles, previous, isRunning) = (scanRegistry, titles, lastByFolder, isRunning)
        let (scan, kept) = await Task.detached { () -> (AgentScan, [String: [ClaudeRegistryEntry]]) in
            let found = scanRegistry()
            var entries = found.entries
            var carried: Set<String> = []
            for folder in found.unreadable {
                for entry in previous[folder] ?? [] where !entries.contains(where: { $0.sessionId == entry.sessionId }) && isRunning(entry.pid) {
                    entries.append(entry)
                    carried.insert(entry.sessionId)
                }
            }
            titles?.forget(keeping: Set(entries.map(\.sessionId)))
            let sessions = entries.map { entry in
                var session = entry.session
                if let recorded = titles?.titles(for: entry, rereading: rereadingTitles) {
                    session.title = AgentTitle(
                        explicitName: recorded.explicitName, generatedTitle: recorded.generatedTitle ?? session.title.generatedTitle)
                }
                return session
            }
            var setups: [String] = []
            for setup in found.folders + entries.compactMap(\.configDir) where !setups.contains(setup) { setups.append(setup) }
            let problem = found.unreadable.isEmpty && !found.processesUnreadable ? nil : Self.partialProblem
            let kept = Dictionary(grouping: entries) { $0.configDir ?? Self.unknownFolder }
            return (.found(sessions, AgentScanExtras(setups: setups, problem: problem, carried: carried)), kept)
        }.value
        lastByFolder = kept
        return scan
    }

    nonisolated static let unknownFolder = ""

    func stillRunning(_ remembered: RememberedName) -> Bool {
        running(remembered)
    }
}

extension AgentHub {
    convenience init(
        transport: AgentTransport, scan: @escaping @Sendable () -> [ClaudeRegistryEntry]?, names: AgentNameStore? = nil,
        focus: AgentTerminalFocusing? = nil, front: AgentFronting? = nil, glance: AgentFronting? = nil, transcriptTitles: ClaudeTranscriptTitles? = nil,
        receiptTimeout: Duration = .seconds(8), handOffLimit: Duration = .seconds(30),
        disconnectGrace: Duration = AgentHub.defaultDisconnectGrace, scanDeadline: Duration = AgentHub.defaultScanDeadline,
        places: (any AgentPlaceReading)? = nil,
        now: @escaping () -> Date = Date.init, makeId: @escaping () -> String = { UUID().uuidString },
        stillRunning: @escaping (RememberedName) -> Bool = ClaudeRegistryScanner.stillRunning
    ) {
        self.init(
            transport: transport, discovery: [ClaudeDiscovery(scan: scan, titles: transcriptTitles, stillRunning: stillRunning)],
            names: names, focus: focus, front: front, glance: glance, receiptTimeout: receiptTimeout, handOffLimit: handOffLimit,
            disconnectGrace: disconnectGrace, scanDeadline: scanDeadline, places: places, now: now, makeId: makeId)
    }
}

enum ClaudeCLI {
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        ToolCLI.locate(
            named: "claude", environment: environment, home: home, alsoIn: [home.appendingPathComponent(".claude/local").path],
            isExecutable: isExecutable)
    }

    static func run(_ argv: [String], environment: [String: String], timeout: TimeInterval = 120, grace: TimeInterval = 2) -> (Int32, String) {
        ToolCLI.run(argv, timeout: timeout, grace: grace, environment: environment)
    }
}

@MainActor
final class ClaudeConnector: AgentConnector {
    let kind = AgentKind.claude
    let defaultFolder: URL
    private let locate: () -> String?
    private let run: @Sendable ([String], [String: String]) -> (Int32, String)
    private let agentsDir: URL
    private let pluginName: String
    private let script: String?
    private let baseEnvironment: [String: String]

    init(
        locate: @escaping () -> String? = { ClaudeCLI.locate() },
        run: @escaping @Sendable ([String], [String: String]) -> (Int32, String) = { ClaudeCLI.run($0, environment: $1) },
        agentsDir: URL, pluginName: String, script: String? = ClaudeConnectorFiles.registerJS,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.locate = locate
        self.run = run
        self.agentsDir = agentsDir
        self.pluginName = pluginName
        self.script = script
        self.baseEnvironment = baseEnvironment
        defaultFolder = ClaudeConnectorInstaller.defaultSetupFolder(home: home)
    }

    private var pluginId: String { "\(pluginName)@\(pluginName)-local" }
    var isBundled: Bool { script != nil }
    var bundledVersion: String? { script.map(ClaudeConnectorFiles.version(for:)) }

    func hasFiles(in target: ConnectorTarget) -> Bool {
        FileManager.default.fileExists(atPath: ClaudeConnectorInstaller.marketplaceDir(in: agentsDir, setupFolder: target.folder).path)
    }

    func manualUninstall(for target: ConnectorTarget) -> [String] {
        ClaudeConnectorInstaller.manualUninstall(pluginName: pluginName, setupFolder: target.folder, isDefault: target.isDefault)
    }

    func recognizes(folder: URL) -> Bool {
        ConnectorFolders.contains(any: ["settings.json", ".credentials.json", "sessions", "projects", "plugins"], in: folder)
    }

    func locateTool() -> String? { locate() }

    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
        guard let script else { return .unavailable }
        let (run, pluginId) = (run, pluginId)
        let environment = ClaudeConnectorInstaller.environment(for: target.folder, isDefault: target.isDefault, base: baseEnvironment)
        let (status, output) = await Task.detached { run([tool, "plugin", "list", "--json"], environment) }.value
        guard status == 0 else { return .failed(Self.trimmed(output)) }
        let found = AgentConnectorStatus.parse(pluginList: Data(output.utf8), pluginId: pluginId, bundledVersion: ClaudeConnectorFiles.version(for: script))
        let registered = switch found {
        case .ready, .outdated, .disabled: true
        case .notInstalled, .unknown: false
        }
        if target.removing { return registered || hasFiles(in: target) ? .removalUnfinished(nil) : .status(.notInstalled) }
        guard target.installation != nil else { return found == .unknown ? .status(.unknown) : .status(.notInstalled) }
        return .status(found)
    }

    func install(tool: String, target: ConnectorTarget) async throws {
        guard let installation = target.installation else { throw AgentConnectorError(message: copy.noReason) }
        try await perform(tool, target) { try $0.install(installation: installation) }
    }

    func update(tool: String, target: ConnectorTarget) async throws {
        guard let installation = target.installation else { throw AgentConnectorError(message: copy.noReason) }
        try await perform(tool, target) { try $0.update(installation: installation) }
    }

    func uninstall(tool: String, target: ConnectorTarget) async throws { try await perform(tool, target) { try $0.uninstall() } }

    private func perform(_ tool: String, _ target: ConnectorTarget, _ action: @escaping @Sendable (ClaudeConnectorInstaller) throws -> Void) async throws {
        guard let script else { throw AgentConnectorError(message: copy.unavailable) }
        let run = run
        let installer = ClaudeConnectorInstaller(
            agentsDir: agentsDir, setupFolder: target.folder, isDefaultSetup: target.isDefault, pluginName: pluginName, claude: tool,
            socketPath: agentsDir.appendingPathComponent("bridge.sock").path,
            tokenPath: agentsDir.appendingPathComponent("token").path,
            readyPath: agentsDir.appendingPathComponent("ready.json").path,
            script: script, run: run, baseEnvironment: baseEnvironment)
        let failure: String? = await Task.detached {
            do {
                try action(installer)
                return nil
            } catch let error as ClaudeConnectorInstaller.InstallError {
                return Self.trimmed(error.output.isEmpty ? "\(error.command.dropFirst().joined(separator: " ")) failed (\(error.status))" : error.output)
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
        help: "\(Branding.appName) reaches Claude Code through a small plugin installed in the folder Claude Code loads its configuration from. Installed means the plugin is in place; each conversation using this folder then connects on its own, unless you disconnect it.",
        reloadHint: "Already running Claude Code here? Run /reload-plugins once in each open conversation. New conversations connect on their own once you trust their folder.",
        uninstallTitle: "Uninstall the Claude Code connector from this folder?",
        uninstallMessage: "Claude Code conversations using this folder disconnect now, and new ones will not connect. Work you already sent may still finish. Each open conversation unloads the connector when you run /reload-plugins in it or restart it. Other folders stay connected, and your conversation names, disconnected conversations and other \(Branding.appName) settings are kept.",
        toolNotFoundLabel: "Claude Code not found",
        toolNotFoundAdvice: "Install Claude Code, then come back here. \(Branding.appName) looks for the claude command on your PATH and in the usual install folders.",
        unavailable: "This copy of \(Branding.appName) is missing its Claude Code connector. Reinstall \(Branding.appName) to connect Claude Code.",
        disabledLabel: "Turned off in Claude Code",
        disabledAdvice: "Turn the plugin back on with /plugin in Claude Code.",
        removalUnfinishedAdvice: "The connector was uninstalled in \(Branding.appName), but Claude Code has not finished removing it. Its sessions no longer connect. Finish uninstalling it, then install it again if you want it back.",
        listUnreadable: "Claude Code's plugin list could not be read.",
        noReason: "Claude Code did not say why.",
        manualUninstallLead: "To remove the connector from Claude Code, run these in a terminal, then run /reload-plugins in each open session or restart it:",
        manualUninstallAfterDisconnect: "Disconnected from \(Branding.appName). Run these in a terminal to finish uninstalling, then run /reload-plugins in each open session or restart it:",
        stillConnected: { count in
            count == 1
                ? "The connector was uninstalled outside \(Branding.appName), so 1 open session is still connected and keeps receiving what you say until you run /reload-plugins in it or restart it."
                : "The connector was uninstalled outside \(Branding.appName), so \(count) open sessions are still connected and keep receiving what you say until you run /reload-plugins in each one or restart them."
        })
}
