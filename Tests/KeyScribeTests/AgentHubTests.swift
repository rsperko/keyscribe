import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentHubTests {
    private func untilSent(_ transport: FakeTransport, _ count: Int) async {
        for _ in 0..<10_000 where transport.sent.count < count { await Task.yield() }
    }

    final class FakeTransport: AgentTransport {
        var live: Set<String> = []
        var sent: [(AgentCommand, String)] = []
        var withdrawn: [String] = []
        func enqueue(_ command: AgentCommand, for session: String) { sent.append((command, session)) }
        func withdraw(_ id: String) -> Bool {
            withdrawn.append(id)
            return true
        }
        func isLive(session: String) -> Bool { live.contains(session) }
    }

    final class Registry {
        var entries: [ClaudeRegistryEntry] = []
        func set(_ session: String, status: String = "idle", cwd: String = "/src/keyscribe", pid: Int = 10, startedAt: Int? = nil) {
            entries.removeAll { $0.sessionId == session }
            entries.append(ClaudeRegistryEntry(pid: pid, sessionId: session, cwd: cwd, name: nil, status: status, waitingFor: nil, startedAt: startedAt))
        }
    }

    final class Clock { var now = Date(timeIntervalSince1970: 1000) }

    private func makeHub(receiptTimeout: Duration = .seconds(5), clock: Clock = Clock()) -> (AgentHub, FakeTransport, Registry, Notices) {
        let transport = FakeTransport()
        let registry = Registry()
        let notices = Notices()
        var counter = 0
        let hub = AgentHub(transport: transport, scan: { registry.entries }, receiptTimeout: receiptTimeout, now: { clock.now }) {
            counter += 1
            return "r\(counter)"
        }
        hub.onNotice = { receipt, request in
            notices.items.append(receipt)
            notices.requests.append(request)
        }
        return (hub, transport, registry, notices)
    }

    final class Notices {
        var items: [AgentReceipt] = []
        var requests: [String] = []
    }

    private func connected(_ hub: AgentHub, _ transport: FakeTransport, _ registry: Registry, _ session: String = "s1", status: String = "idle") {
        registry.set(session, status: status)
        transport.live.insert(session)
        hub.refresh()
    }

    @Test func anIdleConversationIsSentAndConfirmedByTheConnector() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.map(\.0) == [.submit(id: "r1", expectedSession: "s1", text: "run the tests")])
        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(await receipt == .sent("keyscribe"))
    }

    @Test func aSubmitIsFencedOnThePromptCountTheHubLastHeard() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s1", pid: 0, prompts: 2)))
        hub.handle(.typed(session: "s1", prompts: 3))

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.map(\.0) == [.submit(id: "r1", expectedSession: "s1", text: "run the tests", expectedPrompts: 3)])
        hub.handle(.submitted(request: "r1", turn: ""))
        _ = await receipt
    }

    @Test func aSubmitRefusedBecauseTheUserTypedIsKeptForReview() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "typedSince"))
        #expect(await receipt == .kept("keyscribe", reason: .typedSince))
        #expect(hub.unsent.map(\.text) == ["run the tests"])
    }

    @Test func aSubmitRefusedOverAMessageTheUserIsWritingIsKeptForReview() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "draft"))
        #expect(await receipt == .kept("keyscribe", reason: .composing))
        #expect(hub.unsent.map(\.text) == ["run the tests"])
    }

    private func ready(idle: Bool = true, gap: Bool) -> AgentEvent.Hello {
        .init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s1", pid: 0, features: ["readiness"], idle: idle, gap: gap)
    }

    private func greet(_ hub: AgentHub, _ hello: AgentEvent.Hello) {
        hub.prepare(for: hello)
        hub.handle(.hello(hello))
    }

    @Test func aTakeHeldAcrossAConnectionGapIsKeptForReviewNotSent() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry, status: "busy")
        #expect(await hub.deliver("run the tests", to: "s1", delivery: .submit) == .queued("keyscribe"))

        registry.set("s1", status: "idle")
        greet(hub, ready(gap: true))
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.isEmpty)
        #expect(notices.items == [.kept("keyscribe", reason: .connectionGap)])
        #expect(hub.unsent.map(\.text) == ["run the tests"])
    }

    @Test func aReconnectDuringATurnKeepsTheOlderTakeForReviewAndSendsTheNewerOneWhenTheTurnEnds() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry, status: "busy")
        greet(hub, ready(idle: false, gap: false))
        hub.handle(.turnStarted(session: "s1", turn: "t1"))
        #expect(await hub.deliver("before the drop", to: "s1", delivery: .submit) == .queued("keyscribe"))

        greet(hub, ready(idle: false, gap: true))
        #expect(notices.items == [.kept("keyscribe", reason: .connectionGap)])
        #expect(await hub.deliver("after the drop", to: "s1", delivery: .submit) == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)

        registry.set("s1", status: "idle")
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0) == [.submit(id: "r2", expectedSession: "s1", text: "after the drop")])
        hub.handle(.submitted(request: "r2", turn: ""))
        #expect(notices.items == [.kept("keyscribe", reason: .connectionGap), .sent("keyscribe")])
        #expect(hub.unsent.map(\.text) == ["before the drop"])
    }

    @Test func aTakeTheBridgeWithdrewAtAGapIsKeptForReview() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "connectionGap", handedOff: false))
        #expect(await receipt == .kept("keyscribe", reason: .connectionGap))
        #expect(hub.unsent.map(\.text) == ["run the tests"])
    }

    @Test func aTakeThatMayHaveBeenIssuedBeforeTheGapStaysUncertain() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "connectionGap", handedOff: true))
        #expect(await receipt == .uncertain("keyscribe"))
    }

    @Test func aConnectorThatReportsARunningTurnIsBusy() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        greet(hub, ready(idle: false, gap: false))
        #expect(await hub.deliver("run the tests", to: "s1", delivery: .submit) == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)
    }

    @Test func aConnectorThatReportsNoTurnAndNoGapIsReady() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        greet(hub, ready(gap: false))
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.map(\.0.id) == ["r1"])
        hub.handle(.submitted(request: "r1", turn: ""))
        _ = await receipt
    }

    @Test func aConnectorThatCannotReportItsTurnIsNotAssumedIdle() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        let old = AgentEvent.Hello(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s1", pid: 0, features: ["focus"])
        greet(hub, old)
        #expect(await hub.deliver("run the tests", to: "s1", delivery: .submit) == .queued("keyscribe"))
    }

    @Test func aSubmitRefusedBecauseATurnIsRunningWaitsForItToFinish() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry)
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(await receipt == .queued("keyscribe"))
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0.id) == ["r1", "r1"])
        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
    }

    @Test func aBusyConversationQueuesAndSendsWhenTheTurnCompletes() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry, status: "busy")

        #expect(await hub.deliver("run the tests", to: "s1", delivery: .submit) == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)

        registry.set("s1", status: "idle")
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0) == [.submit(id: "r1", expectedSession: "s1", text: "run the tests")])
        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
    }

    @Test func aLateReceiptCarriesTheRequestIdTheCallerGave() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry, status: "busy")

        #expect(await hub.deliver("run the tests", to: "s1", delivery: .submit, request: "entry-1") == .queued("keyscribe"))
        registry.set("s1", status: "idle")
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0) == [.submit(id: "entry-1", expectedSession: "s1", text: "run the tests")])
        hub.handle(.submitted(request: "entry-1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
        #expect(notices.requests == ["entry-1"])
    }

    @Test func aSecondMessageWaitsForTheFirstOnesTurn() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let first = hub.deliver("one", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: ""))
        _ = await first
        #expect(await hub.deliver("two", to: "s1", delivery: .submit) == .queued("keyscribe"))

        hub.handle(.turnStarted(session: "s1", turn: "t1"))
        hub.refresh()
        #expect(transport.sent.count == 1)
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.count == 2)
    }

    @Test func aConversationWithoutItsConnectorIsNotSentAndKept() async {
        let (hub, _, registry, _) = makeHub()
        registry.set("s1")
        hub.refresh()

        let receipt = await hub.deliver("run the tests", to: "s1", delivery: .submit)
        #expect(receipt == .notSent("keyscribe", reason: .connectorNotRunning))
        #expect(hub.unsent.map(\.text) == ["run the tests"])
    }

    @Test func anEndedConversationIsNotSent() async {
        let (hub, _, _, _) = makeHub()
        #expect(await hub.deliver("run the tests", to: "gone", delivery: .submit) == .notSent(nil, reason: .conversationEnded))
    }

    @Test func aRefusalIsReportedAndTheMessageKept() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "sessionChanged"))
        #expect(await receipt == .notSent("keyscribe", reason: .conversationChanged))
        #expect(hub.unsent.map(\.text) == ["run the tests"])
    }

    @Test func aHandoffThatMayHaveLandedIsUncertainNotRetried() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "instanceGone", handedOff: true))
        #expect(await receipt == .uncertain("keyscribe"))
        #expect(hub.unsent.isEmpty)
    }

    @Test func aHandoffThatMayHaveLandedStillBlocksTheNextMessageAndReportsItsLateResult() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let first = hub.deliver("one", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "instanceGone", handedOff: true))
        #expect(await first == .uncertain("keyscribe"))
        #expect(await hub.deliver("two", to: "s1", delivery: .submit) == .queued("keyscribe"))
        #expect(transport.sent.count == 1)

        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
        hub.handle(.turnStarted(session: "s1", turn: "t1"))
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func aPossibleHandoffFollowedByTheTimeoutIsReportedOnce() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let first = hub.deliver("one", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "instanceGone", handedOff: true))
        #expect(await first == .uncertain("keyscribe"))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(notices.items.isEmpty)
        #expect(hub.recent == [.uncertain("keyscribe")])
    }

    @Test func aLateRefusalAfterAPossibleHandoffKeepsTheTextAndReleasesTheQueue() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let first = hub.deliver("one", to: "s1", delivery: .submit)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "instanceGone", handedOff: true))
        _ = await first
        _ = await hub.deliver("two", to: "s1", delivery: .submit)

        hub.handle(.refused(request: "r1", reason: "sessionChanged"))
        #expect(notices.items == [.notSent("keyscribe", reason: .conversationChanged)])
        #expect(hub.unsent.map(\.text) == ["one"])
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func noAnswerFromTheConnectorIsUncertain() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20))
        connected(hub, transport, registry)
        #expect(await hub.deliver("run the tests", to: "s1", delivery: .submit) == .uncertain("keyscribe"))
    }

    @Test func typingIntoAConversationMakesItTheCurrentRecipient() {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry, "s1")
        connected(hub, transport, registry, "s2")
        hub.makeCurrent("s1")
        hub.handle(.typed(session: "s2"))
        #expect(hub.current == "s2")
    }

    @Test func theRecordingListFollowsTheLastConversationsUsed() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), clock: clock)
        registry.set("s1", cwd: "/src/alpha")
        registry.set("s2", cwd: "/src/bravo")
        registry.set("s3", cwd: "/src/charlie")
        transport.live.formUnion(["s1", "s2", "s3"])
        hub.refresh()
        #expect(hub.recordingOrder.map(\.id) == ["s1", "s2", "s3"])
        hub.handle(.typed(session: "s3"))
        clock.now += 1
        hub.makeCurrent("s2")
        #expect(hub.recordingOrder.map(\.id) == ["s2", "s3", "s1"])
        clock.now += 1
        _ = await hub.deliver("run the tests", to: "s1", delivery: .submit)
        #expect(hub.recordingOrder.map(\.id) == ["s2", "s1", "s3"])
    }

    @Test func aConversationStartedAfterTheLastUseLeadsTheRecordingList() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), clock: clock)
        registry.set("s1", cwd: "/src/alpha", pid: 10, startedAt: 100_000)
        registry.set("s2", cwd: "/src/bravo", pid: 20, startedAt: 200_000)
        transport.live.formUnion(["s1", "s2"])
        hub.refresh()
        _ = await hub.deliver("run the tests", to: "s1", delivery: .submit)
        #expect(hub.current == nil)
        #expect(hub.recordingOrder.map(\.id) == ["s1", "s2"])
        registry.set("s3", cwd: "/src/charlie", pid: 30, startedAt: Int(clock.now.timeIntervalSince1970 * 1000) + 500)
        transport.live.insert("s3")
        hub.refresh()
        #expect(hub.recordingOrder.map(\.id) == ["s3", "s1", "s2"])
        clock.now += 1
        _ = await hub.deliver("run the tests", to: "s2", delivery: .submit)
        #expect(hub.recordingOrder.map(\.id) == ["s2", "s3", "s1"])
    }

    @Test func typingIntoTheConversationWhileQueuedHoldsItForReview() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry, status: "busy")
        _ = await hub.deliver("run the tests", to: "s1", delivery: .submit)

        hub.handle(.typed(session: "s1"))
        registry.set("s1", status: "idle")
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.isEmpty)
        #expect(notices.items == [.kept("keyscribe", reason: .typedSince)])
        #expect(hub.unsent.map(\.text) == ["run the tests"])
    }

    @Test func aReviewModeTakeIsKeptAsADraft() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        #expect(await hub.deliver("run the tests", to: "s1", delivery: .draft) == .kept("keyscribe", reason: .draft))
        #expect(transport.sent.isEmpty)
        #expect(hub.unsent.map(\.text) == ["run the tests"])
    }

    @Test func namesAndRowsFollowTheDirectory() {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry, "s1")
        connected(hub, transport, registry, "s2")
        #expect(hub.names == ["keyscribe": "s1", "keyscribe blue": "s2"])
        #expect(hub.rows == ["s1", "s2"])
    }

    @Test func renamingAConversationChangesItsNameAndTellsListeners() throws {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry, "s1")
        var changes = 0
        hub.onChange = { changes += 1 }
        try hub.rename("s1", to: "Backend")
        #expect(hub.names == ["backend": "s1"])
        #expect(changes == 1)
    }

    @Test func aNameAnotherConversationHoldsIsRefusedAndNothingChanges() {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry, "s1")
        connected(hub, transport, registry, "s2")
        #expect(throws: AgentHandles.RenameError.taken) { try hub.rename("s2", to: "keyscribe") }
        #expect(hub.names == ["keyscribe": "s1", "keyscribe blue": "s2"])
    }

    @Test func chosenNamesSurviveARestartThroughTheNameFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        registry.set("b", cwd: "/src/docs")
        let store = AgentNameStore(directory: dir)
        let first = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: store)
        first.refresh()
        try first.rename("a", to: "backend")
        try first.rename("b", to: "api")

        let second = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir))
        second.refresh()
        #expect(second.names == ["backend": "a", "api": "b"])
    }

    @Test func generatedNamesSurviveARestartForSessionsStillRunning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", pid: 10, startedAt: 100)
        registry.set("b", pid: 20, startedAt: 200)
        let first = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir))
        first.refresh()
        #expect(first.names == ["keyscribe": "a", "keyscribe blue": "b"])
        try first.rename("a", to: "backend")
        registry.entries.reverse()
        registry.set("c", pid: 30, startedAt: 300)

        let second = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir))
        second.refresh()
        #expect(second.names == ["backend": "a", "keyscribe blue": "b", "keyscribe": "c"])
    }

    @Test func aClosedSessionsGeneratedNameIsDroppedFromTheNameFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", pid: 10, startedAt: 100)
        registry.set("b", pid: 20, startedAt: 200)
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir))
        hub.refresh()
        registry.entries.removeAll { $0.sessionId == "a" }
        hub.refresh()
        #expect(AgentNameStore(directory: dir).load() == .names([:], remembered: [
            "b": RememberedName(name: "keyscribe blue", pid: 20, startedAt: 200, native: nil),
        ]))
    }

    @Test func aSessionAStartupScanMissedKeepsItsSavedNameWhileItsProcessRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", pid: 10, startedAt: 100)
        registry.set("b", pid: 20, startedAt: 200)
        AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir)).refresh()
        let missing = registry.entries.first { $0.sessionId == "a" }!
        registry.entries.removeAll { $0.sessionId == "a" }
        registry.set("c", pid: 30, startedAt: 300)

        let second = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir),
                              stillRunning: { $0.pid == 10 })
        second.refresh()
        #expect(second.names == ["keyscribe blue": "b", "keyscribe green": "c"])
        guard case .names(_, let remembered) = AgentNameStore(directory: dir).load() else { Issue.record("names not loaded"); return }
        #expect(remembered["a"]?.name == "keyscribe")
        registry.entries.append(missing)
        second.refresh()
        #expect(second.names == ["keyscribe": "a", "keyscribe blue": "b", "keyscribe green": "c"])
    }

    @Test func generatedNamesThatCannotBeSavedAreReportedAndRetried() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: dir.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", pid: 10, startedAt: 100)
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir))
        var changes = 0
        hub.onChange = { changes += 1 }
        hub.refresh()
        #expect(hub.namesNotSaved != nil)
        #expect(hub.names == ["keyscribe": "a"])
        let reported = changes
        hub.refresh()
        #expect(changes == reported)
        try FileManager.default.removeItem(at: dir)
        hub.refresh()
        #expect(hub.namesNotSaved == nil)
        #expect(changes == reported + 1)
        guard case .names(_, let remembered) = AgentNameStore(directory: dir).load() else { Issue.record("names not saved"); return }
        #expect(remembered["a"] == RememberedName(name: "keyscribe", pid: 10, startedAt: 100, native: nil))
    }

    @Test func theSaveWarningClearsWhenNothingIsLeftUnsaved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: dir.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("c", pid: 30, startedAt: 300)
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir),
                           stillRunning: { _ in false })
        var changes = 0
        hub.onChange = { changes += 1 }
        hub.refresh()
        #expect(hub.namesNotSaved != nil)
        let reported = changes
        registry.entries.removeAll()
        hub.refresh()
        #expect(hub.namesNotSaved == nil)
        #expect(changes > reported)
    }

    @Test func aNameFileWithoutRememberedNamesStillLoads() throws {
        let dir = try nameDir(#"{"schema_version": 1, "names": {"a": "backend"}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AgentNameStore(directory: dir).load() == .names(["a": "backend"]))
    }

    @Test func aRenameThatCannotBeSavedIsNotApplied() {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: blocker))
        hub.refresh()
        #expect(throws: (any Error).self) { try hub.rename("a", to: "backend") }
        #expect(hub.names == ["api": "a"])
    }

    private func nameDir(_ contents: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let contents { try Data(contents.utf8).write(to: dir.appendingPathComponent(AgentNameStore.fileName)) }
        return dir
    }

    @Test func noNameFileYetMeansNoChosenNames() throws {
        let dir = try nameDir(nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AgentNameStore(directory: dir).load() == .names([:]))
    }

    @Test func aMalformedOrNewerNameFileIsReportedNotTreatedAsEmpty() throws {
        let broken = try nameDir("not json")
        let newer = try nameDir(#"{"schema_version": 99, "names": {}}"#)
        defer { [broken, newer].forEach { try? FileManager.default.removeItem(at: $0) } }
        guard case .unavailable = AgentNameStore(directory: broken).load() else { Issue.record("malformed file loaded"); return }
        guard case .unavailable = AgentNameStore(directory: newer).load() else { Issue.record("newer file loaded"); return }
    }

    @Test func whileNamesCannotBeLoadedNoNameAddressesAnythingAndTheFileIsKept() throws {
        let dir = try nameDir("not json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir))
        hub.refresh()
        #expect(hub.namesProblem != nil)
        #expect(hub.names.isEmpty)
        #expect(hub.rows == ["a"])
        #expect(throws: (any Error).self) { try hub.rename("a", to: "backend") }
        #expect(try String(contentsOf: dir.appendingPathComponent(AgentNameStore.fileName), encoding: .utf8) == "not json")
    }

    @Test func fixingTheNameFileAndTryingAgainBringsNamesBack() throws {
        let dir = try nameDir("not json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir))
        hub.refresh()
        var changes = 0
        hub.onChange = { changes += 1 }
        try Data(#"{"schema_version": 1, "names": {"a": "backend"}}"#.utf8).write(to: dir.appendingPathComponent(AgentNameStore.fileName))
        hub.reloadNames()
        #expect(hub.namesProblem == nil)
        #expect(hub.names == ["backend": "a"])
        #expect(changes > 0)
    }

    @Test func renamingAConversationThatEndedDoesNothing() throws {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry, "s1")
        try hub.rename("gone", to: "backend")
        #expect(hub.names == ["keyscribe": "s1"])
    }

    private func hello(_ session: String) -> AgentEvent {
        .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i2", session: session, pid: 0))
    }

    @Test func aTimedOutHandoffStillBlocksTheNextMessageAndReportsItsLateResult() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        connected(hub, transport, registry)

        #expect(await hub.deliver("one", to: "s1", delivery: .submit) == .uncertain("keyscribe"))
        #expect(await hub.deliver("two", to: "s1", delivery: .submit) == .queued("keyscribe"))
        #expect(transport.sent.count == 1)

        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
        hub.handle(.turnStarted(session: "s1", turn: "t1"))
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.count == 2)
    }

    @Test func aLateRefusalAfterATimeoutKeepsTheTextAndReleasesTheQueue() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        connected(hub, transport, registry)
        _ = await hub.deliver("one", to: "s1", delivery: .submit)
        _ = await hub.deliver("two", to: "s1", delivery: .submit)

        hub.handle(.refused(request: "r1", reason: "sessionChanged"))
        #expect(notices.items == [.notSent("keyscribe", reason: .conversationChanged)])
        #expect(hub.unsent.map(\.text) == ["one"])
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func aReconnectDoesNotGiveUpOnATimedOutMessageThatCanStillArrive() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        connected(hub, transport, registry)
        _ = await hub.deliver("one", to: "s1", delivery: .submit)
        _ = await hub.deliver("two", to: "s1", delivery: .submit)

        hub.handle(hello("s1"))
        #expect(transport.sent.map(\.0.id) == ["r1"])

        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
        hub.handle(.turnStarted(session: "s1", turn: "t1"))
        hub.handle(.turnComplete(session: "s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func aRefusalAfterTimeoutAndReconnectIsStillReportedAndKept() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        connected(hub, transport, registry)
        _ = await hub.deliver("one", to: "s1", delivery: .submit)
        _ = await hub.deliver("two", to: "s1", delivery: .submit)

        hub.handle(hello("s1"))
        hub.handle(.refused(request: "r1", reason: "sessionChanged"))
        #expect(notices.items == [.notSent("keyscribe", reason: .conversationChanged)])
        #expect(hub.unsent.map(\.text) == ["one"])
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func aLostCompletionDoesNotLockTheConversationOnceTheRegistryShowsItIdle() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(clock: clock)
        connected(hub, transport, registry)
        hub.handle(.turnStarted(session: "s1", turn: "t1"))
        #expect(await hub.deliver("one", to: "s1", delivery: .submit) == .queued("keyscribe"))

        hub.refresh()
        #expect(transport.sent.isEmpty)

        clock.now += AgentHub.runningGrace + 1
        hub.refresh()
        #expect(transport.sent.count == 1)
    }

    @Test func aFreshIdleHelloClearsARunningTurnTheRegistryNoLongerShows() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        hub.handle(.turnStarted(session: "s1", turn: "t1"))
        _ = await hub.deliver("one", to: "s1", delivery: .submit)

        greet(hub, ready(idle: true, gap: false))
        #expect(transport.sent.count == 1)
    }

    @Test func aReconnectAfterAGapNeverReleasesWhatWasHeld() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry)
        hub.handle(.turnStarted(session: "s1", turn: "t1"))
        _ = await hub.deliver("one", to: "s1", delivery: .submit)

        greet(hub, ready(idle: true, gap: true))
        #expect(transport.sent.isEmpty)
        #expect(notices.items == [.kept("keyscribe", reason: .connectionGap)])
    }

    @Test func backgroundResultsAreKeptForLaterInspection() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry, status: "busy")
        _ = await hub.deliver("one", to: "s1", delivery: .submit)
        registry.set("s1", status: "idle")
        hub.refresh()
        hub.handle(.refused(request: "r1", reason: "nope"))
        #expect(hub.recent == [.notSent("keyscribe", reason: .refused("nope"))])
    }

    final class FakeFocus: AgentTerminalFocusing, @unchecked Sendable {
        var focused: [(String, Int)] = []
        var environments: [[String: String]] = []
        var result = AgentFocusResult.exact
        private(set) var wanted: [Bool] = []
        func focus(
            session: String, pid: Int, environment: [String: String], stillWanted: @escaping @MainActor @Sendable () -> Bool,
            asking: @escaping @MainActor @Sendable (String) -> Void
        ) async -> AgentFocusResult {
            focused.append((session, pid))
            wanted.append(await stillWanted())
            environments.append(environment)
            return result
        }
    }

    @Test func openingUsesTheTerminalEnvironmentTheConversationsConnectorReported() async {
        let focus = FakeFocus()
        let registry = Registry()
        registry.set("s1")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus)
        hub.refresh()
        #expect(await hub.open("s1") == .exact)
        hub.handle(.hello(.init(
            protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s1", pid: 0, environment: ["ZELLIJ_PANE_ID": "3"])))
        #expect(await hub.open("s1") == .exact)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s1", pid: 0)))
        #expect(await hub.open("s1") == .exact)
        #expect(focus.environments == [[:], ["ZELLIJ_PANE_ID": "3"], [:]])
    }

    final class FakeFront: AgentFronting, @unchecked Sendable {
        var answer: FrontSession?
        private(set) var asked: [[AgentFrontCandidate]] = []
        func shown(among agents: [AgentFrontCandidate], asking: @escaping @MainActor @Sendable (String) -> Void) async -> FrontSession? {
            asked.append(agents)
            return answer
        }
    }

    @Test func theSessionInFrontIsAskedOfTheTerminalWithEveryConversationAndItsEnvironment() async {
        let front = FakeFront()
        let registry = Registry()
        registry.set("s1", pid: 10)
        registry.set("s2", pid: 11)
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, front: front)
        hub.refresh()
        hub.handle(.hello(.init(
            protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s2", pid: 0, environment: ["ZELLIJ_PANE_ID": "3"])))
        let shown = FrontSession(id: "s2", app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty"))
        front.answer = shown
        #expect(await hub.sessionInFront() == shown)
        #expect(front.asked == [[AgentFrontCandidate(id: "s1", pid: 10), AgentFrontCandidate(id: "s2", pid: 11, environment: ["ZELLIJ_PANE_ID": "3"])]])
        let blind = AgentHub(transport: FakeTransport(), scan: { registry.entries })
        blind.refresh()
        #expect(await blind.sessionInFront() == nil)
    }

    @Test func openingWithoutMakingCurrentLeavesTheRecipientAlone() async {
        let focus = FakeFocus()
        let registry = Registry()
        registry.set("s1")
        registry.set("s2", pid: 11)
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus)
        hub.refresh()
        hub.makeCurrent("s1")
        #expect(await hub.open("s2", makingCurrent: false) == .exact)
        #expect(hub.current == "s1")
        #expect(focus.focused.map(\.0) == ["s2"])
    }

    @Test func openingHandsTheStopCheckToTheTerminalFocus() async {
        let focus = FakeFocus()
        let registry = Registry()
        registry.set("s1")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus)
        hub.refresh()
        #expect(await hub.open("s1", stillWanted: { false }) == .exact)
        #expect(focus.wanted == [false])
    }

    @Test func openingMakesTheConversationCurrentAndBringsItsTerminalForward() async {
        let focus = FakeFocus()
        let registry = Registry()
        registry.set("s1")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus)
        hub.refresh()
        #expect(await hub.open("s1") == .exact)
        #expect(hub.current == "s1")
        #expect(focus.focused.map(\.0) == ["s1"])
        #expect(focus.focused.map(\.1) == [10])
    }

    private func focusHello(_ session: String = "s1") -> AgentEvent {
        .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: session, pid: 0, features: ["focus"]))
    }

    @Test func aConnectorThatAnnouncedFocusIsAskedToFocusItsSessionBeforeTheRequestExpires() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(clock: clock)
        connected(hub, transport, registry)
        hub.handle(focusHello())
        let sentBefore = transport.sent.count
        async let answer = hub.focusInPlace("s1")
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.map(\.0) == [.focus(id: "r1", expectedSession: "s1", expiresAt: clock.now.addingTimeInterval(3))])
        hub.handle(.focused(request: "r1"))
        #expect(await answer == .selected)
        #expect(hub.recent.isEmpty)
    }

    @Test func aLiveConnectorThatCannotFocusIsNeverAskedAndSaysItNeedsAnUpdate() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        hub.handle(hello("s1"))
        #expect(await hub.focusInPlace("s1") == .outdated)
        #expect(transport.sent.isEmpty)
    }

    @Test func aConversationWhoseConnectorNeverConnectedIsNotAsked() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        transport.live = []
        #expect(await hub.focusInPlace("s1") == .notFound)
        #expect(transport.sent.isEmpty)
    }

    @Test func aRefusedFocusIsNotFoundAndNeverReadsAsADeliveryReceipt() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry)
        hub.handle(focusHello())
        let sentBefore = transport.sent.count
        async let refused = hub.focusInPlace("s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "notInCmux"))
        #expect(await refused == .notFound)
        #expect(notices.items.isEmpty && hub.recent.isEmpty && hub.unsent.isEmpty)
    }

    @Test func anUnansweredFocusIsWithdrawnAndALateAnswerChangesNothing() async {
        let (hub, transport, registry, notices) = makeHub()
        connected(hub, transport, registry)
        hub.handle(focusHello())
        #expect(await hub.focusInPlace("s1", within: .milliseconds(20)) == .notFound)
        #expect(transport.withdrawn == ["r1"])
        hub.handle(.focused(request: "r1"))
        #expect(notices.items.isEmpty && hub.recent.isEmpty)
    }

    @Test func aCancelledFocusIsWithdrawnAtOnce() async {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        hub.handle(focusHello())
        let task = Task { await hub.focusInPlace("s1", within: .seconds(30)) }
        while transport.sent.isEmpty { await Task.yield() }
        task.cancel()
        #expect(await task.value == .notFound)
        #expect(transport.withdrawn == ["r1"])
    }

    private func labelHello(_ session: String = "s1", title: String? = nil) -> AgentEvent {
        .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: session, pid: 0, features: ["label"], title: title))
    }

    @Test func explicitConnectorNamesAreAddressesAndOverridesStillWin() throws {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        hub.handle(labelHello(title: "Fix authentication retries"))
        #expect(hub.names == ["fix authentication retries": "s1"])
        let frozenNames = hub.names
        let frozenConversations = hub.directory.conversations
        hub.handle(.title(session: "s1", text: "Cache invalidation"))
        #expect(hub.names == ["cache invalidation": "s1"])
        #expect(AgentAddress.parse("fix authentication retries, run the tests", names: Array(frozenNames.keys)) == .name("fix authentication retries", body: "run the tests"))
        let roster = AgentRoster(frozen: frozenConversations, live: hub.directory.conversations, recipient: .init(id: "s1", source: .current))
        #expect(roster.rows.first?.name == "fix authentication retries")
        try hub.rename("s1", to: "backend")
        hub.handle(.title(session: "s1", text: "Another native name"))
        #expect(hub.names == ["backend": "s1"])
    }

    @Test func anExplicitAbsenceFromTheConnectorOverridesStaleRegistryNames() {
        let (hub, transport, registry, _) = makeHub()
        registry.entries = [.init(pid: 10, sessionId: "s1", cwd: "/src/api", name: "Old native name", status: "idle", waitingFor: nil, nameSource: "user")]
        transport.live.insert("s1")
        hub.refresh()
        #expect(hub.names == ["old native name": "s1"])
        hub.handle(labelHello())
        #expect(hub.names == ["old native name": "s1"])
        hub.handle(.title(session: "s1", text: ""))
        #expect(hub.names == ["api": "s1"])
    }

    @Test func aFreshRegistryRenameSupersedesTheLastHookReport() {
        let (hub, transport, registry, _) = makeHub()
        registry.entries = [.init(pid: 10, sessionId: "s1", cwd: "/src/api", name: "Stale", status: "idle", waitingFor: nil, nameSource: "user")]
        transport.live.insert("s1")
        hub.refresh()
        hub.handle(labelHello(title: "Actual"))
        #expect(hub.names == ["actual": "s1"])
        registry.entries[0].name = "Renamed in Claude"
        hub.refresh()
        #expect(hub.names == ["renamed in claude": "s1"])
        registry.entries[0].name = "Stale"
        hub.refresh()
        #expect(hub.names == ["stale": "s1"])
    }

    private func labels(_ transport: FakeTransport) -> [String] {
        transport.sent.compactMap { if case .status(_, _, let text) = $0.0 { text } else { nil } }
    }

    @Test func aConnectorThatShowsLabelsIsToldTheNameToShowOnceAndAgainAfterARename() throws {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        hub.handle(labelHello())
        hub.refresh()
        #expect(labels(transport) == ["\u{201C}keyscribe\u{201D}"])
        try hub.rename("s1", to: "backend")
        #expect(labels(transport) == ["\u{201C}keyscribe\u{201D}", "\u{201C}backend\u{201D}"])
        hub.handle(labelHello())
        #expect(labels(transport).count == 3)
    }

    @Test func choosingTheCurrentRecipientLeavesEveryLabelAsItWas() {
        let (hub, transport, registry, _) = makeHub()
        registry.set("s1")
        registry.set("s2", cwd: "/src/backend")
        transport.live.formUnion(["s1", "s2"])
        hub.handle(labelHello("s1"))
        hub.handle(labelHello("s2"))
        #expect(Set(labels(transport)) == ["\u{201C}keyscribe\u{201D}", "\u{201C}backend\u{201D}"])
        hub.makeCurrent("s1")
        hub.makeCurrent("s2")
        #expect(labels(transport).count == 2)
    }

    @Test func aConnectorThatCannotShowLabelsIsNeverSentOne() {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        hub.handle(hello("s1"))
        #expect(labels(transport).isEmpty)
    }

    @Test func theTitleAConnectorReportsReachesItsConversation() {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        hub.handle(labelHello(title: "Fix terminal focus"))
        #expect(hub.directory.conversations.first?.title == "Fix terminal focus")
        hub.handle(.title(session: "s1", text: "Fix focus after reconnect"))
        #expect(hub.directory.conversations.first?.title == "Fix focus after reconnect")
        hub.handle(.title(session: "s1", text: ""))
        #expect(hub.directory.conversations.first?.title == nil)
    }

    @Test func aTranscriptTitleShowsUntilTheConnectorReportsOneTheUserGave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-titles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("projects/-src-keyscribe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"ai-title","aiTitle":"Generated","sessionId":"s1"}"#.utf8).write(to: folder.appendingPathComponent("s1.jsonl"))
        let registry = Registry()
        let transport = FakeTransport()
        let hub = AgentHub(transport: transport, scan: { registry.entries }, transcriptTitles: ClaudeTranscriptTitles(configDirs: [dir]))
        registry.set("s1")
        transport.live.insert("s1")
        hub.refresh()
        #expect(hub.directory.conversations.first?.title == "Generated")
        #expect(hub.names == ["keyscribe": "s1"])
        hub.handle(labelHello(title: "Chosen by me"))
        #expect(hub.directory.conversations.first?.title == "Chosen by me")
        #expect(hub.names == ["chosen by me": "s1"])
    }

    @Test func theRoutineRefreshLeavesTranscriptsAloneUntilSomethingAsksForFreshTitles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-routine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("projects/-src-keyscribe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        try Data(#"{"type":"ai-title","aiTitle":"First","sessionId":"s1"}"#.utf8).write(to: file)
        let start = Date()
        let clock = ClaudeTranscriptTitlesTests.Clock()
        clock.now = start
        let registry = Registry()
        let hub = AgentHub(
            transport: FakeTransport(), scan: { registry.entries },
            transcriptTitles: ClaudeTranscriptTitles(configDirs: [dir], now: { clock.now }))
        registry.set("s1")
        hub.refresh(rereadingTitles: false)
        #expect(hub.directory.conversations.first?.title == "First")

        clock.now += ClaudeTranscriptTitles.rereadInterval
        try Data(#"{"type":"ai-title","aiTitle":"Second","sessionId":"s1"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: clock.now], ofItemAtPath: file.path)
        hub.refresh(rereadingTitles: false)
        #expect(hub.directory.conversations.first?.title == "First")
        hub.refresh()
        #expect(hub.directory.conversations.first?.title == "Second")
    }

    @Test func anExplicitTranscriptNameIsAddressableBeforeTheConnectorStarts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-native-name-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("projects/-src-keyscribe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"custom-title","customTitle":"Fix authentication retries","sessionId":"s1"}"#.utf8).write(to: folder.appendingPathComponent("s1.jsonl"))
        let registry = Registry()
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, transcriptTitles: ClaudeTranscriptTitles(configDirs: [dir]))
        registry.set("s1")
        hub.refresh()
        #expect(hub.names == ["fix authentication retries": "s1"])
        hub.handle(labelHello())
        #expect(hub.names == ["fix authentication retries": "s1"])
        hub.handle(.title(session: "s1", text: ""))
        #expect(hub.names == ["keyscribe": "s1"])
    }

    @Test func aConversationThatReconnectsWithoutATitleLosesItsOldOne() {
        let (hub, transport, registry, _) = makeHub()
        connected(hub, transport, registry)
        hub.handle(labelHello(title: "Named"))
        hub.handle(labelHello())
        #expect(hub.directory.conversations.first?.title == nil)
    }

    @Test func openingAConversationThatIsGoneDoesNothing() async {
        let focus = FakeFocus()
        let hub = AgentHub(transport: FakeTransport(), scan: { [] }, focus: focus)
        #expect(await hub.open("s1") == .none)
        #expect(hub.current == nil)
        #expect(focus.focused.isEmpty)
    }

    @Test func aTerminalThatCannotComeForwardStillLeavesTheConversationCurrent() async {
        let focus = FakeFocus()
        focus.result = .none
        let registry = Registry()
        registry.set("s1")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus)
        hub.refresh()
        #expect(await hub.open("s1") == .none)
        #expect(hub.current == "s1")
    }
}
