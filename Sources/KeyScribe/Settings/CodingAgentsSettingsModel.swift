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
    }

    let connectors: [AgentConnectorModel]
    @Published private(set) var rows: [Row] = []
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
    var onRetire: ((AgentKind) -> Void)? {
        didSet { for connector in connectors { connector.onRetire = onRetire } }
    }

    var currentName: String? { rows.first(where: \.current)?.name }
    var connectedCount: Int { rows.filter(\.connected).count }
    var showsAgentType: Bool { Set(rows.map(\.agent)).count > 1 }

    func recipientGuidance(shortcut: String? = nil) -> String {
        guard let example = rows.first(where: \.current) ?? rows.first(where: \.connected) ?? rows.first else {
            return "Open a conversation in a connected coding agent. It will appear here."
        }
        if namesProblem != nil {
            return "Conversation names are unavailable. Start with the session number shown while recording, such as \u{201C}session \(example.number), run the unit tests\u{201D} for \(example.name)."
        }
        if example.current {
            guard example.connected else { return "\(example.name) is current but not connected. Connect it before speaking, or start with another conversation\u{2019}s name." }
            return "Instructions go here unless another conversation is in front of you. Start with another conversation\u{2019}s name to switch."
        }
        guard example.connected else { return "Connect its agent below to send instructions to these conversations." }
        let start = shortcut.map { "Use \($0)" } ?? "Start recording"
        return "\(start) and say \u{201C}\(example.name), run the unit tests.\u{201D}"
    }

    private let describeTerminal: @Sendable (Int) -> String?
    private var terminals: [Int: String?] = [:]
    private var discoveryProblems: [String: String] = [:]
    private var shown: (conversations: [AgentConversation], current: String?)?
    let agentsDir: URL

    init(
        describeTerminal: @escaping @Sendable (Int) -> String? = TerminalDescription.describe(pid:),
        agentsDir: URL, connectors: [any AgentConnector]
    ) {
        self.describeTerminal = describeTerminal
        self.agentsDir = agentsDir
        self.connectors = connectors.map(AgentConnectorModel.init)
    }

    func refresh() async {
        for connector in connectors { await connector.refresh() }
    }

    var namesFile: URL { agentsDir.appendingPathComponent(AgentNameStore.fileName) }

    func reloadNames() {
        onReloadNames?()
    }

    func show(
        _ conversations: [AgentConversation], current: String?, namesProblem: String? = nil, namesNotSaved: String? = nil,
        discoveryProblems: [String: String]? = nil
    ) {
        if namesProblem != self.namesProblem { self.namesProblem = namesProblem }
        if let discoveryProblems { self.discoveryProblems = discoveryProblems }
        for connector in connectors where connector.discoveryProblem != self.discoveryProblems[connector.kind.id] {
            connector.discoveryProblem = self.discoveryProblems[connector.kind.id]
        }
        if namesNotSaved != self.namesNotSaved { self.namesNotSaved = namesNotSaved }
        shown = (conversations, current)
        describeNewTerminals(conversations.map(\.pid))
        let described = conversations.map { terminals[$0.pid] ?? nil }
        let next = conversations.enumerated().map { index, conversation in
            Row(
                id: conversation.id, number: index + 1, name: conversation.handle, folder: conversation.cwd,
                state: AgentRoster.stateLabel(conversation),
                connected: conversation.connectorLive,
                current: conversation.id == current, agent: conversation.agent, terminal: described[index], title: conversation.title)
        }
        if next != rows { rows = next }
        for connector in connectors {
            let mine = next.filter { $0.agent == connector.kind.id }
            if connector.sessions != mine.count { connector.sessions = mine.count }
            let connected = mine.filter(\.connected).count
            if connector.connectedCount != connected { connector.connectedCount = connected }
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
            if let shown = self.shown { self.show(shown.conversations, current: shown.current, namesProblem: self.namesProblem, namesNotSaved: self.namesNotSaved) }
        }
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

    static func problem(_ error: AgentHandles.RenameError, name: String) -> String {
        switch error {
        case .empty: "Enter a name."
        case .taken: "Another conversation is already called \u{201C}\(name)\u{201D}. Both names are unchanged."
        case .reserved: "\u{201C}Session\u{201D} followed by a number is how you say a row, so it cannot be a name."
        }
    }

}
