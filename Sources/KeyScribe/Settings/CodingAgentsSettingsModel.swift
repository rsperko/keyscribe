import Foundation
import KeyScribeKit

@MainActor
final class CodingAgentsSettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let number: Int
        let name: String
        let folder: String
        let state: String
        let connected: Bool
        let current: Bool
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

        var location: String? {
            guard let place else { return terminal }
            let within = "\(place.level.rawValue) \(place.label)"
            guard let terminal else { return "\(place.surface) \(within)" }
            if terminal.hasSuffix(place.surface) { return "\(terminal) \(within)" }
            return "\(terminal) \u{00B7} \(place.surface) \(within)"
        }
    }

    enum ReadAloud: Equatable {
        case thisReply, nextReply

        var note: String {
            switch self {
            case .thisReply: "Reply will be read aloud."
            case .nextReply: "Next reply will be read aloud."
            }
        }
    }

    enum RowAction: Equatable {
        case connect
        case recover(reload: String?)
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
    var onOpenAIServices: (() -> Void)?
    var voice: SpokenVoiceModel?
    private var loadingSpokenResult = false

    func load(spokenResult: SpokenResultSettings) {
        loadingSpokenResult = true
        self.spokenResult = spokenResult
        loadingSpokenResult = false
    }

    var onRename: ((String, String) throws -> Void)?
    var onReloadNames: (() -> Void)?
    var renameCheck: ((String, String) -> AgentHandles.RenameError?)?
    var defaultName: ((String) -> AgentDirectory.DefaultName?)?
    var onUseDefaultName: ((String) throws -> Void)?
    var onRetire: ((String) -> Void)? {
        didSet { for connector in connectors { connector.onRetire = onRetire } }
    }

    var currentName: String? { rows.first(where: \.current)?.name }
    var connectedCount: Int { rows.filter(\.connected).count }
    var showsAgentType: Bool { Set(rows.map(\.agent)).count > 1 }

    var hasError: Bool {
        namesProblem != nil || exclusionsNotSaved != nil || setupsProblem != nil
            || connectors.contains { $0.setups.contains(where: \.hasError) }
    }

    func recognitionContext(for row: Row) -> String? {
        guard !row.identified, rows.contains(where: {
            $0.key != row.key && $0.name == row.name && $0.folder == row.folder && $0.terminal == row.terminal
        }), let startedAt = row.startedAt else { return nil }
        return "Started \(startedAt.formatted(date: .abbreviated, time: .standard))"
    }

    func recipientGuidance(shortcut: String? = nil) -> String {
        guard let example = rows.first(where: \.current) ?? rows.first(where: \.connected) ?? rows.first else {
            return "Open a conversation in a connected coding agent. It will appear here."
        }
        if namesProblem != nil {
            return "Conversation names are unavailable. Start with \u{201C}session\u{201D} and the number shown while recording, then your instruction."
        }
        if example.current {
            guard example.connected else { return "\(example.name) is current but not connected. Connect it before speaking, or start with another conversation\u{2019}s name." }
            return "Instructions go here unless another conversation is in front of you. Start with another conversation\u{2019}s name to switch."
                + Self.checking("what are you waiting for?")
        }
        guard example.connected else { return "Choose Connect\u{2026} on a conversation to send it instructions." }
        let start = shortcut.map { "Use \($0)" } ?? "Start recording"
        return "\(start) and say \u{201C}\(example.name), run the unit tests.\u{201D}" + Self.checking("what is \(example.name) waiting for?")
    }

    private static func checking(_ question: String) -> String {
        " Say \u{201C}\(question)\u{201D} to check on it without sending anything."
    }

    private let describeTerminal: @Sendable (Int) -> String?
    private var terminals: [Int: String?] = [:]
    private var discoveryProblems: [String: String] = [:]
    private var shown: (conversations: [AgentConversation], current: String?)?
    private struct Extras {
        var setups: [String: [String]]
        var candidates: [AgentCandidate]
        var disconnected: [AgentConversation]
        var loadedVersions: [String: String]
        var lastSeen: Set<String>
        var readAloud: Set<String>
        var readNextAloud: Set<String>
    }
    private var shownExtras: Extras?
    let agentsDir: URL
    let setups: ConnectorSetupRegistry

    init(
        describeTerminal: @escaping @Sendable (Int) -> String? = TerminalDescription.describe(pid:),
        agentsDir: URL, setups: ConnectorSetupRegistry? = nil, connectors: [any AgentConnector]
    ) {
        self.describeTerminal = describeTerminal
        self.agentsDir = agentsDir
        let registry = setups ?? ConnectorSetupRegistry(directory: agentsDir)
        self.setups = registry
        self.connectors = connectors.map { AgentConnectorModel($0, registry: registry) }
        setupsProblem = registry.problem
    }

    func refresh() async {
        if setupsProblem != setups.problem { setupsProblem = setups.problem }
        for connector in connectors { await connector.refresh() }
    }

    func maintain() async {
        for connector in connectors { await connector.maintain() }
    }

    var namesFile: URL { agentsDir.appendingPathComponent(AgentNameStore.fileName) }

    func reloadNames() {
        onReloadNames?()
    }

    func show(
        _ conversations: [AgentConversation], current: String?, namesProblem: String? = nil, namesNotSaved: String? = nil,
        discoveryProblems: [String: String]? = nil, discoveredSetups: [String: [String]] = [:], candidates: [AgentCandidate] = [],
        disconnected: [AgentConversation] = [], exclusionsNotSaved: String? = nil, loadedVersions: [String: String] = [:],
        lastSeen: Set<String> = [], readAloud: Set<String> = [], readNextAloud: Set<String> = []
    ) {
        if exclusionsNotSaved != self.exclusionsNotSaved { self.exclusionsNotSaved = exclusionsNotSaved }
        shownExtras = Extras(
            setups: discoveredSetups, candidates: candidates, disconnected: disconnected, loadedVersions: loadedVersions, lastSeen: lastSeen,
            readAloud: readAloud, readNextAloud: readNextAloud)
        if setupsProblem != setups.problem { setupsProblem = setups.problem }
        if namesProblem != self.namesProblem { self.namesProblem = namesProblem }
        if let discoveryProblems { self.discoveryProblems = discoveryProblems }
        for connector in connectors where connector.discoveryProblem != self.discoveryProblems[connector.kind.id] {
            connector.discoveryProblem = self.discoveryProblems[connector.kind.id]
        }
        if namesNotSaved != self.namesNotSaved { self.namesNotSaved = namesNotSaved }
        shown = (conversations, current)
        describeNewTerminals(conversations.map(\.pid) + candidates.map(\.pid) + disconnected.map(\.pid))
        var next = conversations.enumerated().map { index, conversation in
            let lastSeen = !conversation.connectorLive && lastSeen.contains(conversation.id)
            return Row(
                id: conversation.id, number: index + 1, name: conversation.handle, folder: conversation.cwd,
                state: lastSeen ? "Last seen" : AgentRoster.stateLabel(conversation),
                connected: conversation.connectorLive,
                current: conversation.id == current, agent: conversation.agent, terminal: terminals[conversation.pid] ?? nil,
                title: conversation.title, setup: conversation.setup, key: Self.key(pid: conversation.pid, milliseconds: conversation.startedAt.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) }),
                lastSeen: lastSeen, olderConnector: runsOlderConnector(conversation, loadedVersions: loadedVersions), startedAt: conversation.startedAt,
                readAloud: readAloud.contains(conversation.id) ? .thisReply : readNextAloud.contains(conversation.id) ? .nextReply : nil,
                place: conversation.placeName, renamed: conversation.nameSource == .chosen,
                surface: conversation.placeSurface)
        }
        next += candidates.map { candidate in
            Row(
                id: "process:\(candidate.pid):\(candidate.startedAt ?? 0)", number: 0, name: name(of: candidate), folder: candidate.cwd,
                state: "Not connected", connected: false, current: false, agent: candidate.agent, terminal: terminals[candidate.pid] ?? nil,
                setup: candidate.setup, key: Self.key(pid: candidate.pid, milliseconds: candidate.startedAt), identified: false,
                startedAt: candidate.startedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
        if next != rows { rows = next }
        let away = namesProblem != nil ? [] : disconnected.map { conversation in
            Row(
                id: conversation.id, number: 0, name: conversation.handle, folder: conversation.cwd, state: "Disconnected", connected: false,
                current: false, agent: conversation.agent, terminal: terminals[conversation.pid] ?? nil, title: conversation.title,
                setup: conversation.setup, key: conversation.id, place: conversation.placeName,
                renamed: conversation.nameSource == .chosen, surface: conversation.placeSurface)
        }
        if away != disconnectedRows { disconnectedRows = away }
        for connector in connectors {
            let uses = conversations.compactMap { conversation -> AgentConnectorModel.Use? in
                guard conversation.agent == connector.kind.id, let setup = conversation.setup else { return nil }
                return AgentConnectorModel.Use(
                    folder: setup, name: conversation.handle, connected: conversation.connectorLive,
                    older: runsOlderConnector(conversation, loadedVersions: loadedVersions))
            }
            let waiting = candidates.compactMap { candidate -> AgentConnectorModel.Use? in
                guard candidate.agent == connector.kind.id else { return nil }
                return AgentConnectorModel.Use(folder: candidate.setup, name: name(of: candidate), connected: false)
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
                    shown.conversations, current: shown.current, namesProblem: self.namesProblem, namesNotSaved: self.namesNotSaved,
                    discoveredSetups: extras.setups, candidates: extras.candidates, disconnected: extras.disconnected,
                    exclusionsNotSaved: self.exclusionsNotSaved, loadedVersions: extras.loadedVersions, lastSeen: extras.lastSeen,
                    readAloud: extras.readAloud, readNextAloud: extras.readNextAloud)
            }
        }
    }

    static func older(_ loaded: String?, than bundled: String?) -> Bool {
        guard let loaded, let bundled else { return false }
        return loaded != bundled
    }

    static func key(pid: Int, milliseconds: Int?) -> String {
        "\(pid):\(milliseconds ?? 0)"
    }

    private func runsOlderConnector(_ conversation: AgentConversation, loadedVersions: [String: String]) -> Bool {
        conversation.connectorLive && Self.older(
            loadedVersions[conversation.id], than: connectors.first { $0.kind.id == conversation.agent }?.connector.bundledVersion)
    }

    private func name(of candidate: AgentCandidate) -> String {
        let agent = connectors.first { $0.kind.id == candidate.agent }?.kind.displayName ?? candidate.agent
        return "\(agent) in \(URL(fileURLWithPath: candidate.cwd).lastPathComponent)"
    }

    func connector(for row: Row) -> AgentConnectorModel? { connectors.first { $0.kind.id == row.agent } }

    func setup(for row: Row) -> ConnectorSetupModel? {
        guard let setup = row.setup else { return nil }
        return connector(for: row)?.setup(for: setup)
    }

    func action(for row: Row) -> RowAction {
        if row.connected { return .connected }
        guard let setup = setup(for: row) else { return .unknown }
        guard setup.isEnrolled else { return .connect }
        if setup.isInstalled { return .recover(reload: connector(for: row)?.kind.reloadCommand) }
        return setup.state == .checking ? .unknown : .connect
    }

    func connect(_ row: Row) {
        guard let connector = connector(for: row), let setup = setup(for: row) else { return }
        requestInstall(setup, of: connector)
    }

    func disconnect(_ row: Row) { onDisconnect?(row.id) }

    func cancelReadAloud(_ row: Row) { onCancelReadAloud?(row.id) }

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
        guard connector.connector.recognizes(folder: folder) else {
            return "\(ConnectorFolders.display(folder)) doesn\u{2019}t look like a \(connector.kind.displayName) setup folder."
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
        return "\(full) \u{201C}\(short), \u{2026}\u{201D} also works."
    }

    func defaultNameNote(_ row: Row) -> String? {
        guard let preview = defaultName?(row.id) else { return nil }
        let from = switch preview.source {
        case .place: preview.place.map { "from its \($0.surface) \($0.level.rawValue)" } ?? "from its folder"
        case .agent: "from the agent\u{2019}s own name for it"
        case .folder, .chosen: "from its folder"
        }
        return row.renamed ? "Default name: \(preview.name), \(from)." : "This name comes \(from)."
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
        case .reserved: "\u{201C}Session\u{201D} followed by a number is how you say a row, so it cannot be a name."
        }
    }

}
