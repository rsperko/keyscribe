import Foundation
import KeyScribeKit

@MainActor
final class PiDiscovery: AgentDiscovery {
    let kind = AgentKind.pi
    private var sessions: [String: AgentSession] = [:]
    private var inTurn: Set<String> = []
    private var waiting: Set<String> = []
    private let processStart: (Int) -> ProcessStart.Reading
    private let isRunning: @Sendable (Int) -> Bool
    private let processes: @Sendable () -> AgentProcesses.Found

    init(
        processStart: @escaping (Int) -> ProcessStart.Reading = ProcessStart.read(pid:),
        isRunning: @escaping @Sendable (Int) -> Bool = ProcessStart.isRunning(pid:),
        processes: @escaping @Sendable () -> AgentProcesses.Found
    ) {
        self.processStart = processStart
        self.isRunning = isRunning
        self.processes = processes
    }

    nonisolated static let partialProblem = "Some Pi conversations couldn\u{2019}t be checked. Conversations seen earlier stay listed."

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
            mark(&inTurn, hello.session, !hello.knownIdle)
            mark(&waiting, hello.session, hello.waiting != nil)
            resolve(hello.session)
        case .turnStarted(let session, _):
            mark(&inTurn, session, true)
            resolve(session)
        case .turnComplete(let session, _, _):
            mark(&inTurn, session, false)
            resolve(session)
        case .waiting(let session, let prompt):
            mark(&waiting, session, prompt != nil)
            resolve(session)
        case .title(let session, let text):
            sessions[session]?.explicitName = Self.name(text)
        case .typed, .ack, .submitted, .refused, .undelivered, .focused:
            break
        }
    }

    func scan(rereadingTitles: Bool) async -> AgentScan {
        let (pids, isRunning, processes) = (Set(sessions.values.map(\.pid)), isRunning, processes)
        let (alive, found) = await Task.detached { (pids.filter(isRunning), processes()) }.value
        sessions = sessions.filter { !pids.contains($0.value.pid) || alive.contains($0.value.pid) }
        inTurn.formIntersection(sessions.keys)
        waiting.formIntersection(sessions.keys)
        let candidates = found.candidates
        var unmatched: [AgentCandidate] = []
        for candidate in candidates {
            if let key = sessions.first(where: { Self.same(candidate, $0.value) })?.key {
                sessions[key]?.setup = candidate.setup
            } else {
                unmatched.append(candidate)
            }
        }
        var setups: [String] = []
        for setup in candidates.map(\.setup) where !setups.contains(setup) { setups.append(setup) }
        let problem = found.isPartial ? Self.partialProblem : nil
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
