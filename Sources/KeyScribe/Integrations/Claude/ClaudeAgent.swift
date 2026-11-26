import Foundation
import KeyScribeKit

@MainActor
final class ClaudeDiscovery: AgentDiscovery {
    let kind = AgentKind.claude
    private let scanRegistry: @Sendable (_ reusingProcesses: Bool) -> ClaudeRegistryScanner.Scan
    private let titles: ClaudeTranscriptTitles?
    private let running: (RememberedName) -> Bool
    private let isRunning: @Sendable (Int) -> Bool
    private var lastByFolder: [String: [ClaudeRegistryEntry]] = [:]
    private(set) var watchedFolders: [URL] = []
    private let now: () -> Date
    private let watchTranscript: TranscriptWatch
    private let spacing: @Sendable (Duration) async -> Void
    private var retitled: ((_ native: String, _ title: AgentTitle) -> Void)?
    private var titleWatches: [String: (id: UUID, until: Date, task: Task<Void, Never>)] = [:]
    private var awaitingScan: [String: Date] = [:]
    private var rereads = 0
    private var readSinceScan: [String: (title: AgentTitle, read: Int)] = [:]

    typealias TranscriptWatch = @Sendable (URL, @escaping @Sendable () -> Void) -> (@Sendable () -> Void)?

    nonisolated static let titleWatch: TimeInterval = 120
    nonisolated static let titleRecheck: TimeInterval = 5
    nonisolated static let titleWatchLimit = 32

    func follow(_ retitled: @escaping (_ native: String, _ title: AgentTitle) -> Void) {
        self.retitled = retitled
    }

    private func report(_ recorded: ClaudeTranscriptTitle, of session: String, _ entry: ClaudeRegistryEntry) {
        let title = AgentTitle(explicitName: recorded.explicitName, generatedTitle: recorded.generatedTitle ?? entry.session.title.generatedTitle)
        rereads += 1
        readSinceScan[session] = (title, rereads)
        retitled?(session, title)
    }

    func current(_ sessions: [AgentSession]) -> [AgentSession] {
        guard !readSinceScan.isEmpty else { return sessions }
        return sessions.map { session in
            guard let read = readSinceScan[session.id] else { return session }
            var known = session
            known.title = read.title
            return known
        }
    }

    func observe(_ event: AgentEvent) {
        guard case .turnComplete(let session, _, _, _, _) = event, titles != nil else { return }
        let until = now().addingTimeInterval(Self.titleWatch)
        if let entry = entry(session) {
            watchTitle(session, entry, until: until)
        } else {
            awaitingScan[session] = until
            while awaitingScan.count > Self.titleWatchLimit, let oldest = awaitingScan.min(by: { $0.value < $1.value })?.key {
                awaitingScan[oldest] = nil
            }
        }
    }

    func retire(sessions: Set<String>) {
        for session in sessions { endTitleWatch(session) }
    }

    func stop() {
        for session in Array(titleWatches.keys) { endTitleWatch(session) }
        awaitingScan = [:]
    }

    isolated deinit {
        for watch in titleWatches.values { watch.task.cancel() }
    }

    private func entry(_ session: String) -> ClaudeRegistryEntry? {
        lastByFolder.values.joined().first { $0.sessionId == session }
    }

    private func endTitleWatch(_ session: String) {
        titleWatches.removeValue(forKey: session)?.task.cancel()
        awaitingScan[session] = nil
    }

    private func watchTitle(_ session: String, _ entry: ClaudeRegistryEntry, until: Date) {
        guard let titles else { return }
        titleWatches.removeValue(forKey: session)?.task.cancel()
        let (watchFile, spacing, now, id) = (watchTranscript, spacing, now, UUID())
        let task = Task { @MainActor [weak self] in
            let (signals, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let expiry = Task { @MainActor [weak self] in
                await spacing(.seconds(max(0, until.timeIntervalSince(now()))))
                guard !Task.isCancelled, self?.titleWatches[session]?.id == id else { return }
                self?.endTitleWatch(session)
            }
            var close: (@Sendable () -> Void)?
            defer {
                expiry.cancel()
                close?()
                if self?.titleWatches[session]?.id == id { self?.titleWatches[session] = nil }
            }
            guard let transcript = await Task.detached(operation: { titles.transcript(for: entry) }).value, !Task.isCancelled
            else { return }
            close = watchFile(transcript) { signal.yield() }
            guard close != nil else {
                let read = await Task.detached(operation: { titles.reread(entry) }).value
                if let read, !Task.isCancelled { self?.report(read, of: session, entry) }
                return
            }
            var writes = signals.makeAsyncIterator()
            var readAt: Date?
            var opening = true
            repeat {
                if let readAt, now().timeIntervalSince(readAt) < Self.titleRecheck {
                    await spacing(.seconds(Self.titleRecheck - now().timeIntervalSince(readAt)))
                }
                guard !Task.isCancelled, now() < until else { return }
                let read = await Task.detached(operation: { titles.reread(entry) }).value
                guard !Task.isCancelled else { return }
                if let read { self?.report(read, of: session, entry) }
                readAt = opening ? nil : now()
                opening = false
            } while await writes.next() != nil
        }
        titleWatches[session] = (id, until, task)
        while titleWatches.count > Self.titleWatchLimit, let oldest = titleWatches.min(by: { $0.value.until < $1.value.until })?.key {
            endTitleWatch(oldest)
        }
    }

    private func titlesScanned(_ sessions: Set<String>) {
        let at = now()
        for session in titleWatches.keys where !sessions.contains(session) { endTitleWatch(session) }
        let due = awaitingScan.filter { $0.value > at }
        awaitingScan = [:]
        for (session, until) in due {
            if let entry = entry(session) {
                watchTitle(session, entry, until: until)
            } else {
                awaitingScan[session] = until
            }
        }
    }

    nonisolated static let partialProblem = "Some Claude Code session lists couldn\u{2019}t be read. Conversations seen earlier stay listed."

    init(
        scanEach: @escaping @Sendable (_ reusingProcesses: Bool) -> ClaudeRegistryScanner.Scan, titles: ClaudeTranscriptTitles? = nil,
        stillRunning: @escaping (RememberedName) -> Bool = ClaudeRegistryScanner.stillRunning,
        isRunning: @escaping @Sendable (Int) -> Bool = ProcessStart.isRunning(pid:),
        transcriptWatch: @escaping TranscriptWatch = TranscriptFileWatch.open,
        titleSpacing: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        scanRegistry = scanEach
        self.now = now
        watchTranscript = transcriptWatch
        spacing = titleSpacing
        self.titles = titles
        running = stillRunning
        self.isRunning = isRunning
    }

    convenience init(
        scan: @escaping @Sendable () -> [ClaudeRegistryEntry]?, titles: ClaudeTranscriptTitles? = nil,
        stillRunning: @escaping (RememberedName) -> Bool = ClaudeRegistryScanner.stillRunning,
        transcriptWatch: @escaping TranscriptWatch = TranscriptFileWatch.open,
        titleSpacing: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            scanEach: { _ in scan().map { ClaudeRegistryScanner.Scan(entries: $0, unreadable: []) } ?? ClaudeRegistryScanner.Scan(entries: [], unreadable: [Self.unknownFolder]) },
            titles: titles, stillRunning: stillRunning, transcriptWatch: transcriptWatch, titleSpacing: titleSpacing, now: now)
    }

    convenience init(
        enrolled: @escaping @Sendable () -> [URL], defaultFolder: URL = ClaudeConnectorInstaller.defaultSetupFolder(),
        declared: @escaping @Sendable () -> String? = { nil },
        processes: @escaping @Sendable (_ reusing: Bool) -> AgentProcesses.Found
    ) {
        self.init(scanEach: { reusing in
            let running = processes(reusing)
            let shell = declared().map { URL(fileURLWithPath: $0, isDirectory: true) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let fromProcesses = running.setups.map { URL(fileURLWithPath: $0, isDirectory: true) } + (shell.map { [ConnectorFolders.canonical($0)] } ?? [])
            var seen: Set<String> = []
            let dirs = ([ConnectorFolders.canonical(defaultFolder)] + enrolled() + fromProcesses).filter { seen.insert($0.path).inserted }
            var found = ClaudeRegistryScanner.scanEach(configDirs: dirs)
            found.processesUnreadable = running.isPartial
            found.folders = fromProcesses.map(\.path)
            found.watched = dirs.map { $0.appendingPathComponent("sessions", isDirectory: true).path }
                .filter { FileManager.default.fileExists(atPath: $0) }
            return found
        }, titles: ClaudeTranscriptTitles(configDirs: []))
    }

    convenience init(setups: ConnectorSetupRegistry, processes: AgentProcessTable) {
        self.init(enrolled: {
            (setups.setups?.enrolled(agent: AgentKind.claude.id) ?? []).map { URL(fileURLWithPath: $0.folder, isDirectory: true) }
        }, declared: { ToolEnvironment.shared.folder(AgentProcesses.Rule.claude.setupVariable) }, processes: { processes.found(.claude, reusing: $0) })
    }

    func scan(rereadingTitles: Bool, reusingProcesses: Bool) async -> AgentScan {
        let readBefore = rereads
        defer { readSinceScan = readSinceScan.filter { $0.value.read > readBefore } }
        let (scanRegistry, titles, previous, isRunning) = (scanRegistry, titles, lastByFolder, isRunning)
        let (scan, kept, watched) = await Task.detached { () -> (AgentScan, [String: [ClaudeRegistryEntry]], [String]) in
            let found = scanRegistry(reusingProcesses)
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
            return (.found(sessions, AgentScanExtras(setups: setups, problem: problem, carried: carried)), kept, found.watched)
        }.value
        lastByFolder = kept
        if case .found(let sessions, _) = scan { titlesScanned(Set(sessions.map(\.id))) }
        watchedFolders = watched.map { URL(fileURLWithPath: $0, isDirectory: true) }
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
        transcriptWatch: @escaping ClaudeDiscovery.TranscriptWatch = TranscriptFileWatch.open,
        titleSpacing: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        receiptTimeout: Duration = .seconds(8), handOffLimit: Duration = .seconds(30), checkWait: Duration = AgentHub.defaultCheckWait,
        disconnectGrace: Duration = AgentHub.defaultDisconnectGrace, scanDeadline: Duration = AgentHub.defaultScanDeadline,
        places: (any AgentPlaceReading)? = nil,
        now: @escaping () -> Date = Date.init, makeId: @escaping () -> String = { UUID().uuidString },
        stillRunning: @escaping (RememberedName) -> Bool = ClaudeRegistryScanner.stillRunning
    ) {
        self.init(
            transport: transport, discovery: [ClaudeDiscovery(
                scan: scan, titles: transcriptTitles, stillRunning: stillRunning, transcriptWatch: transcriptWatch,
                titleSpacing: titleSpacing, now: now)],
            names: names, focus: focus, front: front, glance: glance, receiptTimeout: receiptTimeout, handOffLimit: handOffLimit,
            checkWait: checkWait, disconnectGrace: disconnectGrace, scanDeadline: scanDeadline, places: places, now: now, makeId: makeId)
    }
}

enum TranscriptFileWatch {
    static func open(_ url: URL, _ changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .global(qos: .utility))
        source.setEventHandler { changed() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return { source.cancel() }
    }
}

enum ClaudeCLI {
    static func extraFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [home.appendingPathComponent(".claude/local").path]
    }

    static func run(_ argv: [String], environment: [String: String], timeout: TimeInterval = 120, grace: TimeInterval = 2) -> (Int32, String) {
        ToolCLI.run(argv, timeout: timeout, grace: grace, environment: environment)
    }
}

@MainActor
final class ClaudeConnector: AgentConnector {
    let kind = AgentKind.claude
    let defaultFolder: URL
    private let run: @Sendable ([String], [String: String]) -> (Int32, String)
    private let version: @Sendable (String) async -> ToolCheck
    private let tools: ToolEnvironment
    private let home: URL
    private let agentsDir: URL
    private let pluginName: String
    private let script: String?
    private let baseEnvironment: [String: String]
    private let surfaces: ConnectorSurfaces

    init(
        run: @escaping @Sendable ([String], [String: String]) -> (Int32, String) = { ClaudeCLI.run($0, environment: $1) },
        version: (@Sendable (String) async -> ToolCheck)? = nil,
        tools: ToolEnvironment = .shared,
        agentsDir: URL, pluginName: String, surfaces: ConnectorSurfaces, script: String? = ClaudeConnectorFiles.registerJS,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.run = run
        self.version = version ?? { await tools.check(tool: $0, agent: AgentKind.claude.id) }
        self.tools = tools
        self.home = home
        self.agentsDir = agentsDir
        self.pluginName = pluginName
        self.script = script
        self.baseEnvironment = baseEnvironment
        self.surfaces = surfaces
        defaultFolder = ClaudeConnectorInstaller.defaultSetupFolder(home: home)
    }

    private var pluginId: String { "\(pluginName)@\(pluginName)-local" }
    var isBundled: Bool { script != nil }
    var bundledVersion: String? { script.map { ClaudeConnectorFiles.version(for: $0, surfaces: surfaces) } }

    func hasFiles(in target: ConnectorTarget) -> Bool {
        FileManager.default.fileExists(atPath: ClaudeConnectorInstaller.marketplaceDir(in: agentsDir, setupFolder: target.folder).path)
    }

    func manualUninstall(for target: ConnectorTarget) -> [String] {
        ClaudeConnectorInstaller.manualUninstall(pluginName: pluginName, setupFolder: target.folder, isDefault: target.isDefault)
    }

    func recognizes(folder: URL) -> Bool {
        ConnectorFolders.contains(any: ["settings.json", ".credentials.json", "sessions", "projects", "plugins"], in: folder)
    }

    private static let rule = AgentProcesses.Rule.claude

    var toolProgram: String? { Self.rule.command }

    var folderVariable: String? { Self.rule.setupVariable }

    func findTool(in folder: URL, chosen: String?) -> ToolSearch.Result? {
        tools.search(program: Self.rule.command, agent: kind.id, setup: folder.path, chosen: chosen, extra: ClaudeCLI.extraFolders(home: home))
    }

    func checkTool(_ tool: String) async -> ToolCheck? { await version(tool) }

    private func base(for tool: String) -> [String: String] {
        tools.runEnvironment(tool: tool, agent: kind.id, base: baseEnvironment)
    }

    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
        guard let script else { return .unavailable }
        let working = await version(tool)
        guard working.isWorking else { return .toolNotWorking(working) }
        let (run, pluginId) = (run, pluginId)
        let environment = ClaudeConnectorInstaller.environment(for: target.folder, isDefault: target.isDefault, base: base(for: tool))
        let (status, output) = await Task.detached { run([tool, "plugin", "list", "--json"], environment) }.value
        guard status == 0 else { return .failed(Self.trimmed(output)) }
        let found = AgentConnectorStatus.parse(pluginList: Data(output.utf8), pluginId: pluginId, bundledVersion: ClaudeConnectorFiles.version(for: script, surfaces: surfaces))
        let registered = switch found {
        case .ready, .outdated, .disabled: true
        case .notInstalled, .unknown, .notOpen: false
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
            script: script, surfaces: surfaces, run: run, baseEnvironment: base(for: tool))
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
        help: "\(Branding.appName) reaches Claude Code through a small plugin installed in the folder Claude Code loads its configuration from. Installed means the plugin is in place; each conversation using this folder then connects on its own once you trust its project folder, unless you disconnect it.",
        reloadHint: "Already running Claude Code here? Run /reload-plugins in each open conversation.",
        uninstallTitle: "Uninstall the Claude Code connector from this folder?",
        uninstallMessage: "Claude Code conversations using this folder disconnect now, and new ones will not connect. Work you already sent may still finish. Each open conversation unloads the connector when you run /reload-plugins in it or restart it. Other folders stay connected. The folder, its conversations, your conversation names and disconnections, and other \(Branding.appName) settings are kept.",
        toolNotFoundLabel: "Claude Code not found",
        toolNotFoundAdvice: "Install Claude Code, or choose the claude command yourself. \(Branding.appName) looked for it in a running conversation, your login shell\u{2019}s PATH, its own PATH, and the usual install folders.",
        toolNotWorkingLabel: "Claude Code not working",
        unavailable: "This copy of \(Branding.appName) is missing its Claude Code connector. Reinstall \(Branding.appName) to connect Claude Code.",
        disabledLabel: "Turned off in Claude Code",
        disabledAdvice: "Turn the plugin back on with /plugin in Claude Code.",
        removalUnfinishedAdvice: "The connector was uninstalled in \(Branding.appName), but Claude Code has not finished removing it. Its conversations no longer connect. Finish uninstalling it, then install it again if you want it back.",
        listUnreadable: "Claude Code's plugin list could not be read.",
        noReason: "Claude Code did not say why.",
        manualUninstallAfterDisconnect: "Disconnected from \(Branding.appName). Run these in a terminal to finish uninstalling, then run /reload-plugins in each open conversation or restart it:",
        stillConnected: { count in
            count == 1
                ? "The connector was uninstalled outside \(Branding.appName), so 1 open conversation is still connected and keeps receiving what you say until you run /reload-plugins in it or restart it."
                : "The connector was uninstalled outside \(Branding.appName), so \(count) open conversations are still connected and keep receiving what you say until you run /reload-plugins in each one or restart them."
        })
}
