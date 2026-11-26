import Foundation
import KeyScribeKit

@MainActor
final class ExtensionDiscovery: AgentDiscovery {
    let kind: AgentKind
    private var sessions: [String: AgentSession] = [:]
    private var inTurn: Set<String> = []
    private var waiting: Set<String> = []
    private let processStart: (Int) -> ProcessStart.Reading
    private let isRunning: @Sendable (Int) -> Bool
    private let processes: @Sendable (_ reusing: Bool) -> AgentProcesses.Found
    private let folder: (String) -> String?
    private let declared: () -> String?
    private var installations: [String: String] = [:]

    init(
        kind: AgentKind,
        processStart: @escaping (Int) -> ProcessStart.Reading = ProcessStart.read(pid:),
        isRunning: @escaping @Sendable (Int) -> Bool = ProcessStart.isRunning(pid:),
        processes: @escaping @Sendable (_ reusing: Bool) -> AgentProcesses.Found,
        folder: @escaping (String) -> String? = { _ in nil },
        declared: @escaping () -> String? = { nil }
    ) {
        self.kind = kind
        self.folder = folder
        self.declared = declared
        self.processStart = processStart
        self.isRunning = isRunning
        self.processes = processes
    }

    nonisolated static func partialProblem(_ kind: AgentKind) -> String {
        "Some \(kind.displayName) conversations couldn\u{2019}t be checked. Conversations seen earlier stay listed."
    }

    func observe(_ event: AgentEvent) {
        switch event {
        case .hello(let hello):
            sessions = sessions.filter { $0.key == hello.session || $0.value.pid != hello.pid }
            let known = sessions[hello.session].flatMap { $0.pid == hello.pid ? $0.explicitName : nil }
            sessions[hello.session] = AgentSession(
                agent: kind.id, id: hello.session, pid: hello.pid, cwd: hello.cwd ?? "",
                explicitName: hello.quiet ? known : Self.name(hello.title),
                state: .idle,
                startedAt: sessions[hello.session].flatMap { $0.pid == hello.pid ? $0.startedAt : nil } ?? startedAt(of: hello.pid))
            if let installation = hello.installation { installations[hello.session] = installation }
            sessions[hello.session]?.setup = installations[hello.session].flatMap(folder)
            mark(&inTurn, hello.session, !hello.knownIdle)
            mark(&waiting, hello.session, hello.waiting != nil)
            resolve(hello.session)
        case .turnStarted(let session, _, _):
            mark(&inTurn, session, true)
            resolve(session)
        case .turnComplete(let session, _, _, _, _):
            mark(&inTurn, session, false)
            resolve(session)
        case .waiting(let session, let prompt):
            mark(&waiting, session, prompt != nil)
            resolve(session)
        case .title(let session, let text):
            sessions[session]?.explicitName = Self.name(text)
        case .typed, .absorbed, .ack, .submitted, .checked, .refused, .undelivered, .focused, .notify, .shown:
            break
        }
    }

    func listed(_ native: String) -> AgentSession? { sessions[native] }

    func current(_ scanned: [AgentSession]) -> [AgentSession] { scanned.map { sessions[$0.id] ?? $0 } }

    func scan(rereadingTitles: Bool, reusingProcesses: Bool) async -> AgentScan {
        let (pids, isRunning, processes) = (Set(sessions.values.compactMap(\.pid)), isRunning, processes)
        let (alive, found) = await Task.detached { (pids.filter(isRunning), processes(reusingProcesses)) }.value
        sessions = sessions.filter { $0.value.pid.map { !pids.contains($0) || alive.contains($0) } ?? true }
        inTurn.formIntersection(sessions.keys)
        waiting.formIntersection(sessions.keys)
        installations = installations.filter { sessions[$0.key] != nil }
        let candidates = found.candidates
        var unmatched: [AgentCandidate] = []
        for candidate in candidates {
            if let key = sessions.first(where: { Self.same(candidate, $0.value) })?.key {
                sessions[key]?.setup = installations[key].flatMap(folder) ?? candidate.setup
            } else {
                unmatched.append(candidate)
            }
        }
        for key in sessions.keys {
            if let reported = installations[key].flatMap(folder) { sessions[key]?.setup = reported }
        }
        var setups: [String] = []
        let listed = sessions.values.compactMap(\.setup) + candidates.compactMap(\.setup) + (declared().map { [$0] } ?? [])
        for setup in listed where !setups.contains(setup) { setups.append(setup) }
        let problem = found.isPartial ? Self.partialProblem(kind) : nil
        return .found(sessions.values.sorted { $0.id < $1.id }, AgentScanExtras(candidates: unmatched, setups: setups, problem: problem))
    }

    static func same(_ candidate: AgentCandidate, _ session: AgentSession) -> Bool {
        guard candidate.pid == session.pid else { return false }
        guard let started = candidate.startedAt, let known = session.startedAt else { return true }
        return started == known
    }

    func stillRunning(_ remembered: RememberedName) -> Bool {
        ProcessStart.stillRunning(remembered, lead: 1, reading: processStart)
    }

    func retire(sessions retiring: Set<String>) {
        sessions = sessions.filter { !retiring.contains($0.key) }
        installations = installations.filter { !retiring.contains($0.key) }
        inTurn.subtract(retiring)
        waiting.subtract(retiring)
    }

    private func mark(_ set: inout Set<String>, _ session: String, _ member: Bool) {
        if member { set.insert(session) } else { set.remove(session) }
    }

    private func resolve(_ session: String) {
        sessions[session]?.state = waiting.contains(session) ? .userDialog : inTurn.contains(session) ? .working : .idle
    }

    private func startedAt(of pid: Int) -> Int? {
        if case .started(let at) = processStart(pid) { return at }
        return nil
    }

    private static func name(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }
}

extension AgentIntegration {
    static func extensionAgent(_ agent: ExtensionAgent) -> AgentIntegration {
        let rule = agent.rule
        return AgentIntegration(
            kind: agent.kind,
            rule: rule,
            discovery: { setups, processes in
                ExtensionDiscovery(
                    kind: agent.kind,
                    processes: { processes.found(rule, reusing: $0) },
                    folder: { installation in setups.setups?.setups.first { $0.agent == agent.kind.id && $0.installation == installation }?.folder },
                    declared: {
                        ToolEnvironment.shared.folder(rule.setupVariable).flatMap { path in
                            FileManager.default.fileExists(atPath: path) ? ConnectorFolders.canonical(URL(fileURLWithPath: path, isDirectory: true)).path : nil
                        }
                    })
            },
            connector: { ExtensionConnector(agent: agent, agentsDir: $0, pluginName: $1, surfaces: $2) })
    }
}
