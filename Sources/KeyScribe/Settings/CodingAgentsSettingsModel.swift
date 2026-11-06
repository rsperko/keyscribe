import Foundation
import KeyScribeKit

@MainActor
final class CodingAgentsSettingsModel: ObservableObject {
    enum Connector: Equatable {
        case checking
        case claudeNotFound
        case status(ClaudeConnectorStatus)
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let number: Int
        let name: String
        let folder: String
        let state: String
        let connected: Bool
        let current: Bool
        var agent = "claude"
        var terminal: String?
        var title: String?
    }

    @Published private(set) var connector: Connector = .checking
    @Published private(set) var operation: String?
    @Published private(set) var needsReload = false
    @Published private(set) var rows: [Row] = []
    @Published private(set) var renameProblem: String?
    @Published private(set) var renameDetails: String?
    @Published private(set) var namesProblem: String?

    var onRename: ((String, String) throws -> Void)?
    var onReloadNames: (() -> Void)?

    var currentName: String? { rows.first(where: \.current)?.name }
    var connectedCount: Int { rows.filter(\.connected).count }
    var showsAgentType: Bool { Set(rows.map(\.agent)).count > 1 }
    var showsRemovalWarning: Bool { connector == .status(.notInstalled) && connectedCount > 0 }

    func recipientGuidance(shortcut: String? = nil) -> String {
        guard let example = rows.first(where: \.current) ?? rows.first(where: \.connected) ?? rows.first else {
            return "Open a Claude Code conversation in your terminal. It will appear here."
        }
        if namesProblem != nil {
            return "Conversation names are unavailable. Start with the session number shown while recording, such as \u{201C}session \(example.number), run the unit tests\u{201D} for \(example.name)."
        }
        if example.current {
            guard example.connected else { return "\(example.name) is current but not connected. Connect it before speaking, or start with another conversation\u{2019}s name." }
            return "Your next instruction goes here. Start with another conversation\u{2019}s name to switch."
        }
        guard example.connected else { return "Connect Claude Code below to send instructions to these conversations." }
        let start = shortcut.map { "Use \($0)" } ?? "Start recording"
        return "\(start) and say \u{201C}\(example.name), run the unit tests.\u{201D}"
    }

    private let locateClaude: () -> String?
    private let run: @Sendable ([String]) -> (Int32, String)
    private let describeTerminal: @Sendable (Int) -> String?
    private var terminals: [Int: String?] = [:]
    private var shown: (conversations: [AgentConversation], current: String?)?
    private let agentsDir: URL
    private let pluginName: String
    private var refreshes = 0

    init(
        locateClaude: @escaping () -> String? = { ClaudeCLI.locate() },
        run: @escaping @Sendable ([String]) -> (Int32, String) = { ClaudeCLI.run($0) },
        describeTerminal: @escaping @Sendable (Int) -> String? = TerminalDescription.describe(pid:),
        agentsDir: URL, pluginName: String
    ) {
        self.locateClaude = locateClaude
        self.run = run
        self.describeTerminal = describeTerminal
        self.agentsDir = agentsDir
        self.pluginName = pluginName
    }

    private var pluginId: String { "\(pluginName)@\(pluginName)-local" }

    func refresh() async {
        guard let claude = locateClaude() else {
            connector = .claudeNotFound
            return
        }
        refreshes += 1
        let ticket = refreshes
        let (run, pluginId) = (run, pluginId)
        let (status, output) = await Task.detached { run([claude, "plugin", "list", "--json"]) }.value
        guard ticket == refreshes, operation == nil else { return }
        connector = status == 0
            ? .status(ClaudeConnectorStatus.parse(pluginList: Data(output.utf8), pluginId: pluginId, bundledVersion: ClaudeConnectorFiles.version))
            : .failed(Self.trimmed(output))
    }

    func install() async { await perform("Installing…", reloads: true) { try $0.install() } }
    func update() async { await perform("Updating…", reloads: true) { try $0.update() } }
    func remove() async { await perform("Removing…", reloads: false) { try $0.uninstall() } }

    var namesFile: URL { agentsDir.appendingPathComponent(AgentNameStore.fileName) }

    func reloadNames() {
        onReloadNames?()
    }

    func show(_ conversations: [AgentConversation], current: String?, namesProblem: String? = nil) {
        if namesProblem != self.namesProblem { self.namesProblem = namesProblem }
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
            if let shown = self.shown { self.show(shown.conversations, current: shown.current, namesProblem: self.namesProblem) }
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

    private func perform(_ progress: String, reloads: Bool, _ action: @escaping @Sendable (ClaudeConnectorInstaller) throws -> Void) async {
        guard operation == nil else { return }
        guard let claude = locateClaude() else {
            connector = .claudeNotFound
            return
        }
        operation = progress
        refreshes += 1
        let installer = ClaudeConnectorInstaller(
            agentsDir: agentsDir, pluginName: pluginName, claude: claude,
            socketPath: agentsDir.appendingPathComponent("bridge.sock").path,
            tokenPath: agentsDir.appendingPathComponent("token").path,
            run: run)
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
        operation = nil
        if let failure {
            connector = .failed(failure)
            needsReload = false
            return
        }
        needsReload = reloads
        await refresh()
    }

    private nonisolated static func trimmed(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}

enum ClaudeCLI {
    static func locate(
        named program: String = "claude",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let searched = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let usual = [
            home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
            home.appendingPathComponent(".claude/local").path,
        ]
        return (searched + usual).map { ($0 as NSString).appendingPathComponent(program) }.first(where: isExecutable)
    }

    static func run(_ argv: [String], timeout: TimeInterval = 120, grace: TimeInterval = 2) -> (Int32, String) {
        guard let program = argv.first else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = Output()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                output.finish()
            } else {
                output.append(chunk)
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            try? pipe.fileHandleForWriting.close()
            return (-1, error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()
        let command = argv.dropFirst().joined(separator: " ")
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + grace)
            }
            reader.readabilityHandler = nil
            return (-1, "\(command) did not finish within \(Int(timeout)) seconds")
        }
        if !output.waitForEnd(grace) { reader.readabilityHandler = nil }
        return (process.terminationStatus, output.text)
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let ended = DispatchSemaphore(value: 0)

        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        func finish() { ended.signal() }
        func waitForEnd(_ seconds: TimeInterval) -> Bool { ended.wait(timeout: .now() + seconds) == .success }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
