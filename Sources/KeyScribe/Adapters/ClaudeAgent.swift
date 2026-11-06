import Foundation
import KeyScribeKit

@MainActor
final class ClaudeDiscovery: AgentDiscovery {
    let kind = AgentKind.claude
    private let scanRegistry: @Sendable () -> [ClaudeRegistryEntry]?
    private let titles: ClaudeTranscriptTitles?
    private let running: (RememberedName) -> Bool

    init(
        scan: @escaping @Sendable () -> [ClaudeRegistryEntry]?, titles: ClaudeTranscriptTitles? = nil,
        stillRunning: @escaping (RememberedName) -> Bool = ClaudeRegistryScanner.stillRunning
    ) {
        scanRegistry = scan
        self.titles = titles
        running = stillRunning
    }

    convenience init(configDirs: [URL]) {
        self.init(scan: { ClaudeRegistryScanner.scan(configDirs: configDirs) }, titles: ClaudeTranscriptTitles(configDirs: configDirs))
    }

    func scan(rereadingTitles: Bool) async -> AgentScan {
        let (scanRegistry, titles) = (scanRegistry, titles)
        return await Task.detached {
            guard let found = scanRegistry() else {
                return .unreadable("The Claude Code session list could not be read, so these are the sessions last seen.")
            }
            titles?.forget(keeping: Set(found.map(\.sessionId)))
            return .found(found.map { entry in
                var session = entry.session
                if let recorded = titles?.titles(for: entry, rereading: rereadingTitles) {
                    session.title = AgentTitle(explicitName: recorded.explicitName, generatedTitle: recorded.generatedTitle)
                }
                return session
            })
        }.value
    }

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
        now: @escaping () -> Date = Date.init, makeId: @escaping () -> String = { UUID().uuidString },
        stillRunning: @escaping (RememberedName) -> Bool = ClaudeRegistryScanner.stillRunning
    ) {
        self.init(
            transport: transport, discovery: [ClaudeDiscovery(scan: scan, titles: transcriptTitles, stillRunning: stillRunning)],
            names: names, focus: focus, front: front, glance: glance, receiptTimeout: receiptTimeout, handOffLimit: handOffLimit,
            disconnectGrace: disconnectGrace, scanDeadline: scanDeadline, now: now, makeId: makeId)
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

    static func run(_ argv: [String], timeout: TimeInterval = 120, grace: TimeInterval = 2) -> (Int32, String) {
        ToolCLI.run(argv, timeout: timeout, grace: grace)
    }
}

@MainActor
final class ClaudeConnector: AgentConnector {
    let kind = AgentKind.claude
    private let locate: () -> String?
    private let run: @Sendable ([String]) -> (Int32, String)
    private let agentsDir: URL
    private let pluginName: String
    private let script: String?

    init(
        locate: @escaping () -> String? = { ClaudeCLI.locate() },
        run: @escaping @Sendable ([String]) -> (Int32, String) = { ClaudeCLI.run($0) },
        agentsDir: URL, pluginName: String, script: String? = ClaudeConnectorFiles.registerJS
    ) {
        self.locate = locate
        self.run = run
        self.agentsDir = agentsDir
        self.pluginName = pluginName
        self.script = script
    }

    private var pluginId: String { "\(pluginName)@\(pluginName)-local" }
    var isBundled: Bool { script != nil }
    var hasFiles: Bool { FileManager.default.fileExists(atPath: ClaudeConnectorInstaller.marketplaceDir(in: agentsDir).path) }
    var wasRemoved: Bool { ClaudeConnectorInstaller.wasRemoved(in: agentsDir) }
    var manualUninstall: [String] { ClaudeConnectorInstaller.manualUninstall(pluginName: pluginName) }

    func locateTool() -> String? { locate() }

    func check(tool: String) async -> AgentConnectorModel.State {
        guard let script else { return .unavailable }
        let (run, pluginId) = (run, pluginId)
        let (status, output) = await Task.detached { run([tool, "plugin", "list", "--json"]) }.value
        guard status == 0 else { return .failed(Self.trimmed(output)) }
        let found = AgentConnectorStatus.parse(pluginList: Data(output.utf8), pluginId: pluginId, bundledVersion: ClaudeConnectorFiles.version(for: script))
        let registered = switch found {
        case .ready, .outdated, .disabled: true
        case .notInstalled, .unknown: false
        }
        let leftOver = registered || hasFiles
        return leftOver && wasRemoved ? .removalUnfinished(nil) : .status(found)
    }

    func install(tool: String) async throws { try await perform(tool) { try $0.install() } }
    func update(tool: String) async throws { try await perform(tool) { try $0.update() } }
    func uninstall(tool: String) async throws { try await perform(tool) { try $0.uninstall() } }
    func disable() throws { try ClaudeConnectorInstaller.disable(in: agentsDir) }

    private func perform(_ tool: String, _ action: @escaping @Sendable (ClaudeConnectorInstaller) throws -> Void) async throws {
        guard let script else { throw AgentConnectorError(message: copy.unavailable) }
        let installer = ClaudeConnectorInstaller(
            agentsDir: agentsDir, pluginName: pluginName, claude: tool,
            socketPath: agentsDir.appendingPathComponent("bridge.sock").path,
            tokenPath: agentsDir.appendingPathComponent("token").path,
            readyPath: agentsDir.appendingPathComponent("ready.json").path,
            script: script, run: run)
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
        help: "\(Branding.appName) reaches Claude Code through a small plugin installed for your user account. Installed means the plugin is in place; each session then connects on its own.",
        reloadHint: "Already running Claude Code? Run /reload-plugins once in each open session. New sessions connect on their own once you trust their folder.",
        uninstallTitle: "Uninstall the Claude Code connector?",
        uninstallMessage: "Open Claude Code sessions disconnect now, and new ones will not connect. Work you already sent may still finish. Each open session unloads the connector when you run /reload-plugins in it or restart it. Your conversation names and other \(Branding.appName) settings are kept.",
        noSessions: "No Claude Code sessions are running.",
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

extension CodingAgentsSettingsModel {
    convenience init(
        locateClaude: @escaping () -> String? = { ClaudeCLI.locate() },
        run: @escaping @Sendable ([String]) -> (Int32, String) = { ClaudeCLI.run($0) },
        describeTerminal: @escaping @Sendable (Int) -> String? = TerminalDescription.describe(pid:),
        agentsDir: URL, pluginName: String, script: String? = ClaudeConnectorFiles.registerJS
    ) {
        self.init(
            describeTerminal: describeTerminal, agentsDir: agentsDir,
            connectors: [ClaudeConnector(locate: locateClaude, run: run, agentsDir: agentsDir, pluginName: pluginName, script: script)])
    }
}
