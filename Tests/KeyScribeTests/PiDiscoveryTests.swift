import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct PiDiscoveryTests {
    final class Processes: @unchecked Sendable {
        var running: Set<Int> = [10, 11]
        var starts: [Int: TimeInterval] = [10: 1_700_000_000, 11: 1_700_000_050]
        func isRunning(_ pid: Int) -> Bool { running.contains(pid) }
        func start(_ pid: Int) -> ProcessStart.Reading { starts[pid].map { .started($0) } ?? .gone }
    }

    final class DuringScan: @unchecked Sendable {
        var deliver: (@MainActor () -> Void)?
    }

    private func make(_ processes: Processes = Processes()) -> PiDiscovery {
        PiDiscovery(processStart: processes.start, isRunning: processes.isRunning)
    }

    private func hello(_ session: String, pid: Int = 10, cwd: String? = "/src/api", title: String? = nil, idle: Bool = true, features: [String] = ["readiness"]) -> AgentEvent {
        .hello(.init(
            protocolVersion: 2, agent: "pi", agentVersion: "", instance: "i\(pid)", session: session, pid: pid, features: features, title: title,
            idle: idle, gap: false, cwd: cwd))
    }

    @Test func aHelloAnnouncesASessionWithItsProcessStartAsItsStartTime() async {
        let discovery = make()
        discovery.observe(hello("s1", title: "frontend"))
        let found = await discovery.scan(rereadingTitles: false)
        #expect(found == .found([AgentSession(
            agent: "pi", id: "s1", pid: 10, cwd: "/src/api", explicitName: "frontend", state: .idle, startedAt: 1_700_000_000_000)]))
    }

    @Test func aBusyHelloAndTurnEventsSetTheState() async {
        let discovery = make()
        discovery.observe(hello("s1", idle: false))
        #expect(await discovery.scan(rereadingTitles: false) == .found([AgentSession(agent: "pi", id: "s1", pid: 10, cwd: "/src/api", state: .working, startedAt: 1_700_000_000_000)]))
        discovery.observe(.turnComplete(session: "s1", reason: "complete", answer: ""))
        #expect(sessions(await discovery.scan(rereadingTitles: false)).map(\.state) == [.idle])
        discovery.observe(.turnStarted(session: "s1", turn: "t2"))
        #expect(sessions(await discovery.scan(rereadingTitles: false)).map(\.state) == [.working])
    }

    @Test func aHelloWithoutReadinessIsNotAssumedIdle() async {
        let discovery = make()
        discovery.observe(hello("s1", idle: true, features: []))
        #expect(sessions(await discovery.scan(rereadingTitles: false)).map(\.state) == [.working])
    }

    @Test func aTitleEventRenamesTheSessionAndAnEmptyOneClearsIt() async {
        let discovery = make()
        discovery.observe(hello("s1", title: "frontend"))
        discovery.observe(.title(session: "s1", text: "backend"))
        #expect(sessions(await discovery.scan(rereadingTitles: false)).map(\.explicitName) == ["backend"])
        discovery.observe(.title(session: "s1", text: ""))
        #expect(sessions(await discovery.scan(rereadingTitles: false)).map(\.explicitName) == [nil])
    }

    @Test func aNewSessionOnTheSameProcessReplacesTheOldOne() async {
        let discovery = make()
        discovery.observe(hello("s1"))
        discovery.observe(hello("s2", cwd: "/src/docs"))
        let found = sessions(await discovery.scan(rereadingTitles: false))
        #expect(found.map(\.id) == ["s2"])
        #expect(found.map(\.cwd) == ["/src/docs"])
    }

    @Test func aSecondHelloForTheSameSessionKeepsItsStartTimeAndUpdatesTheRest() async {
        let processes = Processes()
        let discovery = make(processes)
        discovery.observe(hello("s1", title: "one"))
        processes.starts[10] = 1_700_000_999
        discovery.observe(hello("s1", title: "two", idle: false))
        let found = sessions(await discovery.scan(rereadingTitles: false))
        #expect(found.map(\.startedAt) == [1_700_000_000_000])
        #expect(found.map(\.explicitName) == ["two"])
        #expect(found.map(\.state) == [.working])
    }

    @Test func aSessionWhoseProcessIsGoneLeavesTheList() async {
        let processes = Processes()
        let discovery = make(processes)
        discovery.observe(hello("s1", pid: 10))
        discovery.observe(hello("s2", pid: 11, cwd: "/src/docs"))
        processes.running = [11]
        #expect(sessions(await discovery.scan(rereadingTitles: false)).map(\.id) == ["s2"])
        processes.running = []
        #expect(await discovery.scan(rereadingTitles: false) == .found([]))
    }

    @Test func aHelloArrivingWhileAScanIsCheckingProcessesSurvivesIt() async {
        let during = DuringScan()
        let discovery = PiDiscovery(
            processStart: Processes().start,
            isRunning: { pid in
                DispatchQueue.main.async { MainActor.assumeIsolated { during.deliver?() } }
                return pid != 99
            })
        discovery.observe(hello("s1", pid: 10))
        discovery.observe(hello("gone", pid: 99))
        let late = hello("s2", pid: 11, cwd: "/src/docs")
        during.deliver = { discovery.observe(late) }
        #expect(sessions(await discovery.scan(rereadingTitles: false)).map(\.id) == ["s1", "s2"])
    }

    @Test func aHelloWhoseProcessStartCannotBeReadHasNoStartTimeUntilALaterHelloReadsIt() async {
        let processes = Processes()
        processes.starts = [:]
        let discovery = make(processes)
        discovery.observe(hello("s1", cwd: nil))
        let found = sessions(await discovery.scan(rereadingTitles: false))
        #expect(found.map(\.startedAt) == [nil])
        #expect(found.map(\.cwd) == [""])
        processes.starts[10] = 1_700_000_000
        discovery.observe(hello("s1", cwd: nil))
        #expect(sessions(await discovery.scan(rereadingTitles: false)).map(\.startedAt) == [1_700_000_000_000])
    }

    @Test func aHelloForAKnownSessionFromAnotherProcessTakesThatProcessesStartTime() async {
        let processes = Processes()
        let discovery = make(processes)
        discovery.observe(hello("s1", pid: 10))
        discovery.observe(hello("s1", pid: 11))
        let found = sessions(await discovery.scan(rereadingTitles: false))
        #expect(found.map { ($0.pid, $0.startedAt) }.map { "\($0.0) \($0.1 ?? 0)" } == ["11 1700000050000"])
    }

    @Test func retiringForgetsEverySession() async {
        let discovery = make()
        discovery.observe(hello("s1"))
        discovery.retire()
        #expect(await discovery.scan(rereadingTitles: false) == .found([]))
    }

    @Test func eventsForUnknownSessionsAndRequestEventsChangeNothing() async {
        let discovery = make()
        discovery.observe(.turnStarted(session: "ghost", turn: "t1"))
        discovery.observe(.title(session: "ghost", text: "x"))
        discovery.observe(.submitted(request: "r1", turn: "t1"))
        #expect(await discovery.scan(rereadingTitles: false) == .found([]))
    }

    @Test func aRememberedNameStaysReservedWhileItsProcessStartMatches() {
        let processes = Processes()
        let discovery = make(processes)
        #expect(discovery.stillRunning(RememberedName(name: "api", pid: 10, startedAt: 1_700_000_000_000, native: nil, agent: "pi")))
        #expect(!discovery.stillRunning(RememberedName(name: "api", pid: 10, startedAt: 1_600_000_000_000, native: nil, agent: "pi")))
        #expect(!discovery.stillRunning(RememberedName(name: "api", pid: 12, startedAt: 1_700_000_000_000, native: nil, agent: "pi")))
    }

    private func sessions(_ scan: AgentScan) -> [AgentSession] {
        if case .found(let sessions) = scan { return sessions.sorted { $0.id < $1.id } }
        return []
    }
}

struct ProcessStartTests {
    @Test func theCurrentProcessHasAStartTimeAndAMissingOneIsGone() {
        guard case .started(let at) = ProcessStart.read(pid: Int(getpid())) else {
            Issue.record("own process not found")
            return
        }
        #expect(at <= Date().timeIntervalSince1970)
        #expect(at > Date().timeIntervalSince1970 - 86_400)
        #expect(ProcessStart.read(pid: 999_999) == .gone)
        #expect(ProcessStart.isRunning(pid: Int(getpid())))
        #expect(!ProcessStart.isRunning(pid: 999_999))
    }

    @Test func aRememberedProcessStillRunsWhenItsStartTimeIsWithinTheLead() {
        guard case .started(let at) = ProcessStart.read(pid: Int(getpid())) else {
            Issue.record("own process not found")
            return
        }
        let recorded = Int(at * 1000)
        let name = { (startedAt: Int) in RememberedName(name: "x", pid: Int(getpid()), startedAt: startedAt, native: nil, agent: "") }
        #expect(ProcessStart.stillRunning(name(recorded), lead: 1))
        #expect(ProcessStart.stillRunning(name(recorded + 60_000), lead: 120))
        #expect(!ProcessStart.stillRunning(name(recorded + 60_000), lead: 1))
        #expect(!ProcessStart.stillRunning(name(recorded - 5_000), lead: 120))
        #expect(!ProcessStart.stillRunning(RememberedName(name: "x", pid: 999_999, startedAt: recorded, native: nil, agent: ""), lead: 120))
    }
}
