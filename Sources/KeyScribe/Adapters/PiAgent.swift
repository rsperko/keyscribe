import Foundation
import KeyScribeKit

@MainActor
final class PiDiscovery: AgentDiscovery {
    let kind = AgentKind.pi
    private var sessions: [String: AgentSession] = [:]
    private let processStart: (Int) -> ProcessStart.Reading
    private let isRunning: @Sendable (Int) -> Bool

    init(
        processStart: @escaping (Int) -> ProcessStart.Reading = ProcessStart.read(pid:),
        isRunning: @escaping @Sendable (Int) -> Bool = ProcessStart.isRunning(pid:)
    ) {
        self.processStart = processStart
        self.isRunning = isRunning
    }

    func observe(_ event: AgentEvent) {
        switch event {
        case .hello(let hello):
            sessions = sessions.filter { $0.key == hello.session || $0.value.pid != hello.pid }
            sessions[hello.session] = AgentSession(
                agent: kind.id, id: hello.session, pid: hello.pid, cwd: hello.cwd ?? "", explicitName: Self.name(hello.title),
                state: hello.knownIdle ? .idle : .working,
                startedAt: sessions[hello.session].flatMap { $0.pid == hello.pid ? $0.startedAt : nil } ?? startedAt(of: hello.pid))
        case .turnStarted(let session, _):
            sessions[session]?.state = .working
        case .turnComplete(let session, _, _):
            sessions[session]?.state = .idle
        case .title(let session, let text):
            sessions[session]?.explicitName = Self.name(text)
        case .typed, .ack, .submitted, .refused, .undelivered, .focused:
            break
        }
    }

    func scan(rereadingTitles: Bool) async -> AgentScan {
        let (pids, isRunning) = (Set(sessions.values.map(\.pid)), isRunning)
        let alive = await Task.detached { pids.filter(isRunning) }.value
        sessions = sessions.filter { !pids.contains($0.value.pid) || alive.contains($0.value.pid) }
        return .found(sessions.values.sorted { $0.id < $1.id })
    }

    func stillRunning(_ remembered: RememberedName) -> Bool {
        ProcessStart.stillRunning(remembered, lead: 1, reading: processStart)
    }

    func retire() {
        sessions = [:]
    }

    private func startedAt(of pid: Int) -> Int? {
        if case .started(let at) = processStart(pid) { return Int((at * 1000).rounded()) }
        return nil
    }

    private static func name(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }
}
