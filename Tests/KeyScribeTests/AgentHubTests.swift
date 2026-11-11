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
        var forgotten: [String] = []
        func forget(session: String) { forgotten.append(session) }
    }

    final class Registry: @unchecked Sendable {
        var entries: [ClaudeRegistryEntry] = []
        func set(
            _ session: String, status: String = "idle", waitingFor: String? = nil, cwd: String = "/src/keyscribe", pid: Int = 10,
            startedAt: Int? = nil
        ) {
            entries.removeAll { $0.sessionId == session }
            entries.append(ClaudeRegistryEntry(
                pid: pid, sessionId: session, cwd: cwd, name: nil, status: status, waitingFor: waitingFor, startedAt: startedAt))
        }
    }

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1000) }
    private static let deadline = Date(timeIntervalSince1970: 1005)

    private func makeHub(
        receiptTimeout: Duration = .seconds(5), handOffLimit: Duration = .seconds(30), disconnectGrace: Duration = .seconds(30),
        clock: Clock = Clock()
    ) -> (AgentHub, FakeTransport, Registry, Notices) {
        let transport = FakeTransport()
        let registry = Registry()
        let notices = Notices()
        var counter = 0
        let hub = AgentHub(
            transport: transport, scan: { registry.entries }, receiptTimeout: receiptTimeout, handOffLimit: handOffLimit,
            disconnectGrace: disconnectGrace, scanDeadline: .seconds(30), now: { clock.now }
        ) {
            counter += 1
            return "r\(counter)"
        }
        hub.onNotice = { receipt, request, _ in
            notices.items.append(receipt)
            notices.requests.append(request)
        }
        return (hub, transport, registry, notices)
    }

    final class Notices {
        var items: [AgentReceipt] = []
        var requests: [String] = []
    }

    private func connected(_ hub: AgentHub, _ transport: FakeTransport, _ registry: Registry, _ session: String = "s1", status: String = "idle") async {
        registry.set(session, status: status)
        transport.live.insert(AgentSessionID.make(agent: "claude", native: session))
        await hub.rescan()
    }

    @Test func theHubKnowsWhetherAnyListedConversationIsConnected() async {
        let (hub, transport, registry, _) = makeHub()
        registry.set("s1")
        await hub.rescan()
        #expect(!hub.hasConnectedConversation)
        transport.live.insert("claude:s1")
        await hub.rescan()
        #expect(hub.hasConnectedConversation)
    }

    @Test func theHubSaysWhenTheFirstConversationConnects() async {
        let (hub, transport, registry, _) = makeHub()
        var connects = 0
        hub.onFirstConnection = { connects += 1 }
        registry.set("s1")
        registry.set("s2")
        await hub.rescan()
        #expect(connects == 0)
        transport.live.insert("claude:s1")
        hub.refresh()
        #expect(connects == 1)
        transport.live.insert("claude:s2")
        hub.refresh()
        #expect(connects == 1)
        transport.live = []
        hub.refresh()
        transport.live.insert("claude:s2")
        hub.refresh()
        #expect(connects == 2)
    }

    @Test func theRescanIsQuickOnlyWhileAConversationIsConnectedOrSettingsIsOpen() {
        #expect(AgentRuntime.rescanInterval(connected: true, settingsOpen: false) == .seconds(1))
        #expect(AgentRuntime.rescanInterval(connected: false, settingsOpen: true) == .seconds(1))
        #expect(AgentRuntime.rescanInterval(connected: false, settingsOpen: false) == .seconds(10))
    }

    @Test func anIdleConversationIsSentAndConfirmedByTheConnector() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.map(\.0) == [.submit(id: "r1", expectedSession: "claude:s1", text: "run the tests", expiresAt: Self.deadline)])
        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(await receipt == .sent("keyscribe"))
    }

    @Test func aSubmitIsFencedOnThePromptCountTheHubLastHeard() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, prompts: 2)))
        hub.handle(.typed(session: "claude:s1", prompts: 3))

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.map(\.0) == [.submit(id: "r1", expectedSession: "claude:s1", text: "run the tests", expectedPrompts: 3, expiresAt: Self.deadline)])
        hub.handle(.submitted(request: "r1", turn: ""))
        _ = await receipt
    }

    @Test(arguments: [(["images"], ["/tmp/a.png"]), ([String](), [String]())])
    func imagesGoOnlyToAConnectorThatSaidItTakesThem(_ features: [String], _ expected: [String]) async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: features)))

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("see /tmp/a.png", to: "claude:s1", images: ["/tmp/a.png"])
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.last.map(\.0) == .submit(id: "r1", expectedSession: "claude:s1", text: "see /tmp/a.png", expiresAt: Self.deadline, images: expected))
        hub.handle(.submitted(request: "r1", turn: ""))
        _ = await receipt
    }

    @Test func aSubmitRefusedBecauseTheUserTypedIsKeptForReview() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "typedSince"))
        #expect(await receipt == .kept("keyscribe", reason: .typedSince))
    }

    @Test func aSubmitRefusedOverAMessageTheUserIsWritingIsKeptForReview() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "draft"))
        #expect(await receipt == .kept("keyscribe", reason: .composing))
    }

    @Test func aSubmitLeftInThePromptBoxAfterAStopIsKeptForTheUserToSend() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: ["fill"])))

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "filled"))
        #expect(await receipt == .kept("keyscribe", reason: .inPromptBox))
    }

    @Test func onlyAConnectorThatSaidItFillsThePromptBoxCanLeaveAMessageThere() {
        #expect(AgentHub.filled(handle: "docs", features: ["focus", "fill"]) == .kept("docs", reason: .inPromptBox))
        #expect(AgentHub.filled(handle: "docs", features: ["focus"]) == .notSent("docs", reason: .stopped))
        #expect(AgentHub.filled(handle: "docs", features: nil) == .notSent("docs", reason: .stopped))
    }

    @Test func everySubmissionTheUserMakesIsCounted() {
        let (hub, _, _, _) = makeHub()
        #expect(hub.typedCount("claude:s1") == 0)
        hub.handle(.typed(session: "claude:s1", prompts: 4))
        hub.handle(.typed(session: "claude:s1"))
        #expect(hub.typedCount("claude:s1") == 2)
        #expect(hub.typedCount("claude:s2") == 0)
    }

    private func ready(idle: Bool = true, gap: Bool) -> AgentEvent.Hello {
        .init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: ["readiness"], idle: idle, gap: gap)
    }

    private func greet(_ hub: AgentHub, _ hello: AgentEvent.Hello) {
        hub.prepare(for: hello)
        hub.handle(.hello(hello))
    }

    @Test func aTakeHeldAcrossAConnectionGapIsKeptForReviewNotSent() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        #expect(await hub.deliver("run the tests", to: "claude:s1") == .queued("keyscribe"))

        registry.set("s1", status: "idle")
        greet(hub, ready(gap: true))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.isEmpty)
        #expect(notices.items == [.kept("keyscribe", reason: .connectionGap)])
    }

    @Test func aReconnectDuringATurnKeepsTheOlderTakeForReviewAndSendsTheNewerOneWhenTheTurnEnds() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, ready(idle: false, gap: false))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        #expect(await hub.deliver("before the drop", to: "claude:s1") == .queued("keyscribe"))

        greet(hub, ready(idle: false, gap: true))
        #expect(notices.items == [.kept("keyscribe", reason: .connectionGap)])
        #expect(await hub.deliver("after the drop", to: "claude:s1") == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)

        registry.set("s1", status: "idle")
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        await hub.rescan()
        #expect(transport.sent.map(\.0) == [.submit(id: "r2", expectedSession: "claude:s1", text: "after the drop", expiresAt: Self.deadline)])
        hub.handle(.submitted(request: "r2", turn: ""))
        #expect(notices.items == [.kept("keyscribe", reason: .connectionGap), .sent("keyscribe")])
    }

    @Test func aTakeTheBridgeWithdrewAtAGapIsKeptForReview() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "connectionGap", handedOff: false))
        #expect(await receipt == .kept("keyscribe", reason: .connectionGap))
    }

    @Test func aTakeThatMayHaveBeenIssuedBeforeTheGapStaysUncertain() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "connectionGap", handedOff: true))
        #expect(await receipt == .uncertain("keyscribe"))
    }

    @Test func aConnectorThatReportsARunningTurnIsBusy() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        greet(hub, ready(idle: false, gap: false))
        #expect(await hub.deliver("run the tests", to: "claude:s1") == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)
    }

    @Test func aConnectorThatReportsNoTurnAndNoGapIsReady() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        greet(hub, ready(gap: false))
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.map(\.0.id) == ["r1"])
        hub.handle(.submitted(request: "r1", turn: ""))
        _ = await receipt
    }

    @Test func aConnectorThatCannotReportItsTurnIsNotAssumedIdle() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        let old = AgentEvent.Hello(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: ["focus"])
        greet(hub, old)
        #expect(await hub.deliver("run the tests", to: "claude:s1") == .queued("keyscribe"))
    }

    @Test func aSubmitRefusedBecauseATurnIsRunningWaitsForItToFinish() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(await receipt == .queued("keyscribe"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0.id) == ["r1", "r1"])
        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
    }

    @Test func aBusyConversationQueuesAndSendsWhenTheTurnCompletes() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry, status: "busy")

        #expect(await hub.deliver("run the tests", to: "claude:s1") == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)

        registry.set("s1", status: "idle")
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        await hub.rescan()
        #expect(transport.sent.map(\.0) == [.submit(id: "r1", expectedSession: "claude:s1", text: "run the tests", expiresAt: Self.deadline)])
        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
    }

    @Test func aLateReceiptCarriesTheRequestIdTheCallerGave() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry, status: "busy")

        #expect(await hub.deliver("run the tests", to: "claude:s1", request: "entry-1") == .queued("keyscribe"))
        registry.set("s1", status: "idle")
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        await hub.rescan()
        #expect(transport.sent.map(\.0) == [.submit(id: "entry-1", expectedSession: "claude:s1", text: "run the tests", expiresAt: Self.deadline)])
        hub.handle(.submitted(request: "entry-1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
        #expect(notices.requests == ["entry-1"])
    }

    @Test func aSecondMessageWaitsForTheFirstOnesTurn() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let first = hub.deliver("one", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: ""))
        _ = await first
        #expect(await hub.deliver("two", to: "claude:s1") == .queued("keyscribe"))

        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        await hub.rescan()
        #expect(transport.sent.count == 1)
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.count == 2)
    }

    @Test func aConversationWithoutItsConnectorIsNotSentAndKept() async {
        let (hub, _, registry, _) = makeHub()
        registry.set("s1")
        await hub.rescan()

        let receipt = await hub.deliver("run the tests", to: "claude:s1")
        #expect(receipt == .notSent("keyscribe", reason: .connectorNotRunning))
    }

    @Test func anEndedConversationIsNotSent() async {
        let (hub, _, _, _) = makeHub()
        #expect(await hub.deliver("run the tests", to: "claude:gone") == .notSent(nil, reason: .conversationEnded))
    }

    @Test func aRefusalIsReportedAndTheMessageKept() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "sessionChanged"))
        #expect(await receipt == .notSent("keyscribe", reason: .conversationChanged))
    }

    @Test func aHandoffThatMayHaveLandedIsUncertainNotRetried() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "instanceGone", handedOff: true))
        #expect(await receipt == .uncertain("keyscribe"))
    }

    @Test func aHandoffThatMayHaveLandedStillBlocksTheNextMessageAndReportsItsLateResult() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let first = hub.deliver("one", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "instanceGone", handedOff: true))
        #expect(await first == .uncertain("keyscribe"))
        #expect(await hub.deliver("two", to: "claude:s1") == .queued("keyscribe"))
        #expect(transport.sent.count == 1)

        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func aPossibleHandoffFollowedByTheTimeoutIsReportedOnce() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let first = hub.deliver("one", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "instanceGone", handedOff: true))
        #expect(await first == .uncertain("keyscribe"))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(notices.items.isEmpty)
    }

    @Test func aLateRefusalAfterAPossibleHandoffKeepsTheTextAndReleasesTheQueue() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)

        let sentBefore = transport.sent.count
        async let first = hub.deliver("one", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.undelivered(request: "r1", reason: "instanceGone", handedOff: true))
        _ = await first
        _ = await hub.deliver("two", to: "claude:s1")

        hub.handle(.refused(request: "r1", reason: "sessionChanged"))
        #expect(notices.items == [.notSent("keyscribe", reason: .conversationChanged)])
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func noAnswerFromTheConnectorIsUncertain() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        #expect(await hub.deliver("run the tests", to: "claude:s1") == .uncertain("keyscribe"))
    }

    @Test func aHandOffNoOneAnswersHoldsTheQueueOnlyUntilItsLimitAndIsForgottenAfterIt() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20), handOffLimit: .milliseconds(60))
        await connected(hub, transport, registry)
        #expect(await hub.deliver("one", to: "claude:s1") == .uncertain("keyscribe"))
        #expect(await hub.deliver("two", to: "claude:s1") == .queued("keyscribe"))
        #expect(transport.sent.map(\.0.id) == ["r1"])
        for _ in 0..<300 where transport.sent.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
        hub.handle(.submitted(request: "r1", turn: "1"))
        hub.handle(.submitted(request: "r2", turn: "2"))
        let outcomes = Array(zip(notices.requests, notices.items))
        #expect(outcomes.filter { $0.0 == "r1" }.isEmpty)
        #expect(outcomes.last { $0.0 == "r2" }?.1 == .sent("keyscribe"))
    }

    @Test func aHandOffTheHubStopsTrackingIsForgottenByItsListenerOnce() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), handOffLimit: .milliseconds(60))
        await connected(hub, transport, registry)
        var forgotten: [String] = []
        hub.onForget = { forgotten.append($0) }
        #expect(await hub.deliver("one", to: "claude:s1") == .uncertain("keyscribe"))
        #expect(forgotten.isEmpty)
        for _ in 0..<300 where forgotten.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        hub.handle(.submitted(request: "r1", turn: "1"))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(forgotten == ["r1"])
    }

    @Test func aSubmitExpiresWhenTheHubStopsWaitingForItsReceipt() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .seconds(8), clock: clock)
        await connected(hub, transport, registry)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        #expect(transport.sent.first?.0.expiresAt == clock.now.addingTimeInterval(8))
        hub.handle(.refused(request: "r1", reason: "expired"))
        #expect(await receipt == .notSent("keyscribe", reason: .expired))
    }

    @Test func aSubmitTheBridgeDroppedAsExpiredIsReportedAsNotTakenInTime() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.undelivered(request: "r1", reason: "expired", handedOff: false))
        #expect(await receipt == .notSent("keyscribe", reason: .expired))
    }

    @Test func anExpiredSubmitTheConnectorHadCollectedStaysUncertain() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.undelivered(request: "r1", reason: "expired", handedOff: true))
        #expect(await receipt == .uncertain("keyscribe"))
    }

    @Test func aReceiptWithinTheHandOffLimitStillSettlesAnUncertainTake() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20), handOffLimit: .seconds(5))
        await connected(hub, transport, registry)
        #expect(await hub.deliver("one", to: "claude:s1") == .uncertain("keyscribe"))
        hub.handle(.submitted(request: "r1", turn: "1"))
        #expect(notices.items == [.sent("keyscribe")])
        #expect(notices.requests == ["r1"])
    }

    @Test func aWorkingRefusalForATimedOutTakeKeepsItsTextAndReleasesTheQueueInsteadOfRequeueingIt() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20), handOffLimit: .seconds(5))
        await connected(hub, transport, registry)
        #expect(await hub.deliver("one", to: "claude:s1") == .uncertain("keyscribe"))
        #expect(await hub.deliver("two", to: "claude:s1") == .queued("keyscribe"))
        #expect(transport.sent.map(\.0.id) == ["r1"])
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(notices.items == [.notSent("keyscribe", reason: .refused("working"))])
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
        hub.handle(.submitted(request: "r2", turn: "2"))
        #expect(notices.items.last == .sent("keyscribe"))
    }

    private func dictated(_ hub: AgentHub, _ transport: FakeTransport, turn: String = "t1") async {
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        if case .submit(let id, _, _, _, _, _) = transport.sent.last?.0 { hub.handle(.submitted(request: id, turn: turn)) }
        _ = await receipt
        hub.handle(.turnStarted(session: "claude:s1", turn: turn))
    }

    @Test func aDictatedTurnReportsEachApprovalAndQuestionOnceAndWhenItClears() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var seen: [String] = []
        hub.onAttention = { conversation, handle, value, _ in seen.append("\(conversation)|\(handle)|\(value.map { "\($0)" } ?? "cleared")") }
        await dictated(hub, transport)
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        await hub.rescan()
        await hub.rescan()
        registry.set("s1", status: "busy")
        await hub.rescan()
        registry.set("s1", status: "waiting", waitingFor: "input needed")
        await hub.rescan()
        registry.set("s1", status: "waiting", waitingFor: "dialog open")
        await hub.rescan()
        #expect(seen == [
            "claude:s1|keyscribe|approval", "claude:s1|keyscribe|cleared", "claude:s1|keyscribe|question", "claude:s1|keyscribe|cleared",
        ])
    }

    @Test func aTypedTurnWaitingForApprovalReportsNothing() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var seen: [AgentAttention?] = []
        hub.onAttention = { _, _, value, _ in seen.append(value) }
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        await hub.rescan()
        #expect(seen.isEmpty)
    }

    @Test func aFinishedTurnClearsItsNoticeAndAQuestionAfterItIsNotTheirs() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var seen: [AgentAttention?] = []
        hub.onAttention = { _, _, value, _ in seen.append(value) }
        await dictated(hub, transport)
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        await hub.rescan()
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done."))
        registry.set("s1", status: "waiting", waitingFor: "input needed")
        await hub.rescan()
        #expect(seen == [.approval, nil])
    }

    @Test func aConnectorGoneMidTurnPastTheGraceIsReportedOnceAndAReconnectClearsIt() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(disconnectGrace: .seconds(5), clock: clock)
        await connected(hub, transport, registry)
        var seen: [AgentAttention?] = []
        hub.onAttention = { _, _, value, _ in seen.append(value) }
        await dictated(hub, transport)
        transport.live = []
        await hub.rescan()
        clock.now += 4
        await hub.rescan()
        #expect(seen.isEmpty)
        clock.now += 2
        await hub.rescan()
        await hub.rescan()
        #expect(seen == [.disconnected])
        transport.live = [AgentSessionID.make(agent: "claude", native: "s1")]
        hub.handle(hello("claude:s1"))
        #expect(seen == [.disconnected, nil])
    }

    @Test func aConversationThatVanishesMidTurnWithdrawsItsNoticeThenReportsDisconnectedByName() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(disconnectGrace: .seconds(5), clock: clock)
        await connected(hub, transport, registry)
        var seen: [String] = []
        hub.onAttention = { _, handle, value, _ in seen.append("\(handle)|\(value.map { "\($0)" } ?? "cleared")") }
        await dictated(hub, transport)
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        await hub.rescan()
        registry.entries = []
        transport.live = []
        await hub.rescan()
        #expect(seen == ["keyscribe|approval", "keyscribe|cleared"])
        clock.now += 6
        await hub.rescan()
        await hub.rescan()
        #expect(seen == ["keyscribe|approval", "keyscribe|cleared", "keyscribe|disconnected"])
        clock.now += 60
        await hub.rescan()
        #expect(seen.count == 3)
    }

    @Test func aVanishedConversationThatComesBackWithdrawsItsDisconnectedNotice() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(disconnectGrace: .seconds(5), clock: clock)
        await connected(hub, transport, registry)
        var seen: [String] = []
        hub.onAttention = { _, handle, value, _ in seen.append("\(handle)|\(value.map { "\($0)" } ?? "cleared")") }
        await dictated(hub, transport)
        registry.entries = []
        transport.live = []
        await hub.rescan()
        clock.now += 6
        await hub.rescan()
        #expect(seen == ["keyscribe|disconnected"])
        await connected(hub, transport, registry)
        #expect(seen == ["keyscribe|disconnected", "keyscribe|cleared"])
        registry.entries = []
        transport.live = []
        await hub.rescan()
        clock.now += 60
        await hub.rescan()
        await connected(hub, transport, registry)
        #expect(seen.filter { $0.hasSuffix("disconnected") }.count == 1)
        #expect(seen.last == "keyscribe|cleared")
    }

    @Test func aDialogTheConnectorDescribesIsReportedWithWhatItWaitsForAndClearsWhenItCloses() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var seen: [AgentAttention?] = []
        hub.onAttention = { _, _, value, _ in seen.append(value) }
        await dictated(hub, transport)
        let prompt = AgentPrompt(title: "Allow?", tool: "bash")
        registry.set("s1", status: "waiting", waitingFor: "a dialog")
        hub.handle(.waiting(session: "claude:s1", prompt: prompt))
        await hub.rescan()
        #expect(seen == [.waiting(prompt)])
        registry.set("s1", status: "busy")
        hub.handle(.waiting(session: "claude:s1", prompt: nil))
        await hub.rescan()
        #expect(seen == [.waiting(prompt), nil])
    }

    @Test func aPromptDescriptionIsForgottenWhenItsSessionDisappears() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var seen: [AgentAttention?] = []
        hub.onAttention = { _, _, value, _ in seen.append(value) }
        hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(title: "Allow?", detail: "rm -rf build")))
        registry.entries = []
        transport.live = []
        await hub.rescan()
        await connected(hub, transport, registry)
        await dictated(hub, transport)
        registry.set("s1", status: "waiting", waitingFor: "a dialog")
        await hub.rescan()
        #expect(!seen.contains { if case .waiting = $0 { true } else { false } })
    }

    @Test func aDialogWithoutADescriptionStillAnnouncesNothing() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var seen: [AgentAttention?] = []
        hub.onAttention = { _, _, value, _ in seen.append(value) }
        await dictated(hub, transport)
        registry.set("s1", status: "waiting", waitingFor: "a dialog")
        await hub.rescan()
        #expect(seen.isEmpty)
    }

    @Test func aRefusalTheConnectorMarksStoppedIsReportedAsStopped() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        if case .submit(let id, _, _, _, _, _) = transport.sent.last?.0 { hub.handle(.refused(request: id, reason: "stopped")) }
        #expect(await receipt == .notSent("keyscribe", reason: .stopped))
    }

    @Test func aStoppedHubReportsNoResultOrNoticeForLaterEvents() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var reported: [String] = []
        hub.onResult = { _, _, _, _, _ in reported.append("result") }
        hub.onAttention = { _, _, _, _ in reported.append("attention") }
        await dictated(hub, transport)
        hub.stop()
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done."))
        await hub.rescan()
        #expect(reported.isEmpty)
    }

    @Test func aConnectorBackWithinTheGraceReportsNothing() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(disconnectGrace: .seconds(5), clock: clock)
        await connected(hub, transport, registry)
        var seen: [AgentAttention?] = []
        hub.onAttention = { _, _, value, _ in seen.append(value) }
        await dictated(hub, transport)
        transport.live = []
        await hub.rescan()
        transport.live = [AgentSessionID.make(agent: "claude", native: "s1")]
        await hub.rescan()
        clock.now += 60
        transport.live = []
        await hub.rescan()
        #expect(seen.isEmpty)
    }

    @Test func aTurnThatDictationStartedReportsItsAnswerOnceWhenItCompletes() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var results: [String] = []
        hub.onResult = { conversation, handle, value, _, _ in results.append("\(conversation)|\(handle)|\(value)") }
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "a typed turn"))
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        #expect(await receipt == .sent("keyscribe"))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "a later typed turn"))
        #expect(results == ["claude:s1|keyscribe|All green."])
    }

    @Test func aDictatedTurnsResultAndEndingNameTheRequestThatStartedIt() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin in origins.append(origin) }
        hub.onEnded = { _, _, _, _, origin in origins.append(origin) }
        async let first = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        _ = await first
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        async let second = hub.deliver("try again", to: "claude:s1")
        await untilSent(transport, 2)
        hub.handle(.submitted(request: "r2", turn: "t2"))
        _ = await second
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "error", answer: ""))
        #expect(origins == ["r1", "r2"])
    }

    @Test func theTurnAMessageSentFromThePromptBoxStartsIsAwaitedForItsRequest() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var results: [String] = []
        hub.onResult = { _, _, answer, _, origin in results.append("\(answer)|\(origin ?? "-")") }
        hub.awaitTypedTurn(of: "claude:s1", request: "r7")
        hub.handle(.typed(session: "claude:s1"))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t5"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Renamed."))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t6"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "a later typed turn"))
        #expect(results == ["Renamed.|r7"])
    }

    @Test func aPromptBoxTurnNoLongerAwaitedLendsItsRequestToNothing() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var results: [String] = []
        hub.onResult = { _, _, answer, _, _ in results.append(answer) }
        hub.awaitTypedTurn(of: "claude:s1", request: "r7")
        hub.forgetTypedTurn(of: "claude:s1", request: "r7")
        hub.handle(.typed(session: "claude:s1"))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t5"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "typed by hand"))
        #expect(results.isEmpty)
    }

    @Test func aDictatedTurnWhoseCompletionWasLostNeverLendsItsResultToALaterTypedTurn() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var results: [String] = []
        hub.onResult = { _, _, value, _, _ in results.append(value) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        _ = await receipt
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(hello("claude:s1"))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "a typed reply"))
        #expect(results.isEmpty)
    }

    @Test func aNewTurnStartingBeforeTheDictatedOneCompletesTakesItsEligibilityAway() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var results: [String] = []
        hub.onResult = { _, _, value, _, _ in results.append(value) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        _ = await receipt
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "a typed reply"))
        #expect(results.isEmpty)
    }

    @Test func aRepeatedStartOfTheSameTurnKeepsItsResult() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var results: [String] = []
        hub.onResult = { _, _, value, _, _ in results.append(value) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.submitted(request: "r1", turn: "1"))
        _ = await receipt
        hub.handle(.turnStarted(session: "claude:s1", turn: "1"))
        hub.handle(.turnStarted(session: "claude:s1", turn: "1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "complete", answer: "All green."))
        #expect(results == ["All green."])
    }

    @Test func aSubmitThatCannotNameItsTurnIsConfirmedButNoLaterTurnIsSpoken() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var results: [String] = []
        hub.onResult = { _, _, value, _, _ in results.append(value) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(await receipt == .sent("keyscribe"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "the rewritten dictation's reply"))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "a typed reply"))
        #expect(results.isEmpty)
    }

    @Test func aSubmitWithNoTurnBeforeAnyTurnStartsLendsNothingToTheNextTurn() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var results: [String] = []
        hub.onResult = { _, _, value, _, _ in results.append(value) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.submitted(request: "r1", turn: ""))
        _ = await receipt
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "a typed reply"))
        #expect(results.isEmpty)
    }

    @Test func aTurnThatWasStoppedOrFailedReportsNoAnswer() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var results: [String] = []
        hub.onResult = { _, _, value, _, _ in results.append(value) }
        for reason in ["aborted", "error"] {
            async let receipt = hub.deliver("one", to: "claude:s1")
            let before = transport.sent.count
            await untilSent(transport, before + 1)
            hub.handle(.submitted(request: transport.sent.last!.0.id, turn: "t"))
            _ = await receipt
            hub.handle(.turnComplete(session: "claude:s1", reason: reason, answer: "partial"))
        }
        #expect(results.isEmpty)
    }

    @Test func typingIntoAConversationMakesItTheCurrentRecipient() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, "s1")
        await connected(hub, transport, registry, "s2")
        hub.makeCurrent("claude:s1")
        hub.handle(.typed(session: "claude:s2"))
        #expect(hub.current == "claude:s2")
    }

    @Test func theRecordingListFollowsTheLastConversationsUsed() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), clock: clock)
        registry.set("s1", cwd: "/src/alpha")
        registry.set("s2", cwd: "/src/bravo")
        registry.set("s3", cwd: "/src/charlie")
        transport.live.formUnion(["claude:s1", "claude:s2", "claude:s3"])
        await hub.rescan()
        #expect(hub.recordingOrder.map(\.id) == ["claude:s1", "claude:s2", "claude:s3"])
        hub.handle(.typed(session: "claude:s3"))
        clock.now += 1
        hub.makeCurrent("claude:s2")
        #expect(hub.recordingOrder.map(\.id) == ["claude:s2", "claude:s3", "claude:s1"])
        clock.now += 1
        _ = await hub.deliver("run the tests", to: "claude:s1")
        #expect(hub.recordingOrder.map(\.id) == ["claude:s2", "claude:s1", "claude:s3"])
    }

    @Test func aConversationStartedAfterTheLastUseLeadsTheRecordingList() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), clock: clock)
        registry.set("s1", cwd: "/src/alpha", pid: 10, startedAt: 100_000)
        registry.set("s2", cwd: "/src/bravo", pid: 20, startedAt: 200_000)
        transport.live.formUnion(["claude:s1", "claude:s2"])
        await hub.rescan()
        _ = await hub.deliver("run the tests", to: "claude:s1")
        #expect(hub.current == nil)
        #expect(hub.recordingOrder.map(\.id) == ["claude:s1", "claude:s2"])
        registry.set("s3", cwd: "/src/charlie", pid: 30, startedAt: Int(clock.now.timeIntervalSince1970 * 1000) + 500)
        transport.live.insert("claude:s3")
        await hub.rescan()
        #expect(hub.recordingOrder.map(\.id) == ["claude:s3", "claude:s1", "claude:s2"])
        clock.now += 1
        _ = await hub.deliver("run the tests", to: "claude:s2")
        #expect(hub.recordingOrder.map(\.id) == ["claude:s2", "claude:s3", "claude:s1"])
    }

    @Test func typingIntoTheConversationWhileQueuedHoldsItForReview() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        _ = await hub.deliver("run the tests", to: "claude:s1")

        hub.handle(.typed(session: "claude:s1"))
        registry.set("s1", status: "idle")
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.isEmpty)
        #expect(notices.items == [.kept("keyscribe", reason: .typedSince)])
    }

    @Test func namesAndRowsFollowTheDirectory() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, "s1")
        await connected(hub, transport, registry, "s2")
        #expect(hub.names == ["keyscribe": "claude:s1", "keyscribe blue": "claude:s2"])
        #expect(hub.rows == ["claude:s1", "claude:s2"])
    }

    @Test func renamingAConversationChangesItsNameAndTellsListeners() async throws {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, "s1")
        var changes = 0
        hub.onChange = { changes += 1 }
        try hub.rename("claude:s1", to: "Backend")
        #expect(hub.names == ["backend": "claude:s1"])
        #expect(changes == 1)
    }

    @Test func aNameAnotherConversationHoldsIsRefusedAndNothingChanges() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, "s1")
        await connected(hub, transport, registry, "s2")
        #expect(throws: AgentHandles.RenameError.taken) { try hub.rename("claude:s2", to: "keyscribe") }
        #expect(hub.names == ["keyscribe": "claude:s1", "keyscribe blue": "claude:s2"])
    }

    @Test func chosenNamesSurviveARestartThroughTheNameFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        registry.set("b", cwd: "/src/docs")
        let store = AgentNameStore(directory: dir)
        let first = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: store, scanDeadline: .seconds(30))
        await first.rescan()
        try first.rename("claude:a", to: "backend")
        try first.rename("claude:b", to: "api")

        let second = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await second.rescan()
        #expect(second.names == ["backend": "claude:a", "api": "claude:b"])
    }

    @Test func generatedNamesSurviveARestartForSessionsStillRunning() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", pid: 10, startedAt: 100)
        registry.set("b", pid: 20, startedAt: 200)
        let first = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await first.rescan()
        #expect(first.names == ["keyscribe": "claude:a", "keyscribe blue": "claude:b"])
        try first.rename("claude:a", to: "backend")
        registry.entries.reverse()
        registry.set("c", pid: 30, startedAt: 300)

        let second = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await second.rescan()
        #expect(second.names == ["backend": "claude:a", "keyscribe blue": "claude:b", "keyscribe": "claude:c"])
    }

    @Test func aClosedSessionsGeneratedNameIsDroppedFromTheNameFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", pid: 10, startedAt: 100)
        registry.set("b", pid: 20, startedAt: 200)
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await hub.rescan()
        registry.entries.removeAll { $0.sessionId == "a" }
        await hub.rescan()
        #expect(AgentNameStore(directory: dir).load() == .names([:], remembered: [
            "claude:b": RememberedName(name: "keyscribe blue", pid: 20, startedAt: 200, native: nil, agent: "claude"),
        ]))
    }

    @Test func aSessionAStartupScanMissedKeepsItsSavedNameWhileItsProcessRuns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", pid: 10, startedAt: 100)
        registry.set("b", pid: 20, startedAt: 200)
        await AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30)).rescan()
        let missing = registry.entries.first { $0.sessionId == "a" }!
        registry.entries.removeAll { $0.sessionId == "a" }
        registry.set("c", pid: 30, startedAt: 300)

        let second = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30),
                              stillRunning: { $0.pid == 10 })
        await second.rescan()
        #expect(second.names == ["keyscribe blue": "claude:b", "keyscribe green": "claude:c"])
        guard case .names(_, let remembered, _) = AgentNameStore(directory: dir).load() else { Issue.record("names not loaded"); return }
        #expect(remembered["claude:a"]?.name == "keyscribe")
        registry.entries.append(missing)
        await second.rescan()
        #expect(second.names == ["keyscribe": "claude:a", "keyscribe blue": "claude:b", "keyscribe green": "claude:c"])
    }

    @Test func generatedNamesThatCannotBeSavedAreReportedAndRetried() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: dir.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", pid: 10, startedAt: 100)
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        var changes = 0
        hub.onChange = { changes += 1 }
        await hub.rescan()
        #expect(hub.namesNotSaved != nil)
        #expect(hub.names == ["keyscribe": "claude:a"])
        let reported = changes
        await hub.rescan()
        #expect(changes == reported)
        try FileManager.default.removeItem(at: dir)
        await hub.rescan()
        #expect(hub.namesNotSaved == nil)
        #expect(changes == reported + 1)
        guard case .names(_, let remembered, _) = AgentNameStore(directory: dir).load() else { Issue.record("names not saved"); return }
        #expect(remembered["claude:a"] == RememberedName(name: "keyscribe", pid: 10, startedAt: 100, native: nil, agent: "claude"))
    }

    @Test func theSaveWarningClearsWhenNothingIsLeftUnsaved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: dir.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("c", pid: 30, startedAt: 300)
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30),
                           stillRunning: { _ in false })
        var changes = 0
        hub.onChange = { changes += 1 }
        await hub.rescan()
        #expect(hub.namesNotSaved != nil)
        let reported = changes
        registry.entries.removeAll()
        await hub.rescan()
        #expect(hub.namesNotSaved == nil)
        #expect(changes > reported)
    }

    @Test func aNameFileWithoutRememberedNamesStillLoads() throws {
        let dir = try nameDir(#"{"schema_version": 1, "names": {"claude:a": "backend"}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AgentNameStore(directory: dir).load() == .names(["claude:a": "backend"]))
    }

    @Test func aRenameThatCannotBeSavedIsNotApplied() async {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: blocker), scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(throws: (any Error).self) { try hub.rename("claude:a", to: "backend") }
        #expect(hub.names == ["api": "claude:a"])
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

    @Test func whileNamesCannotBeLoadedNoConversationIsAdmittedAndTheFileIsKept() async throws {
        let dir = try nameDir("not json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(hub.namesProblem != nil)
        #expect(hub.names.isEmpty)
        #expect(hub.rows.isEmpty)
        #expect(throws: (any Error).self) { try hub.rename("claude:a", to: "backend") }
        #expect(try String(contentsOf: dir.appendingPathComponent(AgentNameStore.fileName), encoding: .utf8) == "not json")
    }

    @Test func fixingTheNameFileAndTryingAgainBringsNamesBack() async throws {
        let dir = try nameDir("not json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await hub.rescan()
        var changes = 0
        hub.onChange = { changes += 1 }
        try Data(#"{"schema_version": 1, "names": {"claude:a": "backend"}}"#.utf8).write(to: dir.appendingPathComponent(AgentNameStore.fileName))
        hub.reloadNames()
        #expect(hub.namesProblem == nil)
        #expect(hub.names == ["backend": "claude:a"])
        #expect(changes > 0)
    }

    @Test func renamingAConversationThatEndedDoesNothing() async throws {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, "s1")
        try hub.rename("claude:gone", to: "backend")
        #expect(hub.names == ["keyscribe": "claude:s1"])
    }

    private func hello(_ session: String) -> AgentEvent {
        .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i2", session: session, pid: 0))
    }

    @Test func aTimedOutHandoffStillBlocksTheNextMessageAndReportsItsLateResult() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)

        #expect(await hub.deliver("one", to: "claude:s1") == .uncertain("keyscribe"))
        #expect(await hub.deliver("two", to: "claude:s1") == .queued("keyscribe"))
        #expect(transport.sent.count == 1)

        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.count == 2)
    }

    @Test func aLateRefusalAfterATimeoutKeepsTheTextAndReleasesTheQueue() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        _ = await hub.deliver("one", to: "claude:s1")
        _ = await hub.deliver("two", to: "claude:s1")

        hub.handle(.refused(request: "r1", reason: "sessionChanged"))
        #expect(notices.items == [.notSent("keyscribe", reason: .conversationChanged)])
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func aReconnectDoesNotGiveUpOnATimedOutMessageThatCanStillArrive() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        _ = await hub.deliver("one", to: "claude:s1")
        _ = await hub.deliver("two", to: "claude:s1")

        hub.handle(hello("claude:s1"))
        #expect(transport.sent.map(\.0.id) == ["r1"])

        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func aRefusalAfterTimeoutAndReconnectIsStillReportedAndKept() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        _ = await hub.deliver("one", to: "claude:s1")
        _ = await hub.deliver("two", to: "claude:s1")

        hub.handle(hello("claude:s1"))
        hub.handle(.refused(request: "r1", reason: "sessionChanged"))
        #expect(notices.items == [.notSent("keyscribe", reason: .conversationChanged)])
        #expect(transport.sent.map(\.0.id) == ["r1", "r2"])
    }

    @Test func aLostCompletionDoesNotLockTheConversationOnceTheRegistryShowsItIdle() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(clock: clock)
        await connected(hub, transport, registry)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        #expect(await hub.deliver("one", to: "claude:s1") == .queued("keyscribe"))

        await hub.rescan()
        #expect(transport.sent.isEmpty)

        clock.now += AgentHub.runningGrace + 1
        await hub.rescan()
        #expect(transport.sent.count == 1)
    }

    @Test func aFreshIdleHelloClearsARunningTurnTheRegistryNoLongerShows() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        _ = await hub.deliver("one", to: "claude:s1")

        greet(hub, ready(idle: true, gap: false))
        #expect(transport.sent.count == 1)
    }

    @Test func aReconnectAfterAGapNeverReleasesWhatWasHeld() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        _ = await hub.deliver("one", to: "claude:s1")

        greet(hub, ready(idle: true, gap: true))
        #expect(transport.sent.isEmpty)
        #expect(notices.items == [.kept("keyscribe", reason: .connectionGap)])
    }

    @Test func aRefusalOfAQueuedMessageIsReportedAsANotice() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        _ = await hub.deliver("one", to: "claude:s1")
        registry.set("s1", status: "idle")
        await hub.rescan()
        hub.handle(.refused(request: "r1", reason: "nope"))
        #expect(notices.items == [.notSent("keyscribe", reason: .refused("nope"))])
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
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus, scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(await hub.open("claude:s1") == .exact)
        hub.handle(.hello(.init(
            protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, environment: ["ZELLIJ_PANE_ID": "3"])))
        #expect(await hub.open("claude:s1") == .exact)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0)))
        #expect(await hub.open("claude:s1") == .exact)
        #expect(focus.environments == [[:], ["ZELLIJ_PANE_ID": "3"], [:]])
    }

    final class FakeDiscovery: AgentDiscovery {
        let kind: AgentKind
        var result: AgentScan = .found([])
        var stall: Duration?
        var blocked = false {
            didSet {
                guard !blocked else { return }
                let released = waiting
                waiting = []
                for continuation in released { continuation.resume() }
            }
        }
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var scans = 0
        private(set) var observed: [AgentEvent] = []
        private(set) var retired: [Set<String>] = []
        init(kind: AgentKind = AgentKind(id: "fake", displayName: "Fake", connectorName: "Fake connector")) { self.kind = kind }
        func scan(rereadingTitles: Bool) async -> AgentScan {
            scans += 1
            if let stall { try? await Task.sleep(for: stall) }
            if blocked { await withCheckedContinuation { waiting.append($0) } }
            return result
        }
        func stillRunning(_ remembered: RememberedName) -> Bool { false }
        func observe(_ event: AgentEvent) { observed.append(event) }
        func retire(sessions: Set<String>) {
            retired.append(sessions)
            if case .found(let found, let extras) = result { result = .found(found.filter { !sessions.contains($0.id) }, extras) }
        }
    }

    @Test func sessionEventsReachTheDiscoveryOfTheirAgentWithNativeIds() async {
        let one = FakeDiscovery(kind: AgentKind(id: "one", displayName: "One", connectorName: "One connector"))
        let two = FakeDiscovery(kind: AgentKind(id: "two", displayName: "Two", connectorName: "Two connector"))
        let hub = AgentHub(transport: FakeTransport(), discovery: [one, two])
        hub.handle(.hello(.init(protocolVersion: 2, agent: "two", agentVersion: "", instance: "i2", session: "two:s1", pid: 11, cwd: "/src/docs")))
        hub.handle(.turnStarted(session: "two:s1", turn: "t1"))
        hub.handle(.title(session: "one:s9", text: "x"))
        hub.handle(.submitted(request: "r1", turn: "t1"))
        await hub.rescan()
        #expect(two.observed == [
            .hello(.init(protocolVersion: 2, agent: "two", agentVersion: "", instance: "i2", session: "s1", pid: 11, cwd: "/src/docs")),
            .turnStarted(session: "s1", turn: "t1"),
        ])
        #expect(one.observed == [.title(session: "s9", text: "x")])
    }

    @Test func retiringAnInstallationForgetsOnlyWhatItsConnectorsAnnounced() async {
        let fake = FakeDiscovery()
        var other = Self.fakeSession("f2")
        other.pid = 11
        fake.result = .found([Self.fakeSession("f1"), other])
        let transport = FakeTransport()
        transport.live = ["fake:f1", "fake:f2"]
        let hub = AgentHub(transport: transport, discovery: [fake])
        hub.handle(.hello(.init(protocolVersion: 3, agent: "fake", agentVersion: "", instance: "i1", session: "fake:f1", pid: 10, installation: "a")))
        hub.handle(.hello(.init(protocolVersion: 3, agent: "fake", agentVersion: "", instance: "i2", session: "fake:f2", pid: 11, installation: "b")))
        await hub.rescan()
        hub.retire(installation: "a")
        await hub.rescan()
        #expect(fake.retired == [["f1"]])
        #expect(hub.directory.conversations.map(\.id) == ["fake:f2"])
    }

    @Test func retiringAnInstallationSilencesSpokenUpdatesForItsConversations() async {
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let transport = FakeTransport()
        transport.live = ["fake:f1"]
        let hub = AgentHub(transport: transport, discovery: [fake])
        hub.handle(.hello(.init(protocolVersion: 3, agent: "fake", agentVersion: "", instance: "i1", session: "fake:f1", pid: 10, installation: "a")))
        await hub.rescan()
        var silenced: [String] = []
        hub.onSilence = { silenced.append($0) }
        hub.retire(installation: "a")
        #expect(silenced == ["fake:f1"])
    }

    @Test func disconnectingAConversationNeverHandsItsNameToAnother() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-nm-\(UUID().uuidString)")
        let fake = FakeDiscovery()
        var other = Self.fakeSession("f2")
        other.pid = 11
        fake.result = .found([Self.fakeSession("f1"), other])
        let transport = FakeTransport()
        transport.live = ["fake:f1", "fake:f2"]
        let hub = AgentHub(transport: transport, discovery: [fake], names: AgentNameStore(directory: dir))
        await hub.rescan()
        let before = hub.names
        #expect(before.count == 2)
        let (name, id) = try #require(before.first { $0.value == "fake:f2" })
        hub.disconnect(id)
        #expect(hub.disconnectedNames == [name: id])
        #expect(hub.names[name] == nil)
        #expect(hub.names == before.filter { $0.value != id })
    }

    @Test func aDisconnectedConversationLeavesTheRecipientsAndItsHeldMessagesAreNotSent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-ex-\(UUID().uuidString)")
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let transport = FakeTransport()
        transport.live = ["fake:f1"]
        let hub = AgentHub(transport: transport, discovery: [fake], names: AgentNameStore(directory: dir))
        await hub.rescan()
        hub.makeCurrent("fake:f1")
        var forgotten: [String] = []
        hub.onSilence = { forgotten.append($0) }
        hub.disconnect("fake:f1")
        #expect(hub.directory.conversations.isEmpty)
        #expect(hub.disconnected.map(\.id) == ["fake:f1"])
        #expect(hub.current == nil)
        #expect(hub.names.isEmpty)
        #expect(hub.disconnectedNames == ["api": "fake:f1"])
        #expect(forgotten == ["fake:f1"])
        #expect(transport.sent.contains { if case .quiet(_, "fake:f1") = $0.0 { true } else { false } })
        #expect(await hub.deliver("run the tests", to: "fake:f1") == .notSent("api", reason: .disconnected))
        guard case .names(_, _, let excluded) = AgentNameStore(directory: dir).load() else { Issue.record("not saved"); return }
        #expect(excluded == ["fake:f1"])

        let reopened = AgentHub(transport: FakeTransport(), discovery: [fake], names: AgentNameStore(directory: dir))
        await reopened.rescan()
        #expect(reopened.isExcluded("fake:f1"))
        #expect(reopened.directory.conversations.isEmpty)

        hub.reconnect("fake:f1")
        #expect(transport.sent.contains { if case .admit(_, "fake:f1") = $0.0 { true } else { false } })
        #expect(hub.directory.conversations.map(\.id) == ["fake:f1"])
        guard case .names(_, _, let after) = AgentNameStore(directory: dir).load() else { Issue.record("not saved"); return }
        #expect(after.isEmpty)
    }

    @Test func eventsFromADisconnectedConversationAreIgnored() async {
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let transport = FakeTransport()
        transport.live = ["fake:f1"]
        let hub = AgentHub(transport: transport, discovery: [fake])
        await hub.rescan()
        hub.disconnect("fake:f1")
        var results: [String] = []
        hub.onResult = { _, _, answer, _, _ in results.append(answer) }
        hub.handle(.turnComplete(session: "fake:f1", reason: "complete", answer: "private"))
        #expect(results.isEmpty)
    }

    @Test func aDisconnectThatCannotBeSavedStillHoldsForThisSessionAndSaysSo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake], names: AgentNameStore(directory: dir))
        await hub.rescan()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        hub.disconnect("fake:f1")
        #expect(hub.isExcluded("fake:f1"))
        #expect(hub.exclusionsNotSaved != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        hub.retrySavingExclusions()
        #expect(hub.exclusionsNotSaved == nil)
    }

    @Test func unreadableSavedChoicesAdmitNoConversationUntilTheyCanBeRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(AgentNameStore.fileName))
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake], names: AgentNameStore(directory: dir))
        await hub.rescan()
        #expect(hub.isExcluded("fake:f1"))
        #expect(hub.directory.conversations.isEmpty)
        try AgentNameStore(directory: dir).save([:], remembered: [:])
        hub.reloadNames()
        #expect(!hub.isExcluded("fake:f1"))
    }

    @Test func aSubmitRefusedBecauseADialogIsOpenIsKeptForReview() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.refused(request: transport.sent[0].0.id, reason: "dialog"))
        #expect(await receipt == .kept("keyscribe", reason: .dialog))
    }

    private static func fakeSession(_ id: String) -> AgentSession {
        AgentSession(agent: "fake", id: id, pid: 10, cwd: "/src/api", state: .idle)
    }

    @Test func anUnreadableSessionListKeepsTheLastRosterAndSaysSo() async {
        let fake = FakeDiscovery()
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake])
        fake.result = .found([Self.fakeSession("f1")])
        await hub.rescan()
        #expect(hub.directory.conversations.map(\.id) == ["fake:f1"])
        var changes = 0
        hub.onChange = { changes += 1 }
        fake.result = .unreadable("boom")
        await hub.rescan()
        #expect(hub.directory.conversations.map(\.id) == ["fake:f1"])
        #expect(hub.discoveryProblems == ["fake": "boom"])
        #expect(changes == 1)
        await hub.rescan()
        #expect(changes == 1)
        fake.result = .found([])
        await hub.rescan()
        #expect(hub.directory.conversations.isEmpty)
        #expect(hub.discoveryProblems.isEmpty)
    }

    @Test func aScanThatDoesNotAnswerInTimeKeepsTheLastRosterAndSaysSo() async {
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake], scanDeadline: .milliseconds(50))
        await hub.rescan()
        #expect(hub.directory.conversations.map(\.id) == ["fake:f1"])
        fake.blocked = true
        fake.result = .found([])
        let started = ContinuousClock.now
        await hub.rescan()
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(hub.directory.conversations.map(\.id) == ["fake:f1"])
        #expect(hub.discoveryProblems == ["fake": "Fake\u{2019}s session list is not answering, so these are the sessions last seen."])
        fake.blocked = false
        for _ in 0..<100 where !hub.directory.conversations.isEmpty { await hub.rescan() }
        #expect(hub.directory.conversations.isEmpty)
        #expect(hub.discoveryProblems.isEmpty)
        #expect(fake.scans <= 102)
    }

    @Test func aScanThatNeverAnswersIsNotStartedAgainUntilItSettles() async {
        let fake = FakeDiscovery()
        fake.blocked = true
        fake.result = .found([Self.fakeSession("f1")])
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake], scanDeadline: .milliseconds(30))
        for _ in 0..<3 { await hub.rescan() }
        #expect(fake.scans == 1)
        #expect(hub.directory.conversations.isEmpty)
        #expect(hub.discoveryProblems["fake"] != nil)
        fake.blocked = false
        await hub.rescan()
        #expect(fake.scans == 1)
        #expect(hub.directory.conversations.map(\.id) == ["fake:f1"])
        #expect(hub.discoveryProblems.isEmpty)
        await hub.rescan()
        #expect(fake.scans == 2)
    }

    @Test func aRescanAskedForWhileAScanRunsRunsAgainAfterIt() async {
        let fake = FakeDiscovery()
        fake.blocked = true
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake], scanDeadline: .seconds(5))
        async let first: Void = hub.rescan(rereadingTitles: false)
        while fake.scans == 0 { await Task.yield() }
        async let second: Void = hub.rescan(rereadingTitles: false)
        try? await Task.sleep(for: .milliseconds(20))
        fake.blocked = false
        _ = await (first, second)
        #expect(fake.scans == 2)
    }

    @Test func aScanThatFinishesAfterTheHubStoppedChangesNothing() async {
        let fake = FakeDiscovery()
        fake.blocked = true
        fake.result = .found([Self.fakeSession("f1")])
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake], scanDeadline: .seconds(5))
        var changes = 0
        hub.onChange = { changes += 1 }
        async let scanning: Void = hub.rescan()
        try? await Task.sleep(for: .milliseconds(10))
        hub.stop()
        fake.blocked = false
        await scanning
        #expect(hub.directory.conversations.isEmpty)
        #expect(hub.discoveryProblems.isEmpty)
        #expect(changes == 0)
    }

    @Test func aConnectorTitleReportedDuringAScanOutlivesThatScan() async {
        let fake = FakeDiscovery()
        func session(named name: String) -> AgentSession {
            AgentSession(agent: "fake", id: "f1", pid: 10, cwd: "/src/api", explicitName: name, state: .idle)
        }
        let transport = FakeTransport()
        transport.live = ["fake:f1"]
        let hub = AgentHub(transport: transport, discovery: [fake], scanDeadline: .seconds(5))
        fake.result = .found([session(named: "Alpha")])
        await hub.rescan()
        #expect(hub.directory.conversations.first?.handle == "alpha")
        fake.result = .found([session(named: "Alpha two")])
        fake.blocked = true
        async let scanning: Void = hub.rescan()
        for _ in 0..<10_000 where fake.scans < 2 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(2))
        hub.handle(.title(session: "fake:f1", text: "Bravo"))
        #expect(hub.directory.conversations.first?.handle == "bravo")
        fake.blocked = false
        await scanning
        #expect(hub.directory.conversations.first?.handle == "bravo")
        fake.result = .found([session(named: "Alpha three")])
        await hub.rescan()
        #expect(hub.directory.conversations.first?.handle == "alpha three")
    }

    @Test func aTitleReportedAfterATimedOutScanStartedSurvivesItsLateCompletion() async {
        let fake = FakeDiscovery()
        func session(named name: String) -> AgentSession {
            AgentSession(agent: "fake", id: "f1", pid: 10, cwd: "/src/api", explicitName: name, state: .idle)
        }
        let transport = FakeTransport()
        transport.live = ["fake:f1"]
        let hub = AgentHub(transport: transport, discovery: [fake], scanDeadline: .milliseconds(30))
        fake.result = .found([session(named: "Alpha")])
        await hub.rescan()
        #expect(hub.directory.conversations.first?.handle == "alpha")
        fake.result = .found([session(named: "Alpha two")])
        fake.blocked = true
        await hub.rescan()
        #expect(hub.discoveryProblems["fake"] != nil)
        try? await Task.sleep(for: .milliseconds(2))
        hub.handle(.title(session: "fake:f1", text: "Bravo"))
        #expect(hub.directory.conversations.first?.handle == "bravo")
        fake.blocked = false
        for _ in 0..<100 where !hub.discoveryProblems.isEmpty { await hub.rescan() }
        #expect(fake.scans == 2)
        #expect(hub.discoveryProblems.isEmpty)
        #expect(hub.directory.conversations.first?.handle == "bravo")
    }

    @Test func aRescanAskedForWhileOneRunsIsNotStartedTwiceButRunsOnceMore() async {
        let fake = FakeDiscovery()
        fake.stall = .milliseconds(30)
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake])
        async let first: Void = hub.rescan()
        try? await Task.sleep(for: .milliseconds(5))
        async let second: Void = hub.rescan()
        async let third: Void = hub.rescan()
        await first
        await second
        await third
        #expect(fake.scans == 2)
    }

    @Test func twoAgentsReportingTheSameNativeIdAreTwoConversations() async {
        let one = FakeDiscovery(kind: AgentKind(id: "one", displayName: "One", connectorName: "One connector"))
        let two = FakeDiscovery(kind: AgentKind(id: "two", displayName: "Two", connectorName: "Two connector"))
        one.result = .found([AgentSession(agent: "one", id: "s1", pid: 10, cwd: "/src/api", state: .idle)])
        two.result = .found([AgentSession(agent: "two", id: "s1", pid: 11, cwd: "/src/docs", state: .idle)])
        let transport = FakeTransport()
        transport.live = ["one:s1", "two:s1"]
        let hub = AgentHub(transport: transport, discovery: [one, two])
        await hub.rescan()
        #expect(Set(hub.directory.conversations.map(\.id)) == ["one:s1", "two:s1"])
        #expect(Set(hub.names.keys) == ["api", "docs"])
        try? hub.rename("two:s1", to: "backend")
        #expect(hub.names["backend"] == "two:s1")
        #expect(hub.names["api"] == "one:s1")
        hub.handle(.hello(.init(protocolVersion: 1, agent: "two", agentVersion: "", instance: "i2", session: "two:s1", pid: 11)))
        async let receipt = hub.deliver("run the tests", to: "two:s1")
        await untilSent(transport, 1)
        #expect(transport.sent.map(\.1) == ["two:s1"])
        hub.handle(.submitted(request: transport.sent[0].0.id, turn: ""))
        #expect(await receipt == .sent("backend"))
    }

    @Test func aLiveConnectorWithoutFocusIsUnsupportedWhenItsAgentsConnectorNeverFocuses() async {
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let transport = FakeTransport()
        transport.live = ["fake:f1"]
        let hub = AgentHub(transport: transport, discovery: [fake])
        await hub.rescan()
        hub.handle(.hello(.init(protocolVersion: 1, agent: "fake", agentVersion: "", instance: "i1", session: "fake:f1", pid: 10)))
        #expect(await hub.focusInPlace("fake:f1") == .unsupported)
        #expect(transport.sent.isEmpty)
    }

    @Test func aRememberedNameSavedWithoutAnAgentBelongsToTheLegacyAgent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = #"{"schema_version":1,"names":{},"remembered":{"a":{"name":"keyscribe","pid":10,"started_at":100}}}"#
        try Data(legacy.utf8).write(to: dir.appendingPathComponent(AgentNameStore.fileName))
        let migrated = AgentNameStore(directory: dir, legacyAgent: "claude").load()
        #expect(migrated == .names([:], remembered: ["claude:a": RememberedName(name: "keyscribe", pid: 10, startedAt: 100, native: nil, agent: "claude")]))
        let unmigrated = AgentNameStore(directory: dir).load()
        #expect(unmigrated == .names([:], remembered: ["a": RememberedName(name: "keyscribe", pid: 10, startedAt: 100, native: nil, agent: "")]))
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
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, front: front, scanDeadline: .seconds(30))
        await hub.rescan()
        hub.handle(.hello(.init(
            protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s2", pid: 0, environment: ["ZELLIJ_PANE_ID": "3"])))
        let shown = FrontSession(id: "claude:s2", app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty"))
        front.answer = shown
        #expect(await hub.sessionInFront() == shown)
        #expect(front.asked == [[AgentFrontCandidate(id: "claude:s1", pid: 10), AgentFrontCandidate(id: "claude:s2", pid: 11, environment: ["ZELLIJ_PANE_ID": "3"])]])
        let blind = AgentHub(transport: FakeTransport(), scan: { registry.entries }, scanDeadline: .seconds(30))
        await blind.rescan()
        #expect(await blind.sessionInFront() == nil)
    }

    @Test func openingWithoutMakingCurrentLeavesTheRecipientAlone() async {
        let focus = FakeFocus()
        let registry = Registry()
        registry.set("s1")
        registry.set("s2", pid: 11)
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus, scanDeadline: .seconds(30))
        await hub.rescan()
        hub.makeCurrent("claude:s1")
        #expect(await hub.open("claude:s2", makingCurrent: false) == .exact)
        #expect(hub.current == "claude:s1")
        #expect(focus.focused.map(\.0) == ["claude:s2"])
    }

    @Test func openingHandsTheStopCheckToTheTerminalFocus() async {
        let focus = FakeFocus()
        let registry = Registry()
        registry.set("s1")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus, scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(await hub.open("claude:s1", stillWanted: { false }) == .exact)
        #expect(focus.wanted == [false])
    }

    @Test func openingMakesTheConversationCurrentAndBringsItsTerminalForward() async {
        let focus = FakeFocus()
        let registry = Registry()
        registry.set("s1")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus, scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(await hub.open("claude:s1") == .exact)
        #expect(hub.current == "claude:s1")
        #expect(focus.focused.map(\.0) == ["claude:s1"])
        #expect(focus.focused.map(\.1) == [10])
    }

    private func focusHello(_ session: String = "claude:s1") -> AgentEvent {
        .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: session, pid: 0, features: ["focus"]))
    }

    @Test func aConnectorThatAnnouncedFocusIsAskedToFocusItsSessionBeforeTheRequestExpires() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(clock: clock)
        await connected(hub, transport, registry)
        hub.handle(focusHello())
        let sentBefore = transport.sent.count
        async let answer = hub.focusInPlace("claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.map(\.0) == [.focus(id: "r1", expectedSession: "claude:s1", expiresAt: clock.now.addingTimeInterval(3))])
        hub.handle(.focused(request: "r1"))
        #expect(await answer == .selected)
    }

    @Test func aLiveConnectorThatCannotFocusIsNeverAskedAndSaysItNeedsAnUpdate() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(hello("claude:s1"))
        #expect(await hub.focusInPlace("claude:s1") == .outdated)
        #expect(transport.sent.isEmpty)
    }

    @Test func aConversationWhoseConnectorNeverConnectedIsNotAsked() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        transport.live = []
        #expect(await hub.focusInPlace("claude:s1") == .notFound)
        #expect(transport.sent.isEmpty)
    }

    @Test func aRefusedFocusIsNotFoundAndNeverReadsAsADeliveryReceipt() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(focusHello())
        let sentBefore = transport.sent.count
        async let refused = hub.focusInPlace("claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "notInCmux"))
        #expect(await refused == .notFound)
        #expect(notices.items.isEmpty)
    }

    @Test func anUnansweredFocusIsWithdrawnAndALateAnswerChangesNothing() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(focusHello())
        #expect(await hub.focusInPlace("claude:s1", within: .milliseconds(20)) == .notFound)
        #expect(transport.withdrawn == ["r1"])
        hub.handle(.focused(request: "r1"))
        #expect(notices.items.isEmpty)
    }

    @Test func aCancelledFocusIsWithdrawnAtOnce() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(focusHello())
        let task = Task { await hub.focusInPlace("claude:s1", within: .seconds(30)) }
        while transport.sent.isEmpty { await Task.yield() }
        task.cancel()
        #expect(await task.value == .notFound)
        #expect(transport.withdrawn == ["r1"])
    }

    private func labelHello(_ session: String = "claude:s1", title: String? = nil) -> AgentEvent {
        .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: session, pid: 0, features: ["label"], title: title))
    }

    @Test func whatAConnectorReportedForASessionIsForgottenOnceTheSessionEndsAndDisconnects() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        await connected(hub, transport, registry, "s2")
        hub.handle(labelHello(title: "Fix authentication retries"))
        hub.handle(labelHello("claude:s2", title: "Write the docs"))
        hub.handle(.typed(session: "claude:s2", prompts: 4))
        await hub.rescan()
        #expect(hub.connectorStateSessions == ["claude:s1", "claude:s2"])
        registry.entries.removeAll { $0.sessionId == "s2" }
        await hub.rescan()
        #expect(hub.connectorStateSessions == ["claude:s1", "claude:s2"])
        #expect(transport.forgotten.isEmpty)
        transport.live.remove("claude:s2")
        await hub.rescan()
        #expect(hub.connectorStateSessions == ["claude:s1"])
        #expect(transport.forgotten == ["claude:s2"])
        await hub.rescan()
        #expect(transport.forgotten == ["claude:s2"])
    }

    @Test func explicitConnectorNamesAreAddressesAndOverridesStillWin() async throws {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(labelHello(title: "Fix authentication retries"))
        #expect(hub.names == ["fix authentication retries": "claude:s1"])
        let frozenNames = hub.names
        let frozenConversations = hub.directory.conversations
        hub.handle(.title(session: "claude:s1", text: "Cache invalidation"))
        #expect(hub.names == ["cache invalidation": "claude:s1"])
        #expect(AgentAddress.parse("fix authentication retries, run the tests", names: Array(frozenNames.keys)) == .name("fix authentication retries", body: "run the tests"))
        let roster = AgentRoster(frozen: frozenConversations, live: hub.directory.conversations, recipient: .init(id: "claude:s1", source: .current))
        #expect(roster.rows.first?.name == "fix authentication retries")
        try hub.rename("claude:s1", to: "backend")
        hub.handle(.title(session: "claude:s1", text: "Another native name"))
        #expect(hub.names == ["backend": "claude:s1"])
    }

    @Test func anExplicitAbsenceFromTheConnectorOverridesStaleRegistryNames() async {
        let (hub, transport, registry, _) = makeHub()
        registry.entries = [.init(pid: 10, sessionId: "s1", cwd: "/src/api", name: "Old native name", status: "idle", waitingFor: nil, nameSource: "user")]
        transport.live.insert("claude:s1")
        await hub.rescan()
        #expect(hub.names == ["old native name": "claude:s1"])
        hub.handle(labelHello())
        #expect(hub.names == ["old native name": "claude:s1"])
        hub.handle(.title(session: "claude:s1", text: ""))
        #expect(hub.names == ["api": "claude:s1"])
    }

    @Test func aFreshRegistryRenameSupersedesTheLastHookReport() async {
        let (hub, transport, registry, _) = makeHub()
        registry.entries = [.init(pid: 10, sessionId: "s1", cwd: "/src/api", name: "Stale", status: "idle", waitingFor: nil, nameSource: "user")]
        transport.live.insert("claude:s1")
        await hub.rescan()
        hub.handle(labelHello(title: "Actual"))
        #expect(hub.names == ["actual": "claude:s1"])
        registry.entries[0].name = "Renamed in Claude"
        await hub.rescan()
        #expect(hub.names == ["renamed in claude": "claude:s1"])
        registry.entries[0].name = "Stale"
        await hub.rescan()
        #expect(hub.names == ["stale": "claude:s1"])
    }

    private func labels(_ transport: FakeTransport) -> [String] {
        transport.sent.compactMap { if case .status(_, _, let text) = $0.0 { text } else { nil } }
    }

    @Test func aConnectorThatShowsLabelsIsToldTheNameToShowOnceAndAgainAfterARename() async throws {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(labelHello())
        await hub.rescan()
        #expect(labels(transport) == ["\u{201C}keyscribe\u{201D}"])
        try hub.rename("claude:s1", to: "backend")
        #expect(labels(transport) == ["\u{201C}keyscribe\u{201D}", "\u{201C}backend\u{201D}"])
        hub.handle(labelHello())
        #expect(labels(transport).count == 3)
    }

    @Test func choosingTheCurrentRecipientLeavesEveryLabelAsItWas() async {
        let (hub, transport, registry, _) = makeHub()
        registry.set("s1")
        registry.set("s2", cwd: "/src/backend")
        transport.live.formUnion(["claude:s1", "claude:s2"])
        await hub.rescan()
        hub.handle(labelHello("claude:s1"))
        hub.handle(labelHello("claude:s2"))
        #expect(Set(labels(transport)) == ["\u{201C}keyscribe\u{201D}", "\u{201C}backend\u{201D}"])
        hub.makeCurrent("claude:s1")
        hub.makeCurrent("claude:s2")
        #expect(labels(transport).count == 2)
    }

    @Test func aConnectorThatCannotShowLabelsIsNeverSentOne() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(hello("claude:s1"))
        #expect(labels(transport).isEmpty)
    }

    @Test func theTitleAConnectorReportsReachesItsConversation() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(labelHello(title: "Fix terminal focus"))
        #expect(hub.directory.conversations.first?.title == "Fix terminal focus")
        hub.handle(.title(session: "claude:s1", text: "Fix focus after reconnect"))
        #expect(hub.directory.conversations.first?.title == "Fix focus after reconnect")
        hub.handle(.title(session: "claude:s1", text: ""))
        #expect(hub.directory.conversations.first?.title == nil)
    }

    @Test func aTranscriptTitleShowsUntilTheConnectorReportsOneTheUserGave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-titles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("projects/-src-keyscribe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"ai-title","aiTitle":"Generated","sessionId":"claude:s1"}"#.utf8).write(to: folder.appendingPathComponent("s1.jsonl"))
        let registry = Registry()
        let transport = FakeTransport()
        let hub = AgentHub(transport: transport, scan: { registry.entries }, transcriptTitles: ClaudeTranscriptTitles(configDirs: [dir]), scanDeadline: .seconds(30))
        registry.set("s1")
        transport.live.insert("claude:s1")
        await hub.rescan()
        #expect(hub.directory.conversations.first?.title == "Generated")
        #expect(hub.names == ["keyscribe": "claude:s1"])
        hub.handle(labelHello(title: "Chosen by me"))
        #expect(hub.directory.conversations.first?.title == "Chosen by me")
        #expect(hub.names == ["chosen by me": "claude:s1"])
    }

    @Test func theRoutineRefreshLeavesTranscriptsAloneUntilSomethingAsksForFreshTitles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-routine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("projects/-src-keyscribe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        try Data(#"{"type":"ai-title","aiTitle":"First","sessionId":"claude:s1"}"#.utf8).write(to: file)
        let start = Date()
        let clock = ClaudeTranscriptTitlesTests.Clock()
        clock.now = start
        let registry = Registry()
        let hub = AgentHub(
            transport: FakeTransport(), scan: { registry.entries },
            transcriptTitles: ClaudeTranscriptTitles(configDirs: [dir], now: { clock.now }), scanDeadline: .seconds(30))
        registry.set("s1")
        await hub.rescan(rereadingTitles: false)
        #expect(hub.directory.conversations.first?.title == "First")

        clock.now += ClaudeTranscriptTitles.rereadInterval
        try Data(#"{"type":"ai-title","aiTitle":"Second","sessionId":"claude:s1"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: clock.now], ofItemAtPath: file.path)
        await hub.rescan(rereadingTitles: false)
        #expect(hub.directory.conversations.first?.title == "First")
        await hub.rescan()
        #expect(hub.directory.conversations.first?.title == "Second")
    }

    @Test func anExplicitTranscriptNameIsAddressableBeforeTheConnectorStarts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-native-name-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("projects/-src-keyscribe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"custom-title","customTitle":"Fix authentication retries","sessionId":"claude:s1"}"#.utf8).write(to: folder.appendingPathComponent("s1.jsonl"))
        let registry = Registry()
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, transcriptTitles: ClaudeTranscriptTitles(configDirs: [dir]), scanDeadline: .seconds(30))
        registry.set("s1")
        await hub.rescan()
        #expect(hub.names == ["fix authentication retries": "claude:s1"])
        hub.handle(labelHello())
        #expect(hub.names == ["fix authentication retries": "claude:s1"])
        hub.handle(.title(session: "claude:s1", text: ""))
        #expect(hub.names == ["keyscribe": "claude:s1"])
    }

    @Test func aConversationThatReconnectsWithoutATitleLosesItsOldOne() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(labelHello(title: "Named"))
        hub.handle(labelHello())
        #expect(hub.directory.conversations.first?.title == nil)
    }

    @Test func openingAConversationThatIsGoneDoesNothing() async {
        let focus = FakeFocus()
        let hub = AgentHub(transport: FakeTransport(), scan: { [] }, focus: focus, scanDeadline: .seconds(30))
        #expect(await hub.open("claude:s1") == .none)
        #expect(hub.current == nil)
        #expect(focus.focused.isEmpty)
    }

    @Test func aTerminalThatCannotComeForwardStillLeavesTheConversationCurrent() async {
        let focus = FakeFocus()
        focus.result = .none
        let registry = Registry()
        registry.set("s1")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus, scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(await hub.open("claude:s1") == .none)
        #expect(hub.current == "claude:s1")
    }

    final class Spoken {
        var results: [String] = []
        var endings: [String] = []
        var withdrawn: [String] = []
    }

    private func listening(_ hub: AgentHub, speaks: Bool = true) -> Spoken {
        let spoken = Spoken()
        hub.speaks = { speaks }
        hub.onResult = { _, _, answer, requested, _ in spoken.results.append("\(answer)|\(requested)") }
        hub.onEnded = { _, handle, body, requested, _ in spoken.endings.append("\(handle)|\(body)|\(requested)") }
        hub.onWithdraw = { spoken.withdrawn.append($0) }
        return spoken
    }

    private func reconnected(turn: String?, idle: Bool) -> AgentEvent.Hello {
        .init(
            protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0,
            features: ["readiness", "notify"], idle: idle, gap: true, turn: turn)
    }

    @Test func aReplyAskedForInTheAgentIsReadAsRequested() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        let spoken = listening(hub)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        #expect(hub.notify(session: "claude:s1", turn: "t1", on: true))
        #expect(hub.notify(session: "claude:s1", turn: "t1", on: true))
        #expect(hub.readAloud == ["claude:s1"])
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "a later typed reply"))
        #expect(spoken.results == ["All green.|true"])
        #expect(hub.readAloud.isEmpty && hub.readNextAloud.isEmpty)
    }

    @Test func withSpokenRepliesOffARequestIsRefusedAndNothingIsArmed() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        let spoken = listening(hub, speaks: false)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        #expect(!hub.notify(session: "claude:s1", turn: "t1", on: true))
        #expect(!hub.notify(session: "claude:s1", turn: "", on: true))
        #expect(hub.readAloud.isEmpty && hub.readNextAloud.isEmpty)
        hub.speaks = { true }
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Next."))
        #expect(spoken.results.isEmpty)
    }

    @Test func aRequestWhileIdleCoversTheNextReplyOnly() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        let spoken = listening(hub)
        #expect(hub.notify(session: "claude:s1", turn: "", on: true))
        #expect(hub.readNextAloud == ["claude:s1"])
        #expect(hub.readAloud.isEmpty)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        #expect(hub.readAloud == ["claude:s1"] && hub.readNextAloud.isEmpty)
        hub.handle(.turnComplete(session: "claude:s1", reason: "complete", answer: "Done."))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t3"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "complete", answer: "Later."))
        #expect(spoken.results == ["Done.|true"])
    }

    @Test func aRequestedTurnReportsItsWaitsAsRequested() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        _ = listening(hub)
        var seen: [String] = []
        hub.onAttention = { _, _, value, requested in seen.append("\(value.map { "\($0)" } ?? "cleared")|\(requested)") }
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        await hub.rescan()
        #expect(seen == ["approval|true"])
    }

    @Test func askingToHearADictatedTurnThatIsAlreadyWaitingReportsTheWaitAgainAsRequested() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        _ = listening(hub)
        var seen: [String] = []
        hub.onAttention = { _, _, value, requested in seen.append("\(value.map { "\($0)" } ?? "cleared")|\(requested)") }
        await dictated(hub, transport)
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        await hub.rescan()
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        #expect(seen == ["approval|false", "approval|true"])
    }

    @Test func aReconnectDuringTheSameTurnKeepsWaitingForItsReply() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        let spoken = listening(hub)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        greet(hub, reconnected(turn: "t1", idle: false))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(spoken.results == ["All green.|true"])
    }

    @Test func aDictatedReplySurvivesAReconnectDuringItsTurn() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        let spoken = listening(hub)
        await dictated(hub, transport)
        greet(hub, reconnected(turn: "t1", idle: false))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(spoken.results == ["All green.|false"])
    }

    @Test func aTurnThatEndedWhileDisconnectedSendsTheUserToTheConversation() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        let spoken = listening(hub)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        greet(hub, reconnected(turn: nil, idle: true))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "late"))
        #expect(spoken.endings == ["keyscribe|\(SpokenResult.repliedBody)|true"])
        #expect(spoken.results.isEmpty)
    }

    @Test func aReconnectWhileIdleKeepsARequestForTheNextReply() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        let spoken = listening(hub)
        _ = hub.notify(session: "claude:s1", turn: "", on: true)
        greet(hub, reconnected(turn: nil, idle: true))
        #expect(spoken.endings.isEmpty)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "complete", answer: "Done."))
        #expect(spoken.results == ["Done.|true"])
    }

    @Test func aReconnectThatReportsAnotherTurnOrNoTurnClearsTheRequest() async {
        for hello in [reconnected(turn: "t9", idle: false), reconnected(turn: nil, idle: false), ready(idle: false, gap: true)] {
            let (hub, transport, registry, _) = makeHub()
            await connected(hub, transport, registry, status: "busy")
            let spoken = listening(hub)
            hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
            _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
            greet(hub, hello)
            hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
            #expect(spoken.results.isEmpty)
            #expect(spoken.endings.isEmpty)
            #expect(hub.readAloud.isEmpty && hub.readNextAloud.isEmpty)
        }
    }

    @Test func cancellingWithdrawsThePendingSpeechAndIsNotUndoneByAReconnect() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        let spoken = listening(hub)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        _ = hub.notify(session: "claude:s1", turn: "t1", on: false)
        #expect(spoken.withdrawn == ["claude:s1"])
        #expect(hub.readAloud.isEmpty && hub.readNextAloud.isEmpty)
        greet(hub, reconnected(turn: "t1", idle: false))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(spoken.results.isEmpty)
    }

    @Test func cancellingAlsoStopsADictatedReplyAndWhatIsAlreadyBeingSpoken() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        let spoken = listening(hub)
        await dictated(hub, transport)
        _ = hub.notify(session: "claude:s1", turn: "t1", on: false)
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(spoken.results.isEmpty)
        _ = hub.notify(session: "claude:s1", turn: "", on: false)
        #expect(spoken.withdrawn == ["claude:s1", "claude:s1"])
    }

    @Test func cancellingFromSettingsCoversARequestForTheNextReply() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        let spoken = listening(hub)
        _ = hub.notify(session: "claude:s1", turn: "", on: true)
        hub.cancelReadAloud("claude:s1")
        #expect(hub.readAloud.isEmpty && hub.readNextAloud.isEmpty)
        #expect(spoken.withdrawn == ["claude:s1"])
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "complete", answer: "Done."))
        #expect(spoken.results.isEmpty)
    }

    @Test func turningSpokenRepliesOffClearsRequestsSoTurningThemBackOnReplaysNothing() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        let spoken = listening(hub)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        _ = hub.notify(session: "claude:s2", turn: "", on: true)
        hub.speechTurnedOff()
        #expect(hub.readAloud.isEmpty && hub.readNextAloud.isEmpty)
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(spoken.results.isEmpty)
    }

    @Test(arguments: [("error", "Ended with an error."), ("refusal", "Couldn\u{2019}t complete the request."), ("unknown", SpokenResult.repliedBody)])
    func aRequestedTurnThatEndsWithoutAReplySaysHowItEnded(reason: String, body: String) async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        let spoken = listening(hub)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        hub.handle(.turnComplete(session: "claude:s1", reason: reason, answer: ""))
        #expect(spoken.endings == ["keyscribe|\(body)|true"])
    }

    @Test func aDictatedTurnThatFailsSaysSoAndAnInterruptedOneStaysSilent() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        let spoken = listening(hub)
        await dictated(hub, transport, turn: "t1")
        hub.handle(.turnComplete(session: "claude:s1", reason: "error", answer: ""))
        await dictated(hub, transport, turn: "t2")
        hub.handle(.turnComplete(session: "claude:s1", reason: "aborted", answer: ""))
        #expect(spoken.endings == ["keyscribe|Ended with an error.|false"])
        #expect(spoken.results.isEmpty)
    }

    @Test func disconnectingAConversationDropsItsRequest() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-ra-\(UUID().uuidString)")
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let transport = FakeTransport()
        transport.live = ["fake:f1"]
        let hub = AgentHub(transport: transport, discovery: [fake], names: AgentNameStore(directory: dir))
        await hub.rescan()
        _ = listening(hub)
        _ = hub.notify(session: "fake:f1", turn: "", on: true)
        hub.disconnect("fake:f1")
        #expect(hub.readAloud.isEmpty && hub.readNextAloud.isEmpty)
    }
}
