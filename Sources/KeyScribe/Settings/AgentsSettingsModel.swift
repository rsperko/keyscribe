import Foundation
import KeyScribeKit

@MainActor
final class AgentsSettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let folder: String
        let state: String
        let connected: Bool
        let agent: String
        var terminal: String?
        var title: String?
        var setup: String?
        var key: String = ""
        var identified = true
        var lastSeen = false
        var olderConnector = false
        var startedAt: Date?
        var readAloud: ReadAloud?
        var place: AgentPlaceName?
        var renamed = false
        var surface: String?
        var otherNames: [String] = []
        var unreadSince: Date?
        var needsYou = false
        var host: String?

        var countsUnder: String { host ?? agent }

        var location: String? {
            guard let place else { return terminal }
            let within = "\(place.word) \(place.label)"
            guard let terminal else { return "\(place.surface) \(within)" }
            if terminal.hasSuffix(place.surface) { return "\(terminal) \(within)" }
            return "\(terminal) \u{00B7} \(place.surface) \(within)"
        }
    }

    enum ReadAloud: Equatable {
        case thisReply, nextReply

        var note: String {
            switch self {
            case .thisReply: "Reply will be reported."
            case .nextReply: "Next reply will be reported."
            }
        }
    }

    enum RowAction: Equatable {
        case connect
        case recover(AgentKind?)
        case connected
        case unknown
    }

    struct ConsentRequest: Identifiable {
        let id = UUID()
        let connector: AgentConnectorModel
        let setup: ConnectorSetupModel
        var reconnecting: String?
    }

    let connectors: [AgentConnectorModel]
    @Published private(set) var rows: [Row] = []
    @Published var consent: ConsentRequest?
    @Published private(set) var disconnectedRows: [Row] = []
    @Published private(set) var exclusionsNotSaved: String?
    @Published private(set) var setupsProblem: String?
    @Published var integrationsProblem: String?
    var onDisconnect: ((String) -> Void)?
    var onReconnect: ((String) -> Void)?
    var onShow: ((String) -> Void)?
    var onCancelReadAloud: ((String) -> Void)?
    var onCheckAgain: (() -> Void)?
    var onRetrySavingExclusions: (() -> Void)?
    @Published private(set) var renameProblem: String?
    @Published private(set) var renameDetails: String?
    @Published private(set) var namesProblem: String?
    @Published private(set) var namesNotSaved: String?
    @Published var spokenResult = SpokenResultSettings() {
        didSet { if !loadingSpokenResult, spokenResult != oldValue { onSpokenResultChange?(spokenResult) } }
    }
    var onSpokenResultChange: ((SpokenResultSettings) -> Void)?
    var chosenVoice: String {
        get { SpokenVoices.resolved(spokenResult.voice) }
        set { spokenResult.voice = newValue == SpokenVoices.recommended ? nil : newValue }
    }
    static let textOnlyChoice = ""
    var voiceChoice: String {
        get { spokenResult.textOnly ? Self.textOnlyChoice : chosenVoice }
        set {
            guard newValue != Self.textOnlyChoice else { return spokenResult.textOnly = true }
            var updated = spokenResult
            updated.textOnly = false
            updated.voice = newValue == SpokenVoices.recommended ? nil : newValue
            spokenResult = updated
        }
    }
    var onOpenAIServices: (() -> Void)?
    var voice: SpokenVoiceModel?
    private var loadingSpokenResult = false

    func load(spokenResult: SpokenResultSettings) {
        loadingSpokenResult = true
        self.spokenResult = spokenResult
        loadingSpokenResult = false
    }

    @Published private(set) var turnedOnHosts: [String] = []
    var onHostsChange: (([String]) -> Void)?

    func load(hosts: [String]) {
        if turnedOnHosts != hosts { turnedOnHosts = hosts }
    }

    func isTurnedOn(_ host: AgentKind) -> Bool {
        guard let connector = connector(of: host) else { return turnedOnHosts.contains(host.id) }
        return connector.setups.contains(where: \.isEnrolled)
    }

    func isTurnedOn(id: String) -> Bool { hosts.first { $0.id == id }.map(isTurnedOn) ?? false }

    func problem(of host: AgentKind) -> String? { isTurnedOn(host) ? discoveryProblems[host.id] : nil }

    func setTurnedOn(_ host: AgentKind, _ on: Bool) {
        guard connector(of: host) == nil, on != isTurnedOn(host) else { return }
        turnedOnHosts = on ? turnedOnHosts + [host.id] : turnedOnHosts.filter { $0 != host.id }
        onHostsChange?(turnedOnHosts)
    }

    func host(of connector: AgentConnectorModel) -> AgentKind? { hosts.first { $0.id == connector.kind.id } }

    private func connector(of host: AgentKind) -> AgentConnectorModel? { connectors.first { $0.kind.id == host.id } }

    var onRename: ((String, String) throws -> Void)?
    var onReloadNames: (() -> Void)?
    var renameCheck: ((String, String) -> AgentHandles.RenameError?)?
    var defaultName: ((String) -> AgentDirectory.DefaultName?)?
    var onUseDefaultName: ((String) throws -> Void)?
    var onRetire: ((String) -> Void)? {
        didSet { for connector in connectors { connector.onRetire = onRetire } }
    }

    var connectedCount: Int { rows.filter(\.connected).count }

    var hasError: Bool {
        namesProblem != nil || exclusionsNotSaved != nil || setupsProblem != nil || integrationsProblem != nil
            || connectors.contains { $0.setups.contains(where: \.hasError) }
    }

    func recognitionContext(for row: Row) -> String? {
        guard !row.identified, rows.contains(where: {
            $0.key != row.key && $0.name == row.name && $0.folder == row.folder && $0.terminal == row.terminal
        }), let startedAt = row.startedAt else { return nil }
        return "Started \(startedAt.formatted(date: .abbreviated, time: .standard))"
    }

    private let describeTerminal: @Sendable (Int) -> String?
    private var terminals: [Int: String?] = [:]
    @Published private var discoveryProblems: [String: String] = [:]
    private var shown: [AgentConversation]?
    private struct Extras {
        var setups: [String: [String]]
        var candidates: [AgentCandidate]
        var disconnected: [AgentConversation]
        var olderConnectors: Set<String>
        var lastSeen: Set<String>
        var readAloud: Set<String>
        var readNextAloud: Set<String>
    }
    private var shownExtras: Extras?
    let agentsDir: URL
    let setups: ConnectorSetupRegistry
    let hosts: [AgentKind]

    init(
        describeTerminal: @escaping @Sendable (Int) -> String?,
        agentsDir: URL, setups: ConnectorSetupRegistry? = nil, connectors: [any AgentConnector], hosts: [AgentKind] = [],
        tools: ToolEnvironment = .shared
    ) {
        self.tools = tools
        self.hosts = hosts
        self.describeTerminal = describeTerminal
        self.agentsDir = agentsDir
        let registry = setups ?? ConnectorSetupRegistry(directory: agentsDir)
        self.setups = registry
        self.connectors = connectors.map { AgentConnectorModel($0, registry: registry, tools: tools) }
        setupsProblem = registry.problem
        tools.observe { [weak self] in
            Task { @MainActor in await self?.shellChanged() }
        }
    }

    private let tools: ToolEnvironment

    func refresh() async {
        if setupsProblem != setups.problem { setupsProblem = setups.problem }
        tools.forgetFailedChecks()
        let tools = tools
        Task.detached { await tools.refresh(.settings) }
        for connector in connectors { await connector.refresh() }
    }

    func shellChanged() async {
        for connector in connectors where connector.hasRefreshed { await connector.refresh() }
    }

    func maintain() async {
        for connector in connectors { await connector.maintain() }
    }

    var namesFile: URL { agentsDir.appendingPathComponent(AgentNameStore.fileName) }

    func reloadNames() {
        onReloadNames?()
    }

    func show(
        _ conversations: [AgentConversation], namesProblem: String? = nil, namesNotSaved: String? = nil,
        discoveryProblems: [String: String]? = nil, discoveredSetups: [String: [String]] = [:], candidates: [AgentCandidate] = [],
        disconnected: [AgentConversation] = [], exclusionsNotSaved: String? = nil, olderConnectors: Set<String> = [],
        lastSeen: Set<String> = [], readAloud: Set<String> = [], readNextAloud: Set<String> = [], prompts: [String: AgentPrompt] = [:]
    ) {
        if exclusionsNotSaved != self.exclusionsNotSaved { self.exclusionsNotSaved = exclusionsNotSaved }
        shownExtras = Extras(
            setups: discoveredSetups, candidates: candidates, disconnected: disconnected, olderConnectors: olderConnectors, lastSeen: lastSeen,
            readAloud: readAloud, readNextAloud: readNextAloud)
        if setupsProblem != setups.problem { setupsProblem = setups.problem }
        if namesProblem != self.namesProblem { self.namesProblem = namesProblem }
        if let discoveryProblems, discoveryProblems != self.discoveryProblems { self.discoveryProblems = discoveryProblems }
        for connector in connectors where connector.discoveryProblem != self.discoveryProblems[connector.kind.id] {
            connector.discoveryProblem = self.discoveryProblems[connector.kind.id]
        }
        if namesNotSaved != self.namesNotSaved { self.namesNotSaved = namesNotSaved }
        shown = conversations
        describeNewTerminals(conversations.compactMap(\.pid) + candidates.map(\.pid) + disconnected.compactMap(\.pid))
        var next = conversations.map { conversation in
            let lastSeen = lastSeen.contains(conversation.id) && (!conversation.reachable || conversation.host != nil)
            return Row(
                id: conversation.id, name: conversation.handle, folder: conversation.cwd,
                state: lastSeen ? "Last seen" : AgentRoster.stateLabel(conversation, prompt: prompts[conversation.id]),
                connected: conversation.reachable && !lastSeen,
                agent: conversation.runningAgent, terminal: conversation.pid.flatMap { terminals[$0] ?? nil },
                title: conversation.title, setup: conversation.setup,
                key: conversation.pid.map { Self.key(pid: $0, milliseconds: conversation.startedAt.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) }) } ?? conversation.id,
                lastSeen: lastSeen, olderConnector: conversation.connectorLive && olderConnectors.contains(conversation.id), startedAt: conversation.startedAt,
                readAloud: readAloud.contains(conversation.id) ? .thisReply : readNextAloud.contains(conversation.id) ? .nextReply : nil,
                place: conversation.placeName, renamed: conversation.nameSource == .chosen,
                surface: conversation.placeSurface, otherNames: conversation.otherNames, unreadSince: conversation.placeUnreadSince,
                needsYou: conversation.reachable && !lastSeen && Self.waitsOnUser.contains(conversation.state), host: conversation.host?.host)
        }
        next += candidates.map { candidate in
            Row(
                id: candidate.rowId, name: name(of: candidate), folder: candidate.cwd,
                state: "Not connected", connected: false, agent: candidate.agent, terminal: terminals[candidate.pid] ?? nil,
                setup: candidate.setup, key: Self.key(pid: candidate.pid, milliseconds: candidate.startedAt), identified: false,
                startedAt: candidate.startedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
        if next != rows { rows = next }
        let away = namesProblem != nil ? [] : disconnected.map { conversation in
            Row(
                id: conversation.id, name: conversation.handle, folder: conversation.cwd, state: "Disconnected", connected: false,
                agent: conversation.runningAgent, terminal: conversation.pid.flatMap { terminals[$0] ?? nil }, title: conversation.title,
                setup: conversation.setup, key: conversation.id, place: conversation.placeName,
                renamed: conversation.nameSource == .chosen, surface: conversation.placeSurface, otherNames: conversation.otherNames,
                unreadSince: conversation.placeUnreadSince)
        }
        if away != disconnectedRows { disconnectedRows = away }
        for connector in connectors {
            let uses = conversations.compactMap { conversation -> AgentConnectorModel.Use? in
                if let hosted = conversation.host {
                    guard hosted.host == connector.kind.id else { return nil }
                    return AgentConnectorModel.Use(
                        folder: hosted.instance, name: conversation.handle, connected: !connector.connector.keepsConnection || conversation.connectorLive)
                }
                guard conversation.runningAgent == connector.kind.id, let setup = conversation.setup else { return nil }
                return AgentConnectorModel.Use(
                    folder: setup, name: conversation.handle, connected: conversation.connectorLive,
                    older: conversation.connectorLive && olderConnectors.contains(conversation.id))
            }
            let waiting = candidates.compactMap { candidate -> AgentConnectorModel.Use? in
                guard candidate.agent == connector.kind.id, let setup = candidate.setup else { return nil }
                return AgentConnectorModel.Use(folder: setup, name: name(of: candidate), connected: false)
            }
            connector.show(discovered: discoveredSetups[connector.kind.id] ?? [], uses: uses + waiting)
        }
    }

    private func describeNewTerminals(_ pids: [Int]) {
        terminals = terminals.filter { pids.contains($0.key) }
        let missing = pids.filter { terminals[$0] == nil }
        guard !missing.isEmpty else { return }
        for pid in missing { terminals[pid] = .some(nil) }
        let describe = describeTerminal
        Task { [weak self] in
            let found = await Task.detached { missing.map { ($0, describe($0)) } }.value
            guard let self else { return }
            for (pid, terminal) in found { self.terminals[pid] = .some(terminal) }
            if let shown = self.shown, let extras = self.shownExtras {
                self.show(
                    shown, namesProblem: self.namesProblem, namesNotSaved: self.namesNotSaved,
                    discoveredSetups: extras.setups, candidates: extras.candidates, disconnected: extras.disconnected,
                    exclusionsNotSaved: self.exclusionsNotSaved, olderConnectors: extras.olderConnectors, lastSeen: extras.lastSeen,
                    readAloud: extras.readAloud, readNextAloud: extras.readNextAloud)
            }
        }
    }

    private static let waitsOnUser: [AgentLiveState] = [.waitingApproval, .waitingQuestion, .userDialog]

    static func key(pid: Int, milliseconds: Int?) -> String {
        "\(pid):\(milliseconds ?? 0)"
    }

    private func name(of candidate: AgentCandidate) -> String {
        candidate.label(agentName: connectors.first { $0.kind.id == candidate.agent }?.kind.displayName ?? candidate.agent)
    }

    func connector(for row: Row) -> AgentConnectorModel? { connectors.first { $0.kind.id == row.agent } }

    func agentName(_ row: Row) -> String {
        connector(for: row)?.kind.displayName ?? hosts.first { $0.id == row.agent }?.displayName ?? row.agent
    }

    func awaitingReload(of connector: AgentConnectorModel) -> [Row] {
        rows.filter { row in
            guard row.agent == connector.kind.id, !row.connected, !row.lastSeen, case .recover = action(for: row) else { return false }
            return true
        }
    }

    func configurationFolder(of row: Row) -> String? {
        guard let setup = row.setup, (connector(for: row)?.setups.count ?? 0) > 1 else { return nil }
        return (setup as NSString).abbreviatingWithTildeInPath
    }

    func setup(for row: Row) -> ConnectorSetupModel? {
        guard let setup = row.setup else { return nil }
        return connector(for: row)?.setup(for: setup)
    }

    func action(for row: Row) -> RowAction {
        if row.connected { return .connected }
        guard let setup = setup(for: row) else { return .unknown }
        guard setup.isEnrolled else { return .connect }
        if setup.isInstalled { return .recover(connector(for: row)?.kind) }
        return setup.state == .checking ? .unknown : .connect
    }

    func connect(_ row: Row) {
        guard let connector = connector(for: row), let setup = setup(for: row) else { return }
        requestInstall(setup, of: connector)
    }

    func disconnect(_ row: Row) { onDisconnect?(row.id) }

    func cancelReadAloud(_ row: Row) { onCancelReadAloud?(row.id) }

    static let revealLasts: TimeInterval = 10
    @Published private(set) var revealed: [String] = []
    private var revealedAt = Date.distantPast
    var now: () -> Date = Date.init

    var pendingReveal: [String] { now().timeIntervalSince(revealedAt) < Self.revealLasts ? revealed : [] }

    var revealedKey: String? {
        pendingReveal.lazy.compactMap { id in (self.rows + self.disconnectedRows).first { $0.id == id }?.key }.first
    }

    func reveal(_ rows: [String]) {
        revealed = rows
        revealedAt = now()
        if !rows.isEmpty { showingConversations = true }
    }

    var hasAnyConnection: Bool {
        connectors.contains { $0.setups.contains(where: \.isEnrolled) } || hosts.contains { connector(of: $0) == nil && isTurnedOn($0) }
    }

    var integrationIDs: [String] {
        connectors.filter { host(of: $0) == nil }.map(\.kind.id) + hosts.map(\.id)
    }

    @Published var showingConversations = false {
        didSet { if !showingConversations { listFilter = nil } }
    }

    struct ListFilter: Equatable {
        var ids: Set<String>
        var title: String
    }

    @Published private(set) var listFilter: ListFilter?

    func showOnly(_ ids: [String], title: String) {
        guard !ids.isEmpty else { return }
        listFilter = ListFilter(ids: Set(ids), title: title)
        showingConversations = true
    }

    func showAllConversations() { listFilter = nil }

    var conversationsSummary: String {
        let available = rows.filter(\.connected).count
        return available == 1 ? "1 available" : available == 0 ? "None available" : "\(available) available"
    }

    static let routingNote = "Instructions go to the conversation focused when you start speaking. Say a conversation\u{2019}s name or number to send that instruction there instead. Without either, nothing is sent."

    struct Groups: Equatable {
        var connected: [Row]
        var notConnected: [Row]
        var disconnected: [Row]
    }

    func conversationGroups(matching query: String) -> Groups {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = listFilter?.ids
        let shown = { (rows: [Row]) in
            rows.filter { (filter?.contains($0.id) ?? true) && (query.isEmpty || self.matches($0, query)) }.sorted(by: Self.listOrder)
        }
        return Groups(
            connected: shown(rows.filter(\.connected)),
            notConnected: shown(rows.filter { !$0.connected }),
            disconnected: shown(disconnectedRows))
    }

    private static func listOrder(_ a: Row, _ b: Row) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.key < b.key
        }
    }

    private func matches(_ row: Row, _ query: String) -> Bool {
        ([row.name, agentName(row), row.folder, row.location, row.title, row.setup.map { ($0 as NSString).abbreviatingWithTildeInPath }] + row.otherNames.map(Optional.some))
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    func example(for row: Row) -> SpokenHelp.Row? {
        guard row.connected, namesProblem == nil else { return nil }
        return SpokenHelp.agentPhrases(name: row.name, readsReplies: false).first
    }

    func reconnect(_ row: Row) {
        if let setup = setup(for: row), let connector = connector(for: row), !(setup.isEnrolled && setup.isInstalled) {
            requestInstall(setup, of: connector, reconnecting: row.id)
            return
        }
        onReconnect?(row.id)
    }

    var emptyState: String {
        if namesProblem != nil {
            return "Conversations stay disconnected until \(AgentNameStore.fileName) can be read."
        }
        let problems = Set(discoveryProblems.values)
        guard !problems.isEmpty else { return "No open conversations found." }
        return "Some conversations couldn\u{2019}t be checked. Try again in a moment."
    }

    func choose(folder: URL, for connector: AgentConnectorModel) -> String? {
        if let listed = connector.setup(for: ConnectorFolders.canonical(folder).path) {
            return "\(listed.display) is already listed."
        }
        guard connector.connector.recognizes(folder: folder) else {
            return "\(ConnectorFolders.display(folder)) doesn\u{2019}t look like a \(connector.kind.displayName) \(connector.copy.folderNoun)."
        }
        guard let setup = connector.choose(folder: folder) else { return nil }
        Task { await setup.refresh() }
        if !setup.isEnrolled { requestInstall(setup, of: connector) }
        return nil
    }

    func requestInstall(_ setup: ConnectorSetupModel, of connector: AgentConnectorModel, reconnecting: String? = nil) {
        consent = ConsentRequest(connector: connector, setup: setup, reconnecting: reconnecting)
    }

    func affected(by request: ConsentRequest) -> [String] {
        (rows + disconnectedRows.filter { $0.id == request.reconnecting })
            .filter { $0.agent == request.connector.kind.id && $0.setup == request.setup.folder.path }
            .map { row in recognitionContext(for: row).map { "\(row.name) (\($0))" } ?? row.name }
    }

    func stayingDisconnected(by request: ConsentRequest) -> [String] {
        disconnectedRows.filter { $0.id != request.reconnecting && $0.agent == request.connector.kind.id && $0.setup == request.setup.folder.path }
            .map(\.name)
    }

    func confirm(_ request: ConsentRequest) {
        consent = nil
        Task {
            await request.setup.install()
            if let id = request.reconnecting, request.setup.isEnrolled, request.setup.isInstalled { onReconnect?(id) }
        }
    }

    func retrySetups() async {
        setups.reload()
        setupsProblem = setups.problem
        await refresh()
    }

    @discardableResult
    func rename(_ id: String, to name: String) -> Bool {
        renameDetails = nil
        guard let onRename else {
            renameProblem = "The agent connection is unavailable. Try again when it reconnects."
            return false
        }
        do {
            try onRename(id, name)
            renameProblem = nil
            return true
        } catch let error as AgentHandles.RenameError {
            renameProblem = Self.problem(error, name: AgentHandles.normalize(name))
        } catch {
            renameProblem = "Could not save this name. Your current name is unchanged."
            renameDetails = error.localizedDescription
        }
        return false
    }

    func clearRenameProblem() {
        renameProblem = nil
        renameDetails = nil
    }

    func renameIssue(_ id: String, name: String) -> String? {
        let normalized = AgentHandles.normalize(name)
        if normalized.isEmpty { return Self.problem(.empty, name: normalized) }
        if AgentHandles.isReserved(normalized) { return Self.problem(.reserved, name: normalized) }
        if let renameCheck { return renameCheck(id, normalized).map { Self.problem($0, name: normalized) } }
        if rows.contains(where: { $0.id != id && AgentHandles.matchKey($0.name) == AgentHandles.matchKey(normalized) }) {
            return Self.problem(.taken, name: normalized)
        }
        return nil
    }

    func renameExample(_ id: String, name: String) -> String {
        let normalized = AgentHandles.normalize(name)
        let full = "Say \u{201C}\(normalized), run the unit tests.\u{201D}"
        let others = rows.filter { $0.id != id }.map(\.name)
        guard let short = AgentAddress.shorterSpokenName(for: normalized, among: others + [normalized]) else { return full }
        return "\(full) \u{201C}tell \(short), \u{2026}\u{201D} also works."
    }

    static func placeTrouble(_ row: Row) -> String? {
        guard let since = row.unreadSince else { return nil }
        let what = row.surface.map { "its \($0) names" } ?? "where it runs"
        return "Couldn\u{2019}t read \(what) since \(since.formatted(date: .omitted, time: .shortened)). Using the names last read."
    }

    static func placeNote(_ row: Row) -> String? {
        guard let surface = row.place?.surface ?? row.surface else { return nil }
        if row.renamed { return "This name follows this conversation, including when you resume it." }
        switch row.place?.level {
        case .title?:
            let word = row.place?.word ?? "title"
            return "This name is the \(word) \(surface) shows, so it changes when \(surface) changes it. Rename it here to keep a name of your own."
        case .agent?: return "This name follows this agent. To change it, rename the agent in \(surface)."
        default:
            let word = row.place?.word ?? "pane"
            return "This name follows this conversation, including when you resume it. To name future conversations in this \(word), rename the \(word) in \(surface)."
        }
    }

    func defaultNameNote(_ row: Row) -> String? {
        guard let preview = defaultName?(row.id) else { return nil }
        let from = switch preview.source {
        case .place: preview.place.map { "from its \($0.surface) \($0.word)" } ?? "from its folder"
        case .agent: "from the agent\u{2019}s own name for it"
        case .folder, .chosen: "from its folder"
        }
        let note = row.renamed ? "Default name: \(preview.name), \(from)." : "This name comes \(from)."
        return alsoAnswers(row).map { "\(note) \($0)." } ?? note
    }

    func alsoAnswers(_ row: Row) -> String? {
        let others = row.otherNames
        guard !others.isEmpty else { return nil }
        return "Also answers to \(AgentOutput.either(others.map { "\u{201C}\($0)\u{201D}" }, joining: "and"))"
    }

    @discardableResult
    func useDefaultName(_ id: String) -> Bool {
        renameDetails = nil
        guard let onUseDefaultName else {
            renameProblem = "The agent connection is unavailable. Try again when it reconnects."
            return false
        }
        do {
            try onUseDefaultName(id)
            renameProblem = nil
            return true
        } catch {
            renameProblem = "Could not save this change. Your current name is unchanged."
            renameDetails = error.localizedDescription
            return false
        }
    }

    static func problem(_ error: AgentHandles.RenameError, name: String) -> String {
        switch error {
        case .empty: "Enter a name."
        case .taken: "Another conversation is already called \u{201C}\(name)\u{201D}. Both names are unchanged."
        case .reserved: "\u{201C}Conversation\u{201D} or \u{201C}session\u{201D} followed by a number is how you say a row, so it cannot be a name."
        }
    }

}
