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
        var pinned: [String: String] = [:]
        var liveInstances: Set<String> = []
        func enqueue(_ command: AgentCommand, for session: String, instance: String?) {
            sent.append((command, session))
            if let instance { pinned[command.id] = instance }
        }
        var sessionsOf: (String) -> [String] = { _ in [] }
        var liveCalls = 0
        func isLive(instance: String) -> Bool {
            liveCalls += 1
            return liveInstances.contains(instance) || sessionsOf(instance).contains(where: live.contains)
        }
        func withdraw(_ id: String) -> Bool {
            withdrawn.append(id)
            return true
        }
        func isLive(session: String) -> Bool {
            liveCalls += 1
            return live.contains(session)
        }
        var snapshots = 0
        func liveness(sessions: Set<String>, instances: Set<String>) -> AgentLiveness {
            snapshots += 1
            return AgentLiveness(
                sessions: sessions.intersection(live),
                instances: instances.filter { liveInstances.contains($0) || sessionsOf($0).contains(where: live.contains) })
        }
        var forgotten: [String] = []
        func forget(session: String) { forgotten.append(session) }
        var rehelloed: [String] = []
        func rehello(session: String) { rehelloed.append(session) }
        var silenced: [Set<String>] = []
        func silence(agents: Set<String>) { silenced.append(agents) }
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

        func remove(_ session: String) { entries.removeAll { $0.sessionId == session } }
    }

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1000) }
    private static let deadline = Date(timeIntervalSince1970: 1005)

    private func makeHub(
        receiptTimeout: Duration = .seconds(5), handOffLimit: Duration = .seconds(30), disconnectGrace: Duration = .seconds(30),
        checkWait: Duration = .seconds(5), clock: Clock = Clock()
    ) -> (AgentHub, FakeTransport, Registry, Notices) {
        let transport = FakeTransport()
        let registry = Registry()
        let notices = Notices()
        var counter = 0
        let hub = AgentHub(
            transport: transport, scan: { registry.entries }, receiptTimeout: receiptTimeout, handOffLimit: handOffLimit,
            checkWait: checkWait, disconnectGrace: disconnectGrace, scanDeadline: .seconds(30), now: { clock.now }
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
        #expect(await receipt == .kept("keyscribe", reason: .inPromptBox(.afterStop)))
    }

    private func working(_ features: [String] = ["readiness", "fill", "box"]) -> AgentEvent.Hello {
        .init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: features, idle: false, gap: false)
    }

    @Test func aDictationForTheWorkingConversationInFrontGoesToItsPromptBox() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1", inFront: true)
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.last.map(\.0)
            == .submit(id: "r1", expectedSession: "claude:s1", text: "use the other file", expiresAt: Self.deadline, box: true))
        hub.handle(.refused(request: "r1", reason: "filled"))
        #expect(await receipt == .kept("keyscribe", reason: .inPromptBox(.awaitingReturn)))
    }

    private func steering(_ state: String = "busy") -> AgentEvent.Hello {
        .init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0,
              features: ["readiness", "steer"], idle: false, gap: false)
    }

    @Test func aDictationForAWorkingConversationWhoseAgentSteersIsHandedOffWhereverItIs() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.last.map(\.0) == .submit(id: "r1", expectedSession: "claude:s1", text: "use the other file", expiresAt: Self.deadline))
        hub.handle(.submitted(request: "r1", turn: "t1"))
        #expect(await receipt == .sent("keyscribe"))
    }

    @Test func aConversationThatBothSteersAndTakesThePromptBoxIsTypedIntoInFrontAndSteeredElsewhere() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working(["readiness", "fill", "box", "steer"]))
        var sentBefore = transport.sent.count
        async let inFront = hub.deliver("use the other file", to: "claude:s1", inFront: true)
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.last.map(\.0)
            == .submit(id: "r1", expectedSession: "claude:s1", text: "use the other file", expiresAt: Self.deadline, box: true))
        hub.handle(.refused(request: "r1", reason: "filled"))
        #expect(await inFront == .kept("keyscribe", reason: .inPromptBox(.awaitingReturn)))

        sentBefore = transport.sent.count
        async let behind = hub.deliver("and the next one", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.last.map(\.0) == .submit(id: "r2", expectedSession: "claude:s1", text: "and the next one", expiresAt: Self.deadline))
        hub.handle(.submitted(request: "r2", turn: ""))
        #expect(await behind == .sent("keyscribe"))
    }

    @Test(arguments: [
        ("draft", AgentReceipt.kept("keyscribe", reason: .composing)),
        ("filled", AgentReceipt.kept("keyscribe", reason: .inPromptBox(.afterStop))),
        ("added", AgentReceipt.kept("keyscribe", reason: .inPromptBox(.besideText))),
        ("stopped", AgentReceipt.notSent("keyscribe", reason: .stopped)),
        ("another plugin dropped it", AgentReceipt.notSent("keyscribe", reason: .refused("another plugin dropped it"))),
    ])
    func aSteerTheConnectorLaterCannotDeliverIsReportedLateAgainstItsTake(reason: String, expected: AgentReceipt) async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        var notices: [(AgentReceipt, String)] = []
        hub.onNotice = { receipt, request, _ in notices.append((receipt, request)) }
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(await receipt == .sent("keyscribe"))

        hub.handle(.turnComplete(session: "claude:s1", reason: "aborted", answer: ""))
        hub.handle(.refused(request: "r1", reason: reason))
        #expect(notices.map(\.0) == [expected])
        #expect(notices.map(\.1) == ["r1"])

        hub.handle(.turnStarted(session: "claude:s1", turn: "t2", prompt: AgentPromptDigest.of("use the other file")))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Typed by hand."))
        #expect(origins.isEmpty)
    }

    private func claudeCode(idle: Bool) -> AgentEvent.Hello {
        .init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0,
              features: ["readiness", "fill", "check", "promptDigest", "box", "merge"], idle: idle, gap: false)
    }

    @Test func aDictationForAWorkingClaudeCodeConversationNotInFrontIsQueuedRatherThanHandedOff() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, claudeCode(idle: false))
        let sentBefore = transport.sent.count
        #expect(await hub.deliver("use the other file", to: "claude:s1", inFront: false) == .queued("keyscribe"))
        #expect(transport.sent.count == sentBefore)
    }

    @Test func aClaudeCodeTakeThatMeetsARunningTurnIsSentWhenItEndsAheadOfATakeSaidAfterIt() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        greet(hub, claudeCode(idle: true))
        let sentBefore = transport.sent.count
        async let first = hub.deliver("use the other file", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(await hub.deliver("and run the tests", to: "claude:s1") == .queued("keyscribe"))
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(await first == .queued("keyscribe"))

        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.dropFirst(sentBefore).map(\.0.id) == ["r1", "r1~1"])
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2", prompt: AgentPromptDigest.of("use the other file")))
        hub.handle(.submitted(request: "r1~1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Used it."))
        #expect(transport.sent.dropFirst(sentBefore).map(\.0.id) == ["r1", "r1~1", "r2"])
    }

    @Test(arguments: [
        ("answer", false, nil),
        ("aborted", false, AgentReceipt.kept("keyscribe", reason: .interrupted)),
        ("answer", true, AgentReceipt.kept("keyscribe", reason: .typedSince)),
        ("aborted", true, AgentReceipt.kept("keyscribe", reason: .typedSince)),
    ] as [(String, Bool, AgentReceipt?)])
    func aClaudeCodeTakeQueuedForARunningTurnIsSentWhenItEndsUnlessTheUserStoppedItOrSentAMessageMeanwhile(
        reason: String, typed: Bool, kept: AgentReceipt?
    ) async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        greet(hub, claudeCode(idle: true))
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(await receipt == .queued("keyscribe"))
        if typed { hub.handle(.typed(session: "claude:s1", prompts: 1)) }
        hub.handle(.turnComplete(session: "claude:s1", reason: reason, answer: ""))
        #expect(transport.sent.dropFirst(sentBefore).map(\.0.id) == (kept == nil ? ["r1", "r1~1"] : ["r1"]))
        #expect(notices.items == (kept.map { [$0] } ?? []))
    }

    @Test func takesLeftInOnePromptBoxAreSentWithOneReturnAndShareItsOutcome() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        var presses: [String] = []
        hub.onLeftInPromptBox = { request, _, _ in presses.append(request) }
        var notices: [(AgentReceipt, String)] = []
        hub.onNotice = { receipt, request, _ in notices.append((receipt, request)) }
        var forgotten: [String] = []
        hub.onForget = { forgotten.append($0) }
        for (index, text) in ["first", "second"].enumerated() {
            let sentBefore = transport.sent.count
            async let receipt = hub.deliver(text, to: "claude:s1")
            await untilSent(transport, sentBefore + 1)
            hub.handle(.submitted(request: "r\(index + 1)", turn: ""))
            #expect(await receipt == .sent("keyscribe"))
        }
        hub.handle(.refused(request: "r1", reason: "filled"))
        hub.handle(.refused(request: "r2", reason: "filled"))
        #expect(presses == ["r1"])

        hub.settleLeftInPromptBox("r1", in: "claude:s1", as: .kept("keyscribe", reason: .inPromptBox(.afterStop)))
        #expect(notices.map(\.1) == ["r1", "r2"])
    }

    @Test func takesLeftInOnePromptBoxThatReturnSentAreAllForgotten() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        hub.onLeftInPromptBox = { _, _, _ in }
        var forgotten: [String] = []
        hub.onForget = { forgotten.append($0) }
        for (index, text) in ["first", "second"].enumerated() {
            let sentBefore = transport.sent.count
            async let receipt = hub.deliver(text, to: "claude:s1")
            await untilSent(transport, sentBefore + 1)
            hub.handle(.submitted(request: "r\(index + 1)", turn: ""))
            _ = await receipt
        }
        hub.handle(.refused(request: "r1", reason: "filled"))
        hub.handle(.refused(request: "r2", reason: "filled"))
        hub.settleLeftInPromptBox("r1", in: "claude:s1", as: nil)
        #expect(Set(forgotten).isSuperset(of: ["r1", "r2"]))
    }

    @Test func aRefusalForATakeNeverSteeredIsIgnored() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        hub.handle(.refused(request: "r9", reason: "draft"))
        #expect(notices.isEmpty)
    }

    @Test(arguments: [
        (AgentTurnInput(from: nil, prompt: AgentPromptDigest.of("Yes to all four.")), SpokenResult.Cause.request("Yes to all four.", named: false)),
        (AgentTurnInput(from: .agent, prompt: AgentPromptDigest.of("Found a race in the cache.")), .sender(.agent)),
        (AgentTurnInput(from: nil, prompt: AgentPromptDigest.of("typed while it ran")), nil),
        (nil, nil),
    ])
    func aReplyNamesTheDictationItAnswersOnlyWhenItCameRightAfterIt(after: AgentTurnInput?, expected: SpokenResult.Cause?) async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        greet(hub, steering("idle"))
        var causes: [SpokenResult.Cause?] = []
        hub.onResult = { _, _, _, _, origin, cause in if origin == "r1" { causes.append(cause) } }
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("Yes to all four.", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        #expect(await receipt == .sent("keyscribe"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done.", after: after))
        #expect(causes == [expected])
    }

    @Test func aTurnAnExtensionsMessageStartsAfterTheDictationWasAnsweredIsNotReadAsTheDictationsReply() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        greet(hub, steering("idle"))
        var results: [(String, String?, SpokenResult.Cause?)] = []
        hub.onResult = { _, _, answer, _, origin, cause in results.append((answer, origin, cause)) }
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("Yes to all four.", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        #expect(await receipt == .sent("keyscribe"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All four are in.",
                                 after: AgentTurnInput(from: nil, prompt: AgentPromptDigest.of("Yes to all four."))))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "The disk writer is a software update.",
                                 after: AgentTurnInput(from: .other, prompt: nil)))
        #expect(results.map(\.0) == ["All four are in."])
        #expect(results.map(\.1) == ["r1"])
        #expect(results.map(\.2) == [.request("Yes to all four.", named: false)])
    }

    @Test(arguments: [(0, false, false), (AgentHub.movedOnAfter, false, true), (5, true, true)])
    func aReplyNamesItsDictationOnceTheUserHasMovedOn(waited: TimeInterval, spokeElsewhere: Bool, named: Bool) async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(clock: clock)
        await connected(hub, transport, registry)
        await connected(hub, transport, registry, "s2")
        greet(hub, steering("idle"))
        greet(hub, .init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i2", session: "claude:s2", pid: 0,
                         features: ["readiness", "steer"], idle: true, gap: false))
        var causes: [SpokenResult.Cause?] = []
        hub.onResult = { _, _, _, _, origin, cause in if origin == "r1" { causes.append(cause) } }
        var sentBefore = transport.sent.count
        async let first = hub.deliver("Yes to all four.", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        #expect(await first == .sent("keyscribe"))
        clock.now = clock.now.addingTimeInterval(waited)
        if spokeElsewhere {
            sentBefore = transport.sent.count
            async let second = hub.deliver("Update the docs.", to: "claude:s2")
            await untilSent(transport, sentBefore + 1)
            hub.handle(.submitted(request: "r2", turn: "u1"))
            _ = await second
        }
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done.",
                                 after: AgentTurnInput(from: nil, prompt: AgentPromptDigest.of("Yes to all four."))))
        #expect(causes == [.request("Yes to all four.", named: named)])
    }

    @Test func aSteerAcceptedBeforeItsTurnIsKnownIsSentAndHasTheReplyOfTheTurnThatTakesItIn() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: ""))
        #expect(await receipt == .sent("keyscribe"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Not that one."))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.absorbed(session: "claude:s1", turn: "t2", prompt: AgentPromptDigest.of("use the other file")))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Used it."))
        #expect(origins == ["r1"])
    }

    @Test func aSteeringAgentWaitingOnTheUserStillHoldsTheDictation() async {
        let (hub, transport, registry, _) = makeHub()
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        transport.live.insert("claude:s1")
        await hub.rescan()
        greet(hub, steering())
        #expect(await hub.deliver("use the other file", to: "claude:s1") == .queued("keyscribe", waitingOn: .approval))
        #expect(transport.sent.isEmpty)
    }

    @Test func aSteerNeverOvertakesADictationStillBeingHandedOff() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        let sentBefore = transport.sent.count
        async let first = hub.deliver("first", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(await hub.deliver("second", to: "claude:s1") == .queued("keyscribe"))
        #expect(transport.sent.count == sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        _ = await first
    }

    @Test func aDictationHeldBehindASteerIsSteeredOnceTheFirstIsConfirmedWithoutWaitingForTheTurn() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        let sentBefore = transport.sent.count
        async let first = hub.deliver("first", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(await hub.deliver("second", to: "claude:s1") == .queued("keyscribe"))
        hub.handle(.submitted(request: "r1", turn: "t1"))
        _ = await first
        await untilSent(transport, sentBefore + 2)
        #expect(transport.sent.last.map(\.0) == .submit(id: "r2", expectedSession: "claude:s1", text: "second", expiresAt: Self.deadline))
    }

    @Test func aDictationAddedBesideTextTheUserTypedIsKeptForThemToReview() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1", inFront: true)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "added"))
        #expect(await receipt == .kept("keyscribe", reason: .inPromptBox(.besideText)))
    }

    @Test(arguments: [
        (String?("confirm"), AgentDeliveryDecision.QueueReason.approval), ("select", .question), ("input", .question), ("editor", .question),
        ("custom", .userDialog), (nil, .userDialog),
    ])
    func aDictationHeldByAnOpenPromptSaysWhatKindOfPromptItWaitsOn(kind: String?, reason: AgentDeliveryDecision.QueueReason) async {
        let (hub, transport, registry, _) = makeHub()
        registry.set("s1", status: "waiting", waitingFor: "custom")
        transport.live.insert("claude:s1")
        await hub.rescan()
        greet(hub, working())
        hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: kind, title: "Pick one")))
        await hub.rescan()
        #expect(await hub.deliver("use the other file", to: "claude:s1") == .queued("keyscribe", waitingOn: reason))
    }

    @Test func aPromptReportedForAConversationAlreadyInADialogRefreshesItsLabelOnlyWhenThePromptChanges() async {
        let (hub, transport, registry, _) = makeHub()
        registry.set("s1", status: "waiting", waitingFor: "custom")
        transport.live.insert("claude:s1")
        await hub.rescan()
        greet(hub, working())
        await hub.rescan()
        var changes = 0
        hub.onChange = { changes += 1 }
        hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm")))
        #expect(changes == 1)
        hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm")))
        #expect(changes == 1)
        hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "select")))
        #expect(changes == 2)
    }

    enum PromptSource: String, CaseIterable, Sendable { case hello, waitingEvent }
    enum PromptRow: String, CaseIterable, Sendable { case notListed, listedNotConnected, connected }
    enum PromptDelivery: String, CaseIterable, Sendable { case alone, batchedAfterAHello, batchedBeforeARosterRead }

    struct PromptCell: Sendable, CustomTestStringConvertible {
        let source: PromptSource, row: PromptRow, delivery: PromptDelivery
        var testDescription: String { "\(source) \(row) \(delivery)" }

        static var all: [PromptCell] {
            PromptSource.allCases.flatMap { source in
                PromptRow.allCases.flatMap { row in PromptDelivery.allCases.map { PromptCell(source: source, row: row, delivery: $0) } }
            }
        }
    }

    @Test(arguments: PromptCell.all)
    func aReportedPromptHoldsTheNextDictationWhereverItsConversationStoodAndHoweverItWasBatched(_ cell: PromptCell) async {
        let (source, row, delivery) = (cell.source, cell.row, cell.delivery)
        let (hub, transport, registry, _) = makeHub()
        if row != .notListed { registry.set("s1", status: "waiting", waitingFor: "custom") }
        if row == .connected { transport.live.insert("claude:s1") }
        await hub.rescan()
        transport.live.insert("claude:s1")
        let prompt = AgentPrompt(kind: "confirm")
        var hello = working()
        if source == .hello { hello.waiting = prompt }
        hub.prepare(for: hello)
        let reported: [AgentEvent] = source == .hello ? [.hello(hello)] : [.waiting(session: "claude:s1", prompt: prompt)]
        switch delivery {
        case .alone:
            if source == .waitingEvent { hub.handle(.hello(hello)) }
            for event in reported { hub.handle(event) }
        case .batchedAfterAHello:
            hub.handle((source == .hello ? [] : [.hello(hello)]) + reported + [.shown(session: "claude:s1", on: false)])
        case .batchedBeforeARosterRead:
            hub.handle((source == .hello ? [] : [.hello(hello)]) + reported + [.typed(session: "claude:s1")])
        }
        registry.set("s1", status: "waiting", waitingFor: "custom")
        await hub.rescan()
        #expect(await hub.deliver("use the other file", to: "claude:s1") == .queued("keyscribe", waitingOn: .approval))
    }

    @Test func aPromptIsForgottenOnceItsConnectorNoLongerReadsLive() async {
        let (hub, transport, registry, _) = makeHub()
        registry.set("s1", status: "waiting", waitingFor: "custom")
        transport.live.insert("claude:s1")
        await hub.rescan()
        greet(hub, working())
        hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm")))
        transport.live.remove("claude:s1")
        await hub.rescan()
        transport.live.insert("claude:s1")
        await hub.rescan()
        #expect(await hub.deliver("use the other file", to: "claude:s1") == .queued("keyscribe", waitingOn: .userDialog))
    }

    @Test func aPromptThatArrivesWithAStateChangeIsAnnouncedOnce() async {
        let (hub, fake, _) = await twoSources(count: 20)
        fake.listing = { Self.listed($0, ["f7": .userDialog]) }
        var changes = 0
        hub.onChange = { changes += 1 }
        hub.handle(.waiting(session: "fake:f7", prompt: AgentPrompt(kind: "confirm")))
        await hub.scansSettled()
        #expect(changes == 1)
        #expect(hub.directory.conversations.first { $0.id == "fake:f7" }?.state == .userDialog)
    }

    @Test func aPromptBoxHeldByAReportedApprovalQueuesTheDictationAsWaitingForApproval() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm", tool: "bash", detail: "rm -rf build")))
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1", inFront: true)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "dialog"))
        #expect(await receipt == .queued("keyscribe", waitingOn: .approval))
    }

    @Test func aPromptBoxHeldByADialogQueuesTheDictationAsWaitingOnIt() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1", inFront: true)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "dialog"))
        #expect(await receipt == .queued("keyscribe", waitingOn: .userDialog))
    }

    @Test(arguments: [("ready", true), ("changed", false), ("asking", false)])
    func aFilledPromptBoxIsReadyOnlyWhenTheConnectorSaysSo(_ promptBox: String, _ ready: Bool) async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1", inFront: true)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "filled"))
        _ = await receipt
        async let answer = hub.promptBoxReady("r1", in: "claude:s1")
        await untilSent(transport, sentBefore + 2)
        guard case .check(let check, "claude:s1", "r1", _)? = transport.sent.last?.0 else { Issue.record("no check"); return }
        hub.handle(.checked(request: "r1", check: check, report: .init(state: .refused, reason: "filled", promptBox: promptBox)))
        #expect(await answer == ready)
    }

    @Test func aSteerTheRunningTurnTookInBeforeItsReturnWasConfirmedStillHasThatTurnsReply() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("use the other file")))
        hub.followSteer(of: "claude:s1", for: "r9", text: "use the other file")
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Used it."))
        #expect(origins == ["r9"])
    }

    final class Waits: @unchecked Sendable { var seen: [Duration] = [] }

    @Test func aLongTurnADictationStartedIsSaidToBeStillWorkingUntilItEnds() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        let waits = Waits()
        hub.sleep = { waits.seen.append($0); await Task.yield() }
        hub.stillWorkingWanted = { true }
        var cues: [String] = []
        var ended: [String] = []
        hub.onStillWorkingEnded = { ended.append($0) }
        hub.onStillWorking = { _, handle, working in
            #expect(working())
            cues.append(handle)
            if cues.count == 2 { hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done.")) }
        }
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("use the other file")))
        hub.followSteer(of: "claude:s1", for: "r9", text: "use the other file")
        for _ in 0..<500 { await Task.yield() }
        #expect(cues == ["keyscribe", "keyscribe"])
        #expect(ended == ["claude:s1"])
        #expect(Array(waits.seen.filter { [AgentHub.stillWorkingFirst, AgentHub.stillWorkingAgain].contains($0) }.prefix(2))
            == [AgentHub.stillWorkingFirst, AgentHub.stillWorkingAgain])
    }

    @Test func aTurnNoDictationStartedIsNeverSaidToBeStillWorking() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        hub.sleep = { _ in await Task.yield() }
        hub.stillWorkingWanted = { true }
        var cues = 0
        hub.onStillWorking = { _, _, _ in cues += 1 }
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        for _ in 0..<200 { await Task.yield() }
        #expect(cues == 0)
    }

    @Test func nothingWaitsForTheStillWorkingCueWhileItIsOffOrAfterTheHubStops() async {
        for stops in [false, true] {
            let (hub, transport, registry, _) = makeHub()
            await connected(hub, transport, registry, status: "busy")
            greet(hub, working())
            let waits = Waits()
            hub.sleep = { waits.seen.append($0); await Task.yield() }
            hub.stillWorkingWanted = { stops }
            var cues = 0
            hub.onStillWorking = { _, _, _ in cues += 1 }
            hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
            hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("use the other file")))
            hub.followSteer(of: "claude:s1", for: "r9", text: "use the other file")
            if stops { hub.stop() }
            for _ in 0..<200 { await Task.yield() }
            #expect(cues == 0)
            #expect(!waits.seen.contains(AgentHub.stillWorkingAgain))
        }
    }

    @Test func noStillWorkingCueWhileTheTurnWaitsForAnApproval() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        final class Gate: @unchecked Sendable { var open = false }
        let gate = Gate()
        hub.sleep = { _ in while !gate.open { await Task.yield() } }
        hub.stillWorkingWanted = { true }
        var cues = 0
        hub.onStillWorking = { _, _, _ in cues += 1 }
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("use the other file")))
        hub.followSteer(of: "claude:s1", for: "r9", text: "use the other file")
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        await hub.rescan()
        gate.open = true
        for _ in 0..<200 { await Task.yield() }
        #expect(cues == 0)
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done."))
    }

    @Test func noStillWorkingCueWhileTheTurnWaitsOnAPrompt() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        hub.sleep = { _ in await Task.yield() }
        hub.stillWorkingWanted = { true }
        var cues = 0
        hub.onStillWorking = { _, _, _ in cues += 1 }
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm", title: "Allow rm?")))
        hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("use the other file")))
        hub.followSteer(of: "claude:s1", for: "r9", text: "use the other file")
        for _ in 0..<200 { await Task.yield() }
        #expect(cues == 0)
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done."))
    }

    enum SteerReport: String, CaseIterable, Sendable { case absorbedA, absorbedB, followA, followB }

    nonisolated static let steerOrders: [[SteerReport]] = {
        func orders(_ rest: [SteerReport]) -> [[SteerReport]] {
            rest.isEmpty ? [[]] : rest.indices.flatMap { i in orders(rest.enumerated().filter { $0.offset != i }.map(\.element)).map { [rest[i]] + $0 } }
        }
        return orders(SteerReport.allCases)
    }()

    @Test(arguments: steerOrders)
    func twoSteersIntoOneTurnHaveItsReplyHeardOnceForTheOneItTookInLastWhateverOrderTheirReportsArrive(_ order: [SteerReport]) async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        for report in order {
            switch report {
            case .absorbedA: hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("use the other file")))
            case .absorbedB: hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("and keep the tests")))
            case .followA: hub.followSteer(of: "claude:s1", for: "rA", text: "use the other file")
            case .followB: hub.followSteer(of: "claude:s1", for: "rB", text: "and keep the tests")
            }
        }
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Used it and kept them."))
        let takenLast = order.firstIndex(of: .absorbedA)! > order.firstIndex(of: .absorbedB)! ? "rA" : "rB"
        #expect(origins == [takenLast])
    }

    @Test(arguments: [0, 1, 2], [true, false])
    func theReceiptOfTheDictationThatOpenedATurnNeverTakesItsReplyFromOneTheTurnTookInLater(receiptAt: Int, steerFollowedFirst: Bool) async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("explain the whole build in detail", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        var reports: [() -> Void] = [
            { hub.followSteer(of: "claude:s1", for: "r9", text: "one word: ready?") },
            { hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("one word: ready?"))) },
        ]
        if !steerFollowedFirst { reports.reverse() }
        reports.insert({ hub.handle(.submitted(request: "r1", turn: "t1")) }, at: receiptAt)
        for report in reports { report() }
        _ = await receipt
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Yes."))
        #expect(origins == ["r9"])
    }

    @Test func twoSteersWithTheSameWordsBothTakenInBeforeEitherIsFollowedHaveTheReplyHeardForTheSecond() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("yes")))
        hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("yes")))
        hub.followSteer(of: "claude:s1", for: "rFirst", text: "yes")
        hub.followSteer(of: "claude:s1", for: "rSecond", text: "yes")
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done."))
        #expect(origins == ["rSecond"])
    }

    enum SameWordsTaken: String, CaseIterable, Sendable { case first, second, firstThenSecond, secondThenFirst }

    @Test(arguments: SameWordsTaken.allCases, [true, false])
    func twoSteersWithTheSameWordsAreToldApartByTheRequestTheAgentReportsTakingIn(_ taken: SameWordsTaken, takenBeforeReceipts: Bool) async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        let order: [String] = switch taken {
        case .first: ["r1"]
        case .second: ["r2"]
        case .firstThenSecond: ["r1", "r2"]
        case .secondThenFirst: ["r2", "r1"]
        }
        let absorb = { for request in order { hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("yes"), request: request)) } }
        for request in ["r1", "r2"] {
            let sentBefore = transport.sent.count
            async let receipt = hub.deliver("yes", to: "claude:s1")
            await untilSent(transport, sentBefore + 1)
            if takenBeforeReceipts, request == "r2" { absorb() }
            hub.handle(.submitted(request: request, turn: ""))
            _ = await receipt
        }
        if !takenBeforeReceipts { absorb() }
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done."))
        #expect(origins == [order.last])
    }

    @Test func aDictationTakenIntoTheTurnAnEarlierDictationStartedHasThatTurnsReply() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, steering())
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("explain the whole build in detail", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        _ = await receipt
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var replies: [(String?, SpokenResult.Cause?)] = []
        hub.onResult = { _, _, _, _, origin, cause in replies.append((origin, cause)) }
        hub.followSteer(of: "claude:s1", for: "r9", text: "one word: ready?")
        hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("one word: ready?")))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Yes."))
        #expect(replies.map(\.0) == ["r9"])
    }

    @Test func aPromptBoxCheckNobodyAnswersIsNotReady() async {
        let (hub, transport, registry, _) = makeHub()
        hub.promptBoxCheckWait = .milliseconds(50)
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1", inFront: true)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "filled"))
        _ = await receipt
        #expect(await hub.promptBoxReady("r1", in: "claude:s1") == false)
        #expect(await hub.promptBoxReady("never-filled", in: "claude:s1") == false)
    }

    @Test func aDictationForTheWorkingConversationInFrontThatThePromptBoxTurnsAwayWaitsForTheTurn() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("use the other file", to: "claude:s1", inFront: true)
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(await receipt == .queued("keyscribe"))
    }

    @Test func aDictationForAWorkingConversationNotInFrontWaitsForTheTurn() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        #expect(await hub.deliver("use the other file", to: "claude:s1", inFront: false) == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)
    }

    @Test func aConnectorThatNeverSaidItTakesThePromptBoxIsNeverAskedTo() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working(["readiness", "fill"]))
        #expect(await hub.deliver("use the other file", to: "claude:s1", inFront: true) == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)
    }

    @Test func aConversationWaitingOnTheUserHoldsADictationEvenInFront() async {
        let (hub, transport, registry, _) = makeHub()
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        transport.live.insert("claude:s1")
        await hub.rescan()
        greet(hub, working())
        #expect(await hub.deliver("use the other file", to: "claude:s1", inFront: true) == .queued("keyscribe", waitingOn: .approval))
        #expect(transport.sent.isEmpty)
    }

    @Test func aRunningTurnWaitingForApprovalSaysTheDictationWaitsOnTheApproval() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        registry.set("s1", status: "waiting", waitingFor: "permission prompt")
        await hub.rescan()
        #expect(await hub.deliver("use the other file", to: "claude:s1", inFront: true) == .queued("keyscribe", waitingOn: .approval))
        #expect(transport.sent.isEmpty)
    }

    @Test func aDictationInFrontNeverOvertakesOneAlreadyHeldForTheConversation() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working())
        #expect(await hub.deliver("first", to: "claude:s1", inFront: false) == .queued("keyscribe"))
        #expect(await hub.deliver("second", to: "claude:s1", inFront: true) == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)
    }

    @Test func aDictationInFrontNeverOvertakesOneStillBeingHandedOff() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0,
                                features: ["readiness", "fill", "box"], idle: true, gap: false)))
        let sentBefore = transport.sent.count
        async let first = hub.deliver("first", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        #expect(await hub.deliver("second", to: "claude:s1", inFront: true) == .queued("keyscribe"))
        #expect(transport.sent.count == sentBefore + 1)
        hub.handle(.submitted(request: "r1", turn: ""))
        _ = await first
    }

    @Test func aDictationWithAnAttachedImageWaitsForTheTurnRatherThanLoseTheAttachment() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry, status: "busy")
        greet(hub, working(["readiness", "fill", "box", "images"]))
        #expect(await hub.deliver("see /tmp/a.png", to: "claude:s1", images: ["/tmp/a.png"], inFront: true) == .queued("keyscribe"))
        #expect(transport.sent.isEmpty)
    }

    @Test func onlyAConnectorThatSaidItFillsThePromptBoxCanLeaveAMessageThere() {
        #expect(AgentHub.filled(handle: "docs", features: ["focus", "fill"]) == .kept("docs", reason: .inPromptBox(.afterStop)))
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
        #expect(transport.sent.map(\.0.id) == ["r1", "r1~1"])
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(notices.items.isEmpty)
        hub.handle(.submitted(request: "r1~1", turn: ""))
        #expect(notices.items == [.sent("keyscribe")])
        #expect(notices.requests == ["r1"])
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

    private func canCheck(_ hub: AgentHub) {
        greet(hub, .init(
            protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0,
            features: ["readiness", "check"], idle: true, gap: false))
    }

    private func checks(_ transport: FakeTransport) -> [AgentCommand] {
        transport.sent.map(\.0).filter { if case .check = $0 { true } else { false } }
    }

    private func untilChecked(_ transport: FakeTransport) async {
        for _ in 0..<500 where checks(transport).isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aMissingReceiptIsCheckedBeforeDoubtAndAMessageTheCheckFindsIsSentWithItsReplyFollowed() async {
        let clock = Clock()
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20), clock: clock)
        await connected(hub, transport, registry)
        canCheck(hub)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilChecked(transport)
        #expect(checks(transport) == [.check(id: "check-r1-1", expectedSession: "claude:s1", request: "r1", expiresAt: clock.now.addingTimeInterval(5))])
        hub.handle(.checked(request: "r1", check: "check-r1-1", report: AgentDeliveryReport(state: .seen, turn: "t1")))
        #expect(await receipt == .sent("keyscribe"))
        #expect(notices.items.isEmpty)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(origins == ["r1"])
        #expect(hub.delivery(of: "r1")?.check == .answered(.seen))
    }

    @Test(arguments: [AgentDeliveryReport.State.handed, .holding, .unknown])
    func aCheckThatCannotPlaceTheMessageInTheConversationLeavesItUncertainUntilALateReceipt(_ state: AgentDeliveryReport.State) async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        canCheck(hub)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilChecked(transport)
        hub.handle(.checked(request: "r1", check: "check-r1-1", report: AgentDeliveryReport(state: state, miss: "other")))
        #expect(await receipt == .uncertain("keyscribe"))
        #expect(hub.delivery(of: "r1")?.check == .answered(state))
        #expect(hub.delivery(of: "r1")?.miss == "other")
        hub.handle(.submitted(request: "r1", turn: "t1"))
        #expect(notices.items == [.sent("keyscribe")])
    }

    @Test func aCheckThatFindsTheMessageRefusedReportsItNotSent() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        canCheck(hub)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilChecked(transport)
        hub.handle(.checked(request: "r1", check: "check-r1-1", report: AgentDeliveryReport(state: .refused, reason: "sessionChanged")))
        #expect(await receipt == .notSent("keyscribe", reason: .conversationChanged))
    }

    @Test(arguments: [
        ("typedSince", AgentReceipt.kept("keyscribe", reason: .typedSince)),
        ("draft", .kept("keyscribe", reason: .composing)),
        ("dialog", .kept("keyscribe", reason: .dialog)),
        ("filled", .notSent("keyscribe", reason: .stopped)),
        ("working", .queued("keyscribe")),
    ])
    func aRefusalACheckFindsMeansWhatTheSameRefusalMeansDirectly(_ reason: String, _ expected: AgentReceipt) async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        canCheck(hub)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilChecked(transport)
        hub.handle(.checked(request: "r1", check: "check-r1-1", report: AgentDeliveryReport(state: .refused, reason: reason)))
        #expect(await receipt == expected)
    }

    @Test func aCheckAnswerForAnEarlierAttemptNeverSettlesTheMessageSentAgain() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        canCheck(hub)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(await receipt == .queued("keyscribe"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0.id) == ["r1", "r1~1"])
        hub.handle(.checked(request: "r1", check: "check-r1-1", report: AgentDeliveryReport(state: .refused, reason: "sessionChanged")))
        hub.handle(.checked(request: "r1~1", check: "check-r1-1", report: AgentDeliveryReport(state: .refused, reason: "sessionChanged")))
        #expect(notices.items.isEmpty)
        hub.handle(.submitted(request: "r1~1", turn: "t2"))
        #expect(notices.items == [.sent("keyscribe")])
    }

    @Test(arguments: ["retired", "instanceGone"])
    func aMessageWhoseConversationIsGoneIsDoubtedWithoutAskingIt(_ reason: String) async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        canCheck(hub)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.undelivered(request: "r1", reason: reason, handedOff: true))
        #expect(await receipt == .uncertain("keyscribe"))
        #expect(checks(transport).isEmpty)
    }

    @Test func aCheckNoOneAnswersIsDoubtedOnceItsWaitEnds() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), checkWait: .milliseconds(20))
        await connected(hub, transport, registry)
        canCheck(hub)
        #expect(await hub.deliver("run the tests", to: "claude:s1") == .uncertain("keyscribe"))
        #expect(checks(transport).count == 1)
        #expect(hub.delivery(of: "r1")?.check == .unanswered)
        #expect(hub.delivery(of: "r1")?.doubted != nil)
    }

    @Test func aConnectionLostAfterTheHandOffIsCheckedAndAReceiptResentOnTheNewConnectionIsSent() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        canCheck(hub)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.undelivered(request: "r1", reason: "connectionGap", handedOff: true))
        await untilChecked(transport)
        canCheck(hub)
        hub.handle(.submitted(request: "r1", turn: "t1"))
        #expect(await receipt == .sent("keyscribe"))
        #expect(notices.items.isEmpty)
        #expect(hub.delivery(of: "r1")?.reconnects == 1)
    }

    @Test func aReceiptTimerFromAnEarlierHandOffNeverDoubtsTheMessageSentAgain() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(60))
        await connected(hub, transport, registry)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(await receipt == .queued("keyscribe"))
        try? await Task.sleep(for: .milliseconds(40))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0.id) == ["r1", "r1~1"])
        try? await Task.sleep(for: .milliseconds(35))
        #expect(hub.delivery(of: "r1")?.doubted == nil)
    }

    @Test func aDoubtedMessageFollowsTheNextTurnsReply() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        var origins: [String?] = []
        var recorded: [HistoryEntry.Fact] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        hub.onDelivery = { request, fact in if request == "r1" { recorded.append(fact) } }
        #expect(await hub.deliver("run the tests", to: "claude:s1") == .uncertain("keyscribe"))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(origins == ["r1"])
        #expect(hub.delivery(of: "r1")?.followedTurn != nil)
        #expect(recorded.last?.value.contains("so its reply is followed") == true)
    }

    @Test func aTurnThatStartedBeforeTheDoubtIsTheOneFollowed() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        #expect(await receipt == .uncertain("keyscribe"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(origins == ["r1"])
    }

    @Test func aTurnThatStartedAndEndedBeforeTheDoubtLeavesTheNextTurnUnfollowed() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(40))
        await connected(hub, transport, registry)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(await receipt == .uncertain("keyscribe"))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Someone else's."))
        #expect(origins.isEmpty)
        #expect(hub.delivery(of: "r1")?.followedTurn == nil)
    }

    @Test func aTurnIsNeverFollowedOnceACheckSaysTheMessageHasNotEnteredTheConversation() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        canCheck(hub)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        await untilChecked(transport)
        hub.handle(.checked(request: "r1", check: "check-r1-1", report: AgentDeliveryReport(state: .handed, miss: "other")))
        #expect(await receipt == .uncertain("keyscribe"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Not this one."))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t2"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Nor this."))
        #expect(origins.isEmpty)
    }

    @Test func aMessageRefusedAsWorkingIsCheckedUnderItsRetryAndARetryRefusedAgainIsQueuedAgain() async {
        let (hub, transport, registry, notices) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        canCheck(hub)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.refused(request: "r1", reason: "working"))
        #expect(await receipt == .queued("keyscribe"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        await untilChecked(transport)
        #expect(checks(transport).map { if case .check(_, _, let request, _) = $0 { request } else { "" } } == ["r1~1"])
        hub.handle(.checked(request: "r1~1", check: "check-r1-2", report: AgentDeliveryReport(state: .refused, reason: "working")))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        #expect(transport.sent.map(\.0).filter { if case .submit = $0 { true } else { false } }.map(\.id) == ["r1", "r1~1", "r1~2"])
        hub.handle(.submitted(request: "r1~2", turn: "t3"))
        #expect(notices.items.last == .sent("keyscribe"))
    }

    @Test(arguments: [true, false])
    func aMessageTheUserTypedOverBeforeItsDoubtNeverFollowsATurn(_ turnStartedFirst: Bool) async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(30))
        await connected(hub, transport, registry)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.typed(session: "claude:s1"))
        if turnStartedFirst { hub.handle(.turnStarted(session: "claude:s1", turn: "t1")) }
        #expect(await receipt == .uncertain("keyscribe"))
        if !turnStartedFirst { hub.handle(.turnStarted(session: "claude:s1", turn: "t1")) }
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "The typed message's reply."))
        #expect(origins.isEmpty)
    }

    @Test(arguments: [true, false])
    func aLateCheckSayingTheMessageNeverEnteredStopsFollowingItsTurn(_ turnStartedFirst: Bool) async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), checkWait: .milliseconds(20))
        await connected(hub, transport, registry)
        canCheck(hub)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        if turnStartedFirst { hub.handle(.turnStarted(session: "claude:s1", turn: "t1")) }
        #expect(await receipt == .uncertain("keyscribe"))
        #expect(hub.delivery(of: "r1")?.check == .unanswered)
        hub.handle(.checked(request: "r1", check: "check-r1-1", report: AgentDeliveryReport(state: .handed)))
        if !turnStartedFirst { hub.handle(.turnStarted(session: "claude:s1", turn: "t1")) }
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Someone else's."))
        #expect(origins.isEmpty)
        #expect(hub.delivery(of: "r1")?.followedTurn == nil)
    }

    @Test(arguments: [true, false])
    func aLateRefusalStopsFollowingTheTurnTheMessageWasDoubtedInto(_ throughCheck: Bool) async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), checkWait: .milliseconds(20))
        await connected(hub, transport, registry)
        canCheck(hub)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        #expect(await receipt == .uncertain("keyscribe"))
        #expect(hub.delivery(of: "r1")?.followedTurn != nil)
        if throughCheck {
            hub.handle(.checked(request: "r1", check: "check-r1-1", report: AgentDeliveryReport(state: .refused, reason: "sessionChanged")))
        } else {
            hub.handle(.refused(request: "r1", reason: "sessionChanged"))
        }
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Someone else's."))
        #expect(origins.isEmpty)
        #expect(hub.delivery(of: "r1")?.followedTurn == nil)
    }

    @Test func aLateCheckKeepsAReplyTheUserAskedToHear() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), checkWait: .milliseconds(20))
        await connected(hub, transport, registry)
        canCheck(hub)
        hub.speaks = { true }
        var results: [(Bool, String?)] = []
        hub.onResult = { _, _, _, requested, origin, _ in results.append((requested, origin)) }
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        #expect(await receipt == .uncertain("keyscribe"))
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        hub.handle(.checked(request: "r1", check: "check-r1-1", report: AgentDeliveryReport(state: .handed)))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Asked for."))
        #expect(results.map(\.0) == [true])
        #expect(results.map(\.1) == [nil])
    }

    @Test func aConnectorsTurnEndIsHeardWhateverTurnIdItCarries() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.speaks = { true }
        var answers: [String] = []
        hub.onResult = { _, _, answer, _, _, _ in answers.append(answer) }
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        _ = hub.notify(session: "claude:s1", turn: "t1", on: true)
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Done.", after: nil, turn: "another"))
        #expect(answers == ["Done."])
    }

    @Test func aTurnTheUserTypedAfterADoubtedMessageIsNotFollowed() async {
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20))
        await connected(hub, transport, registry)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        #expect(await hub.deliver("run the tests", to: "claude:s1") == .uncertain("keyscribe"))
        hub.handle(.typed(session: "claude:s1"))
        hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "All green."))
        #expect(origins.isEmpty)
    }

    @Test func theDeliveryRecordsTheHandOffWhatTheConnectorSawItsConfirmationAndReconnects() async {
        let clock = Clock()
        let start = clock.now
        let (hub, transport, registry, _) = makeHub(clock: clock)
        await connected(hub, transport, registry)
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, 1)
        clock.now = start.addingTimeInterval(0.5)
        greet(hub, ready(gap: false))
        clock.now = start.addingTimeInterval(1)
        hub.handle(.submitted(request: "r1", turn: "", report: AgentDeliveryReport(
            handedAt: start.addingTimeInterval(0.1), seenAt: start.addingTimeInterval(0.2))))
        _ = await receipt
        let delivery = hub.delivery(of: "r1")
        #expect(delivery?.handedOff == start)
        #expect(delivery?.handedToAgent == start.addingTimeInterval(0.1))
        #expect(delivery?.entered == start.addingTimeInterval(0.2))
        #expect(delivery?.confirmed == start.addingTimeInterval(1))
        #expect(delivery?.reconnects == 1)
        #expect(hub.deliveryFact(of: "r1")?.label == "Delivery")
    }

    private func dictated(_ hub: AgentHub, _ transport: FakeTransport, turn: String = "t1") async {
        let sentBefore = transport.sent.count
        async let receipt = hub.deliver("run the tests", to: "claude:s1")
        await untilSent(transport, sentBefore + 1)
        if case .submit(let id, _, _, _, _, _, _, _) = transport.sent.last?.0 { hub.handle(.submitted(request: id, turn: turn)) }
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
        if case .submit(let id, _, _, _, _, _, _, _) = transport.sent.last?.0 { hub.handle(.refused(request: id, reason: "stopped")) }
        #expect(await receipt == .notSent("keyscribe", reason: .stopped))
    }

    @Test func aStoppedHubReportsNoResultOrNoticeForLaterEvents() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        var reported: [String] = []
        hub.onResult = { _, _, _, _, _, _ in reported.append("result") }
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
        hub.onResult = { conversation, handle, value, _, _, _ in results.append("\(conversation)|\(handle)|\(value)") }
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
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
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
        hub.onResult = { _, _, answer, _, origin, _ in results.append("\(answer)|\(origin ?? "-")") }
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
        hub.onResult = { _, _, answer, _, _, _ in results.append(answer) }
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
        hub.onResult = { _, _, value, _, _, _ in results.append(value) }
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
        hub.onResult = { _, _, value, _, _, _ in results.append(value) }
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
        hub.onResult = { _, _, value, _, _, _ in results.append(value) }
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
        hub.onResult = { _, _, value, _, _, _ in results.append(value) }
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
        hub.onResult = { _, _, value, _, _, _ in results.append(value) }
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
        hub.onResult = { _, _, value, _, _, _ in results.append(value) }
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

    @Test func aNameTheUserChoseInAnOlderSpellingSurvivesALoadAndASave() async throws {
        let dir = try nameDir(#"{"schema_version": 1, "names": {"claude:a": "Build 2"}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        registry.set("b", cwd: "/src/web")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(hub.names["build two"] == "claude:a")
        try hub.rename("claude:b", to: "web")
        guard case .names(let saved, _, _) = AgentNameStore(directory: dir).load() else { Issue.record("names unreadable"); return }
        #expect(saved["claude:a"] == "build two")
    }

    @Test func aRecipientSavedByAnEarlierVersionIsIgnoredAndDroppedOnTheNextSave() async throws {
        let dir = try nameDir(#"{"schema_version": 1, "names": {"claude:a": "backend"}, "chosen": {"id": "claude:a", "name": "backend"}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(AgentNameStore.fileName)
        let registry = Registry()
        registry.set("a", cwd: "/src/api")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(hub.namesProblem == nil)
        #expect(hub.names == ["backend": "claude:a"])
        try hub.rename("claude:a", to: "api server")
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("chosen"))
        #expect(saved.contains("api server"))
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
        hub.noteUsed("claude:s2")
        #expect(hub.recordingOrder.map(\.id) == ["claude:s2", "claude:s3", "claude:s1"])
        clock.now += 1
        _ = await hub.deliver("run the tests", to: "claude:s1")
        #expect(hub.recordingOrder.map(\.id) == ["claude:s1", "claude:s2", "claude:s3"])
    }

    @Test func aConversationStartedAfterTheLastUseLeadsTheRecordingList() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(receiptTimeout: .milliseconds(20), clock: clock)
        registry.set("s1", cwd: "/src/alpha", pid: 10, startedAt: 100_000)
        registry.set("s2", cwd: "/src/bravo", pid: 20, startedAt: 200_000)
        transport.live.formUnion(["claude:s1", "claude:s2"])
        await hub.rescan()
        _ = await hub.deliver("run the tests", to: "claude:s1")
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

    @Test func theNameARenameReplacedStillReachesTheConversationAfterARestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = Registry()
        registry.set("a", pid: 10, startedAt: 100)
        let first = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await first.rescan()
        try first.rename("claude:a", to: "falcon")

        let second = AgentHub(transport: FakeTransport(), scan: { registry.entries }, names: AgentNameStore(directory: dir), scanDeadline: .seconds(30))
        await second.rescan()
        #expect(second.names == ["falcon": "claude:a"])
        #expect(second.formerNames == ["keyscribe": "claude:a"])
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
        var running = false
        private(set) var runningChecks = 0
        func stillRunning(_ remembered: RememberedName) -> Bool {
            runningChecks += 1
            return running
        }
        func observe(_ event: AgentEvent) { observed.append(event) }
        var listing: ((String) -> AgentSession?)?
        private(set) var listedCalls = 0
        private(set) var reconciled = 0
        func listed(_ native: String) -> AgentSession? {
            listedCalls += 1
            return listing?(native)
        }
        func current(_ sessions: [AgentSession]) -> [AgentSession] {
            reconciled += 1
            return sessions.map { listing?($0.id) ?? $0 }
        }
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

    @Test func aDisconnectedConversationKeepsItsNameAndItsHeldMessagesAreNotSent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-ex-\(UUID().uuidString)")
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let transport = FakeTransport()
        transport.live = ["fake:f1"]
        let hub = AgentHub(transport: transport, discovery: [fake], names: AgentNameStore(directory: dir))
        await hub.rescan()
        var forgotten: [String] = []
        hub.onSilence = { forgotten.append($0) }
        hub.disconnect("fake:f1")
        #expect(hub.directory.conversations.isEmpty)
        #expect(hub.disconnected.map(\.id) == ["fake:f1"])
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
        hub.onResult = { _, _, answer, _, _, _ in results.append(answer) }
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

    @Test func aRefreshAndARescanAskTheBridgeAboutLivenessOnceWhateverTheRosterSize() async {
        let (hub, transport, registry, _) = makeHub()
        for i in 0..<50 {
            registry.set("s\(i)", cwd: "/src/project\(i)", pid: 100 + i)
            transport.live.insert("claude:s\(i)")
            transport.liveInstances.insert("i\(i)")
        }
        await hub.rescan()
        hub.handle((0..<50).map { i in
            .hello(.init(protocolVersion: 3, agent: "claude", agentVersion: "", instance: "i\(i)", session: "claude:s\(i)", pid: 100 + i,
                         features: ["label", "readiness"], connection: "i\(i)"))
        })
        await hub.rescan()
        transport.liveCalls = 0
        transport.snapshots = 0

        hub.refresh()
        #expect(transport.liveCalls == 0)
        #expect(transport.snapshots == 1)
        await hub.rescan()
        #expect(transport.liveCalls == 0)
        #expect(transport.snapshots == 2)
    }

    private func twoSources(count: Int = 200) async -> (AgentHub, FakeDiscovery, FakeDiscovery) {
        let fake = FakeDiscovery()
        let other = FakeDiscovery(kind: AgentKind(id: "other", displayName: "Other", connectorName: "Other connector"))
        let transport = FakeTransport()
        let hub = AgentHub(transport: transport, discovery: [fake, other])
        fake.result = .found((0..<count).map { AgentSession(agent: "fake", id: "f\($0)", pid: 1000 + $0, cwd: "/src/f\($0)", state: .idle) })
        other.result = .found((0..<count).map { AgentSession(agent: "other", id: "o\($0)", pid: 5000 + $0, cwd: "/src/o\($0)", state: .idle) })
        transport.live = Set((0..<count).map { "fake:f\($0)" } + (0..<count).map { "other:o\($0)" })
        await hub.rescan()
        return (hub, fake, other)
    }

    enum ScanTiming: String, CaseIterable, Sendable { case beforeTheFirstRoundStarts, whileTheFirstRoundRuns }
    enum ScanRequests: String, CaseIterable, Sendable {
        case oneThenAnother, oneThenAll, allThenOne, oneThenTheSame

        var first: Set<String>? { self == .allThenOne ? nil : ["fake"] }
        var second: Set<String>? {
            switch self {
            case .oneThenAnother, .allThenOne: ["other"]
            case .oneThenAll: nil
            case .oneThenTheSame: ["fake"]
            }
        }
    }

    @Test(arguments: ScanTiming.allCases, ScanRequests.allCases)
    func everyRescanAskedForScansItsSourcesAfterItWasAsked(_ timing: ScanTiming, _ requests: ScanRequests) async {
        let (hub, fake, other) = await twoSources(count: 3)
        if timing == .whileTheFirstRoundRuns { fake.blocked = true }
        let first = Task { @MainActor in await hub.rescan(rereadingTitles: false, agents: requests.first) }
        if timing == .whileTheFirstRoundRuns {
            await waitUntil { fake.scans > 1 }
        }
        let asked = (fake: fake.scans, other: other.scans)
        let second = Task { @MainActor in await hub.rescan(rereadingTitles: false, agents: requests.second) }
        await Task.yield()
        fake.blocked = false
        await first.value
        await second.value
        let wanted = requests.second ?? ["fake", "other"]
        if wanted.contains("fake") { #expect(fake.scans > asked.fake) }
        if wanted.contains("other") { #expect(other.scans > asked.other) }
    }

    private func waitUntil(_ done: @MainActor () -> Bool) async {
        let until = Date().addingTimeInterval(5)
        while !done(), Date() < until { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(done())
    }

    enum OneConversationEvent: String, CaseIterable, Sendable { case turnStarted, turnComplete, waiting }

    private func event(_ kind: OneConversationEvent, _ session: String) -> AgentEvent {
        switch kind {
        case .turnStarted: .turnStarted(session: session, turn: "t1")
        case .turnComplete: .turnComplete(session: session, reason: "answer", answer: "Done.")
        case .waiting: .waiting(session: session, prompt: nil)
        }
    }

    @Test(arguments: OneConversationEvent.allCases)
    func aScanThatStartedBeforeAnEventNeverPutsBackTheStateTheEventReplaced(_ kind: OneConversationEvent) async {
        let (hub, fake, other) = await twoSources(count: 10)
        let before: AgentLiveState = kind == .turnStarted ? .idle : .working
        let after: AgentLiveState = kind == .turnStarted ? .working : .idle
        var state = before
        fake.result = .found((0..<10).map { AgentSession(agent: "fake", id: "f\($0)", pid: 1000 + $0, cwd: "/src/f\($0)", state: $0 == 7 ? before : .idle) })
        fake.listing = { native in
            AgentSession(agent: "fake", id: native, pid: 1000 + (Int(native.dropFirst()) ?? 0), cwd: "/src/\(native)", state: native == "f7" ? state : .idle)
        }
        other.blocked = true
        let round = Task { @MainActor in await hub.rescan(rereadingTitles: false) }
        await waitUntil { other.scans > 1 }
        state = after
        hub.handle(event(kind, "fake:f7"))
        other.blocked = false
        await round.value
        await hub.scansSettled()
        #expect(hub.directory.conversations.first { $0.id == "fake:f7" }?.state == after)
    }

    @Test func aScanOfHundredsOfConversationsIsReconciledWithItsSourceOncePerRound() async {
        let (hub, fake, _) = await twoSources(count: 400)
        let (calls, reconciled) = (fake.listedCalls, fake.reconciled)
        await hub.rescan(rereadingTitles: false)
        #expect(fake.listedCalls == calls)
        #expect(fake.reconciled == reconciled + 1)
    }

    @Test(arguments: OneConversationEvent.allCases)
    func anEventAboutOneConversationListedFromMemoryScansNoSource(_ kind: OneConversationEvent) async {
        let (hub, fake, other) = await twoSources()
        fake.listing = { native in
            AgentSession(agent: "fake", id: native, pid: 1000 + (Int(native.dropFirst()) ?? 0), cwd: "/src/\(native)",
                         state: native == "f7" && kind == .turnStarted ? .working : .idle)
        }
        let (fakeScans, otherScans) = (fake.scans, other.scans)
        hub.handle(event(kind, "fake:f7"))
        await hub.scansSettled()
        #expect(fake.scans == fakeScans)
        #expect(other.scans == otherScans)
        #expect(hub.directory.conversations.first { $0.id == "fake:f7" }?.state == (kind == .turnStarted ? .working : .idle))
    }

    @Test(arguments: OneConversationEvent.allCases)
    func anEventAboutOneConversationScansOnlyTheSourceThatListsIt(_ kind: OneConversationEvent) async {
        let (hub, fake, other) = await twoSources()
        let (fakeScans, otherScans) = (fake.scans, other.scans)
        hub.handle(event(kind, "fake:f7"))
        await hub.scansSettled()
        #expect(fake.scans == fakeScans + 1)
        #expect(other.scans == otherScans)
    }

    private static func listed(_ native: String, _ states: [String: AgentLiveState], named names: [String: String] = [:]) -> AgentSession {
        let number = Int(native.dropFirst()) ?? 0
        return AgentSession(
            agent: "fake", id: native, pid: 1000 + number, cwd: "/src/\(native)", explicitName: names[native], state: states[native] ?? .idle)
    }

    @Test(arguments: OneConversationEvent.allCases)
    func aTurnEventThatChangesOnlyOneConversationsStateChangesItsRowWithoutRenamingTheRoster(_ kind: OneConversationEvent) async {
        let (hub, fake, _) = await twoSources(count: 400)
        let before: AgentLiveState = kind == .turnComplete ? .working : .idle
        let after: AgentLiveState = switch kind {
        case .turnStarted: .working
        case .turnComplete: .idle
        case .waiting: .waitingQuestion
        }
        var states = ["f7": before]
        fake.listing = { Self.listed($0, states) }
        fake.result = .found((0..<400).map { Self.listed("f\($0)", states) })
        await hub.rescan()
        var changes = 0
        hub.onChange = { changes += 1 }
        let (rebuilds, handles) = (hub.rosterRebuilds, hub.directory.handles)
        states["f7"] = after
        hub.handle(event(kind, "fake:f7"))
        await hub.scansSettled()
        #expect(hub.rosterRebuilds == rebuilds)
        #expect(changes == 1)
        #expect(hub.directory.conversations.first { $0.id == "fake:f7" }?.state == after)
        #expect(hub.directory.handles == handles)
        await hub.rescan()
        #expect(hub.rosterRebuilds == rebuilds)
    }

    @Test func aScanThatChangesHundredsOfStatesTogetherChangesThoseRowsWithoutRenamingTheRoster() async {
        let (hub, fake, _) = await twoSources(count: 400)
        let rebuilds = hub.rosterRebuilds
        let states = Dictionary(uniqueKeysWithValues: (0..<300).map { ("f\($0)", AgentLiveState.working) })
        fake.result = .found((0..<400).map { Self.listed("f\($0)", states) })
        await hub.rescan()
        #expect(hub.rosterRebuilds == rebuilds)
        #expect(hub.directory.conversations.filter { $0.agent == "fake" && $0.state == .working }.count == 300)
    }

    @Test func aBurstOfHellosHandledTogetherSettlesAttentionOnce() async {
        let (hub, _, _) = await twoSources(count: 300)
        let passes = hub.attentionPasses
        hub.handle((0..<300).flatMap { i -> [AgentEvent] in [
            .hello(.init(protocolVersion: 3, agent: "fake", agentVersion: "", instance: "i\(i)", session: "fake:f\(i)", pid: 1000 + i)),
            .shown(session: "fake:f\(i)", on: false),
        ] })
        #expect(hub.attentionPasses == passes + 1)
    }

    @Test func aTurnEventWhoseListingAlsoChangedANameRebuildsTheRoster() async {
        let (hub, fake, _) = await twoSources(count: 20)
        var names: [String: String] = [:]
        fake.listing = { Self.listed($0, ["f7": .working], named: names) }
        let rebuilds = hub.rosterRebuilds
        names["f7"] = "release notes"
        hub.handle(.turnStarted(session: "fake:f7", turn: "t1"))
        await hub.scansSettled()
        #expect(hub.rosterRebuilds == rebuilds + 1)
        #expect(hub.handle(of: "fake:f7") == "release notes")
        #expect(hub.directory.conversations.first { $0.id == "fake:f7" }?.state == .working)
    }

    @Test func aStateChangeAfterARenameRebuildsTheRosterSoTheRenameStays() async throws {
        let (hub, fake, _) = await twoSources(count: 20)
        var states: [String: AgentLiveState] = [:]
        fake.listing = { Self.listed($0, states) }
        try hub.rename("fake:f7", to: "docs")
        let rebuilds = hub.rosterRebuilds
        states["f7"] = .working
        hub.handle(.turnStarted(session: "fake:f7", turn: "t1"))
        await hub.scansSettled()
        #expect(hub.rosterRebuilds == rebuilds + 1)
        #expect(hub.handle(of: "fake:f7") == "docs")
        #expect(hub.directory.conversations.first { $0.id == "fake:f7" }?.state == .working)
    }

    enum ListingStep: String, CaseIterable, Sendable {
        case f1Starts, f2Ends, f3Waits, f4Renamed

        var session: String {
            switch self {
            case .f1Starts: "fake:f1"
            case .f2Ends: "fake:f2"
            case .f3Waits: "fake:f3"
            case .f4Renamed: "fake:f4"
            }
        }

        var event: AgentEvent {
            switch self {
            case .f1Starts, .f4Renamed: .turnStarted(session: session, turn: "t1")
            case .f2Ends: .turnComplete(session: session, reason: "answer", answer: "Done.")
            case .f3Waits: .waiting(session: session, prompt: nil)
            }
        }

        func apply(_ states: inout [String: AgentLiveState], _ names: inout [String: String]) {
            switch self {
            case .f1Starts: states["f1"] = .working
            case .f2Ends: states["f2"] = .idle
            case .f3Waits: states["f3"] = .waitingQuestion
            case .f4Renamed:
                states["f4"] = .working
                names["f4"] = "release notes"
            }
        }

        static var orders: [[ListingStep]] {
            func permutations(_ steps: [ListingStep]) -> [[ListingStep]] {
                guard !steps.isEmpty else { return [[]] }
                return steps.indices.flatMap { i in
                    permutations(Array(steps[..<i] + steps[(i + 1)...])).map { [steps[i]] + $0 }
                }
            }
            return permutations(allCases)
        }
    }

    @Test(arguments: ListingStep.orders)
    func rowsChangedOneEventAtATimeMatchTheRosterAFreshScanBuilds(_ order: [ListingStep]) async {
        var states: [String: AgentLiveState] = ["f2": .working]
        var names: [String: String] = [:]
        let fake = FakeDiscovery()
        let transport = FakeTransport()
        transport.live = Set((0..<8).map { "fake:f\($0)" })
        let hub = AgentHub(transport: transport, discovery: [fake])
        fake.result = .found((0..<8).map { Self.listed("f\($0)", states) })
        fake.listing = { Self.listed($0, states, named: names) }
        await hub.rescan()
        for step in order {
            step.apply(&states, &names)
            hub.handle(step.event)
            await hub.scansSettled()
        }

        let fresh = FakeDiscovery()
        let freshTransport = FakeTransport()
        freshTransport.live = transport.live
        let rebuilt = AgentHub(transport: freshTransport, discovery: [fresh])
        fresh.result = .found((0..<8).map { Self.listed("f\($0)", states, named: names) })
        await rebuilt.rescan()
        #expect(hub.directory.conversations == rebuilt.directory.conversations)
    }

    @Test func aHelloScansOnlyTheSourceItsConversationBelongsTo() async {
        let (hub, fake, other) = await twoSources()
        let (fakeScans, otherScans) = (fake.scans, other.scans)
        hub.handle(.hello(.init(protocolVersion: 3, agent: "other", agentVersion: "", instance: "i1", session: "other:o3", pid: 5003, title: "task")))
        await hub.scansSettled()
        #expect(other.scans == otherScans + 1)
        #expect(fake.scans == fakeScans)
    }

    @Test func aBurstOfHellosHandledTogetherRebuildsTheRosterAndRescansOnce() async {
        let fake = FakeDiscovery()
        let transport = FakeTransport()
        let hub = AgentHub(transport: transport, discovery: [fake])
        let count = 300
        fake.result = .found((0..<count).map { i in
            AgentSession(agent: "fake", id: "f\(i)", pid: 1000 + i, cwd: "/src/project\(i)", state: .idle)
        })
        transport.live = Set((0..<count).map { "fake:f\($0)" })
        await hub.rescan()
        let scansBefore = fake.scans
        var changes = 0
        hub.onChange = { changes += 1 }

        hub.handle((0..<count).flatMap { i -> [AgentEvent] in [
            .hello(.init(protocolVersion: 3, agent: "fake", agentVersion: "", instance: "i\(i)", session: "fake:f\(i)", pid: 1000 + i, title: "task")),
            .title(session: "fake:f\(i)", text: "task \(i)"),
            .shown(session: "fake:f\(i)", on: false),
        ] })
        for _ in 0..<200 { await Task.yield() }

        #expect(changes == 1)
        #expect(fake.scans == scansBefore + 1)
        #expect(hub.handle(of: "fake:f7") == "task seven")
    }

    @Test func aTitleThatRepeatsTheOneAlreadyKnownStartsNoRebuildOrRescan() async {
        let fake = FakeDiscovery()
        let transport = FakeTransport()
        let hub = AgentHub(transport: transport, discovery: [fake])
        fake.result = .found([Self.fakeSession("f1")])
        transport.live = ["fake:f1"]
        await hub.rescan()
        hub.handle(.title(session: "fake:f1", text: "release notes"))
        for _ in 0..<100 { await Task.yield() }
        let rebuilds = hub.rosterRebuilds, scans = fake.scans
        hub.handle(.title(session: "fake:f1", text: "release notes"))
        for _ in 0..<100 { await Task.yield() }
        #expect(hub.rosterRebuilds == rebuilds)
        #expect(fake.scans == scans)
        hub.handle(.title(session: "fake:f1", text: "docs"))
        for _ in 0..<100 { await Task.yield() }
        #expect(hub.handle(of: "fake:f1") == "docs")
    }

    @Test func aRefreshWithNothingNewLeavesTheRosterUnbuiltUntilSomethingChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try AgentNameStore(directory: dir).save([:], remembered: [
            "fake:gone": RememberedName(name: "old work", pid: 5, startedAt: 1, native: nil, agent: "fake"),
        ])
        let fake = FakeDiscovery()
        fake.running = true
        let transport = FakeTransport()
        let hub = AgentHub(transport: transport, discovery: [fake], names: AgentNameStore(directory: dir))
        fake.result = .found([Self.fakeSession("f1")])
        transport.live = ["fake:f1"]
        await hub.rescan()
        let checks = fake.runningChecks
        #expect(checks > 0)

        let rebuilds = hub.rosterRebuilds
        hub.refresh()
        await hub.rescan()
        #expect(hub.rosterRebuilds == rebuilds)
        #expect(hub.directory.remembered["fake:gone"] != nil)

        let checksBeforeRelease = fake.runningChecks
        fake.running = false
        await hub.rescan()
        #expect(hub.rosterRebuilds == rebuilds + 1)
        #expect(fake.runningChecks == checksBeforeRelease + 1)
        #expect(hub.directory.remembered["fake:gone"] == nil)

        var second = Self.fakeSession("f2")
        second.pid = 11
        fake.result = .found([Self.fakeSession("f1"), second])
        await hub.rescan()
        #expect(fake.runningChecks > checks)
        #expect(hub.handle(of: "fake:f2") != nil)
    }

    @Test func aTitleRightAfterItsHelloIsSettledWithItInOneRebuild() async {
        let fake = FakeDiscovery()
        let transport = FakeTransport()
        let hub = AgentHub(transport: transport, discovery: [fake])
        fake.result = .found([Self.fakeSession("f1")])
        transport.live = ["fake:f1"]
        await hub.rescan()
        var handles: [String?] = []
        hub.onChange = { handles.append(hub.handle(of: "fake:f1")) }

        hub.handle([
            .hello(.init(protocolVersion: 3, agent: "fake", agentVersion: "", instance: "i1", session: "fake:f1", pid: 10, title: "docs")),
            .title(session: "fake:f1", text: "release notes"),
        ])

        #expect(handles == ["release notes"])
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
        let waits = RequestedWaits()
        hub.sleep = { await waits.record($0); try await Task.sleep(for: $0) }
        let started = ContinuousClock.now
        await hub.rescan()
        #expect(await waits.all == [.milliseconds(50)])
        #expect(ContinuousClock.now - started < .seconds(30))
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

    @Test func aLiveConnectorWithoutFocusIsUnsupportedWhenTheAppBundlesNoConnectorForItsAgent() async {
        let fake = FakeDiscovery()
        fake.result = .found([Self.fakeSession("f1")])
        let transport = FakeTransport()
        transport.live = ["fake:f1"]
        let hub = AgentHub(transport: transport, discovery: [fake])
        await hub.rescan()
        hub.handle(.hello(.init(protocolVersion: 1, agent: "fake", agentVersion: "", instance: "i1", session: "fake:f1", pid: 10)))
        #expect(await hub.focusInPlace("fake:f1", definition: "cmux") == .unsupported)
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

    @Test func openingHandsTheStopCheckToTheTerminalFocus() async {
        let focus = FakeFocus()
        let registry = Registry()
        registry.set("s1")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus, scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(await hub.open("claude:s1", stillWanted: { false }) == .exact)
        #expect(focus.wanted == [false])
    }

    @Test func openingBringsTheConversationsTerminalForward() async {
        let focus = FakeFocus()
        let registry = Registry()
        registry.set("s1")
        let hub = AgentHub(transport: FakeTransport(), scan: { registry.entries }, focus: focus, scanDeadline: .seconds(30))
        await hub.rescan()
        #expect(await hub.open("claude:s1") == .exact)
        #expect(focus.focused.map(\.0) == ["claude:s1"])
        #expect(focus.focused.map(\.1) == [10])
    }

    private func focusHello(_ session: String = "claude:s1") -> AgentEvent {
        .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: session, pid: 0, features: ["focus", "focusDefinitions"]))
    }

    @Test func aConnectorThatAnnouncedFocusIsAskedToRunTheNamedFocusBeforeTheRequestExpires() async {
        let clock = Clock()
        let (hub, transport, registry, _) = makeHub(clock: clock)
        await connected(hub, transport, registry)
        hub.handle(focusHello())
        let sentBefore = transport.sent.count
        async let answer = hub.focusInPlace("claude:s1", definition: "mux")
        await untilSent(transport, sentBefore + 1)
        #expect(transport.sent.map(\.0) == [.focus(id: "r1", expectedSession: "claude:s1", expiresAt: clock.now.addingTimeInterval(3), definition: "mux")])
        hub.handle(.focused(request: "r1"))
        #expect(await answer == .selected)
    }

    @Test(arguments: ["cmux", "mux"])
    func aConnectorFromBeforeNamedFocusIsNeverAskedAndSaysItNeedsAnUpdate(definition: String) async {
        let (hub, transport, registry, _) = makeHub()
        hub.bundledVersion = { _ in "v2" }
        await connected(hub, transport, registry)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: ["focus"], codeVersion: "v1")))
        #expect(await hub.focusInPlace("claude:s1", definition: definition) == .outdated)
        #expect(transport.sent.isEmpty)
    }

    @Test func aRunningConnectorLoadedBeforeAFocusWasAddedSaysItNeedsAReload() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(focusHello())
        let sentBefore = transport.sent.count
        async let answer = hub.focusInPlace("claude:s1", definition: "mux")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "unknownFocus"))
        #expect(await answer == .outdated)
        #expect(notices.items.isEmpty)
    }

    @Test func aLiveConnectorThatCannotFocusIsNeverAskedAndSaysItNeedsAnUpdate() async {
        let (hub, transport, registry, _) = makeHub()
        hub.bundledVersion = { _ in "v2" }
        await connected(hub, transport, registry)
        hub.handle(hello("claude:s1"))
        #expect(await hub.focusInPlace("claude:s1", definition: "cmux") == .outdated)
        #expect(transport.sent.isEmpty)
    }

    @Test func aConnectorAsNewAsTheBundledOneThatCannotFocusIsUnsupportedNotOutdated() async {
        let (hub, transport, registry, _) = makeHub()
        hub.bundledVersion = { agent in agent == "claude" ? "v2" : nil }
        await connected(hub, transport, registry)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: ["focus"], codeVersion: "v2")))
        #expect(await hub.focusInPlace("claude:s1", definition: "cmux") == .unsupported)
        #expect(transport.sent.isEmpty)
    }

    @Test func aConversationWhoseConnectorNeverConnectedIsNotAsked() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        transport.live = []
        #expect(await hub.focusInPlace("claude:s1", definition: "cmux") == .notFound)
        #expect(transport.sent.isEmpty)
    }

    @Test func aRefusedFocusIsNotFoundAndNeverReadsAsADeliveryReceipt() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(focusHello())
        let sentBefore = transport.sent.count
        async let refused = hub.focusInPlace("claude:s1", definition: "cmux")
        await untilSent(transport, sentBefore + 1)
        hub.handle(.refused(request: "r1", reason: "notInPlace"))
        #expect(await refused == .notFound)
        #expect(notices.items.isEmpty)
    }

    @Test func anUnansweredFocusIsWithdrawnAndALateAnswerChangesNothing() async {
        let (hub, transport, registry, notices) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(focusHello())
        #expect(await hub.focusInPlace("claude:s1", definition: "cmux", within: .milliseconds(20)) == .notFound)
        #expect(transport.withdrawn == ["r1"])
        hub.handle(.focused(request: "r1"))
        #expect(notices.items.isEmpty)
    }

    @Test func aCancelledFocusIsWithdrawnAtOnce() async {
        let (hub, transport, registry, _) = makeHub()
        await connected(hub, transport, registry)
        hub.handle(focusHello())
        let task = Task { await hub.focusInPlace("claude:s1", definition: "cmux", within: .seconds(30)) }
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
        let roster = AgentRoster(frozen: frozenConversations, live: hub.directory.conversations, focused: "claude:s1")
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

    @Test func aConversationRunningAnOlderConnectorIsToldHowToReloadItInItsLabelUntilItReloads() async throws {
        let (hub, transport, registry, _) = makeHub()
        hub.bundledVersion = { $0 == "claude" ? "v2" : nil }
        await connected(hub, transport, registry)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: ["label"], codeVersion: "v1")))
        await hub.rescan()
        #expect(labels(transport).last == "\u{201C}keyscribe\u{201D} \u{00B7} Update: /reload-plugins")
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: ["label"], codeVersion: "v2")))
        await hub.rescan()
        #expect(labels(transport).last == "\u{201C}keyscribe\u{201D}")
    }

    @Test func aConnectorFromBeforeItReportedItsOwnCodeIsOlder() async throws {
        let (hub, transport, registry, _) = makeHub()
        hub.bundledVersion = { $0 == "claude" ? "v2" : nil }
        await connected(hub, transport, registry)
        hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: ["label"])))
        await hub.rescan()
        #expect(labels(transport).last == "\u{201C}keyscribe\u{201D} \u{00B7} Update: /reload-plugins")
        #expect(hub.olderConnectors == ["claude:s1"])
        #expect(await hub.focusInPlace("claude:s1", definition: "cmux") == .outdated)
    }

    @Test func aLongNameIsCutSoTheReloadStepStillFits() {
        #expect(AgentHub.footerLabel("the quarterly budget review notes", reload: "/reload") == "\u{201C}the quarterly budget\u{2026}\u{201D} \u{00B7} Update: /reload")
        #expect(AgentHub.footerLabel("the quarterly budget review notes", reload: nil) == "\u{201C}the quarterly budget review notes\u{201D}")
        #expect(AgentHub.footerLabel("docs", reload: "/reload") == "\u{201C}docs\u{201D} \u{00B7} Update: /reload")
    }

    @Test func anAgentWithNoReloadCommandIsToldHowToRestartItsConversation() {
        #expect(AgentHub.updateStep(.claude) == "/reload-plugins")
        #expect(AgentHub.updateStep(.omp) == "restart with omp --resume")
        #expect(AgentHub.footerLabel("docs", reload: AgentHub.updateStep(.omp)) == "\u{201C}docs\u{201D} \u{00B7} Update: restart with omp --resume")
        #expect(AgentHub.updateStep(AgentKind(id: "other", displayName: "Other", connectorName: "Other connector")) == "restart")
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
            transcriptTitles: ClaudeTranscriptTitles(configDirs: [dir]), scanDeadline: .seconds(30))
        registry.set("s1")
        await hub.rescan(rereadingTitles: false)
        #expect(hub.directory.conversations.first?.title == "First")

        clock.now += 1
        try Data(#"{"type":"ai-title","aiTitle":"Second","sessionId":"claude:s1"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: clock.now], ofItemAtPath: file.path)
        await hub.rescan(rereadingTitles: false)
        #expect(hub.directory.conversations.first?.title == "First")
        await hub.rescan()
        #expect(hub.directory.conversations.first?.title == "Second")
    }

    @Test func aConversationWhoseStateComesFromItsConnectorShowsWorkingAsSoonAsItsTurnStarts() async {
        let pi = ExtensionDiscovery(kind: .pi, processStart: { _ in .started(milliseconds: 1) }, isRunning: { _ in true }, processes: { AgentProcesses.Found() })
        let transport = FakeTransport()
        let hub = AgentHub(transport: transport, discovery: [pi], scanDeadline: .seconds(30))
        transport.live.insert("pi:s1")
        hub.handle(.hello(.init(
            protocolVersion: 2, agent: "pi", agentVersion: "", instance: "i1", session: "pi:s1", pid: 10, features: ["readiness"],
            idle: true, gap: false, cwd: "/src/api")))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .idle)
        hub.handle(.turnStarted(session: "pi:s1", turn: "t1"))
        let until = Date().addingTimeInterval(5)
        while hub.directory.conversations.first?.state != .working, Date() < until { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(hub.directory.conversations.first?.state == .working)
    }

    final class TranscriptWatches: @unchecked Sendable {
        private let lock = NSLock()
        private var changed: [String: @Sendable () -> Void] = [:]
        private var openedNames: [String] = []
        var failing = false

        var opened: [String] { lock.withLock { openedNames } }
        var open: Int { lock.withLock { changed.count } }
        func isOpen(_ name: String) -> Bool { lock.withLock { changed[name] != nil } }

        func watch(_ url: URL, _ onChange: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
            let name = url.lastPathComponent
            return lock.withLock {
                guard !failing else { return nil }
                changed[name] = onChange
                openedNames.append(name)
                return { [weak self] in self?.lock.withLock { _ = self?.changed.removeValue(forKey: name) } }
            }
        }

        func write(_ name: String) { lock.withLock { changed[name] }?() }
    }

    final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [(id: UUID, length: Duration, resume: CheckedContinuation<Void, Never>)] = []

        var pending: [Duration] { lock.withLock { waiting.map(\.length) } }

        func sleep(_ length: Duration) async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let cancelled = lock.withLock {
                        guard !Task.isCancelled else { return true }
                        waiting.append((id, length, continuation))
                        return false
                    }
                    if cancelled { continuation.resume() }
                }
            } onCancel: {
                lock.withLock { waiting.firstIndex { $0.id == id }.map { waiting.remove(at: $0) } }?.resume.resume()
            }
        }

        func release(_ matching: (Duration) -> Bool) {
            let released = lock.withLock {
                let chosen = waiting.filter { matching($0.length) }
                waiting.removeAll { matching($0.length) }
                return chosen
            }
            for sleep in released { sleep.resume.resume() }
        }
    }

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    private struct TitleRig {
        let hub: AgentHub
        let registry: Registry
        let scans: Count
        let watches: TranscriptWatches
        let sleeps: Sleeps
        let titles: ClaudeTranscriptTitles
        let folder: URL

        func writeTitle(_ title: String, session: String = "s1") throws {
            try Data(#"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"claude:\#(session)"}"#.utf8)
                .write(to: folder.appendingPathComponent("\(session).jsonl"))
        }

        @MainActor var title: String? { hub.directory.conversations.first { $0.id == "claude:s1" }?.title }
        static let recheck = Duration.seconds(ClaudeDiscovery.titleRecheck)
    }

    private func titleRig(_ dir: URL) throws -> TitleRig {
        let folder = dir.appendingPathComponent("projects/-src-keyscribe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registry = Registry()
        let scans = Count()
        let watches = TranscriptWatches()
        let sleeps = Sleeps()
        let titles = ClaudeTranscriptTitles(configDirs: [dir])
        let transport = FakeTransport()
        let hub = AgentHub(
            transport: transport, scan: { scans.add(); return registry.entries }, transcriptTitles: titles,
            transcriptWatch: { watches.watch($0, $1) }, titleSpacing: { await sleeps.sleep($0) }, scanDeadline: .seconds(30))
        registry.set("s1")
        transport.live.insert("claude:s1")
        try Data().write(to: folder.appendingPathComponent("s1.jsonl"))
        return TitleRig(hub: hub, registry: registry, scans: scans, watches: watches, sleeps: sleeps, titles: titles, folder: folder)
    }

    private func turnEnded(_ rig: TitleRig, _ session: String = "claude:s1") async {
        rig.hub.handle(.turnComplete(session: session, reason: "answer", answer: "Done."))
        await rig.hub.scansSettled()
    }

    enum TitleWrite: String, CaseIterable, Sendable { case beforeTheEnd, afterTheEnd, afterAnEndBeforeTheFirstScan }

    @Test(arguments: TitleWrite.allCases)
    func aTitleItsTranscriptGainsAroundATurnEndArrivesWithNoSecondHello(_ write: TitleWrite) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-late-title-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try titleRig(dir)
        if write == .afterAnEndBeforeTheFirstScan {
            await turnEnded(rig)
            await rig.hub.rescan()
        } else {
            await rig.hub.rescan()
            rig.hub.handle(labelHello())
            await rig.hub.scansSettled()
            if write == .beforeTheEnd { try rig.writeTitle("Fix the flaky test") }
            rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
            await turnEnded(rig)
        }
        await waitUntil { rig.watches.isOpen("s1.jsonl") }
        if write != .beforeTheEnd {
            #expect(rig.title == nil)
            await waitUntil { rig.sleeps.pending.isEmpty == false }
            try rig.writeTitle("Fix the flaky test")
            rig.watches.write("s1.jsonl")
        }
        await waitUntil { rig.title == "Fix the flaky test" }
    }

    @Test func aTranscriptWhoseWatchCannotOpenIsStillReadOnceAndHoldsNoSlotOrTimer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-unwatched-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try titleRig(dir)
        rig.watches.failing = true
        try rig.writeTitle("Old title")
        await rig.hub.rescan()
        #expect(rig.title == "Old title")
        try rig.writeTitle("Written before the end")
        await turnEnded(rig)
        await waitUntil { rig.title == "Written before the end" }
        #expect(rig.watches.open == 0)
        #expect(rig.sleeps.pending.isEmpty)
    }

    @Test func aWriteDuringTheSpacingIsReadOnceTheSpacingEndsWithNoSecondWrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-title-cadence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try titleRig(dir)
        await rig.hub.rescan()
        await turnEnded(rig)
        await waitUntil { rig.watches.isOpen("s1.jsonl") }
        try rig.writeTitle("Later")
        rig.watches.write("s1.jsonl")
        await waitUntil { rig.title == "Later" }
        let reads = rig.titles.reads
        try rig.writeTitle("Within the spacing")
        rig.watches.write("s1.jsonl")
        let pacing = { (length: Duration) in length > .zero && length <= TitleRig.recheck }
        await waitUntil { rig.sleeps.pending.contains(where: pacing) }
        #expect(rig.titles.reads == reads)
        #expect(rig.title == "Later")
        rig.sleeps.release(pacing)
        await waitUntil { rig.title == "Within the spacing" }
    }

    @Test func transcriptWritesThatLeaveTheTitleAloneStartNoScan() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-title-same-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try titleRig(dir)
        await rig.hub.rescan()
        await turnEnded(rig)
        await waitUntil { rig.watches.isOpen("s1.jsonl") && !rig.sleeps.pending.isEmpty }
        let (scans, reads) = (rig.scans.count, rig.titles.reads)
        try Data(#"{"type":"assistant","sessionId":"claude:s1"}"#.utf8).write(to: rig.folder.appendingPathComponent("s1.jsonl"))
        rig.watches.write("s1.jsonl")
        await waitUntil { rig.titles.reads == reads + 1 }
        await rig.hub.scansSettled()
        #expect(rig.scans.count == scans)
    }

    enum WatchEnd: String, CaseIterable, Sendable { case itsTimeRunsOut, itsConversationLeavesTheList, theHubStops }

    @Test(arguments: WatchEnd.allCases)
    func aTitleWatchClosesWithNoWriteAndArmsNoTimerOfItsOwn(_ end: WatchEnd) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-title-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try titleRig(dir)
        await rig.hub.rescan()
        await turnEnded(rig)
        await waitUntil { rig.watches.isOpen("s1.jsonl") }
        #expect(AgentRuntime.pace(settingsOpen: false) == nil)
        switch end {
        case .itsTimeRunsOut: rig.sleeps.release { $0 > TitleRig.recheck }
        case .itsConversationLeavesTheList:
            rig.registry.remove("s1")
            await rig.hub.rescan(rereadingTitles: false)
        case .theHubStops: rig.hub.stop()
        }
        await waitUntil { rig.watches.open == 0 }
        #expect(rig.sleeps.pending.isEmpty)
    }

    @Test func turnEndsInManyConversationsKeepABoundedNumberOfWatchesOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-hub-title-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try titleRig(dir)
        let many = ClaudeDiscovery.titleWatchLimit + 10
        for index in 0..<many {
            rig.registry.set("s\(index)", pid: 100 + index)
            try rig.writeTitle("", session: "s\(index)")
        }
        await rig.hub.rescan()
        for index in 0..<many { rig.hub.handle(.turnComplete(session: "claude:s\(index)", reason: "answer", answer: "Done.")) }
        await rig.hub.scansSettled()
        await waitUntil { rig.watches.opened.count >= ClaudeDiscovery.titleWatchLimit }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.watches.open <= ClaudeDiscovery.titleWatchLimit)
    }

    @Test func theRuntimeWakesEverySecondWhileSettingsIsOpenAndOtherwiseNever() {
        #expect(AgentRuntime.pace(settingsOpen: true) == .seconds(1))
        #expect(AgentRuntime.pace(settingsOpen: false) == nil)
    }

    @Test func theProcessOfAConversationRememberedByNameIsWatchedUntilItsNameIsReleased() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try AgentNameStore(directory: dir).save([:], remembered: [
            "fake:gone": RememberedName(name: "old work", pid: 77, startedAt: 1, native: nil, agent: "fake"),
        ])
        let fake = FakeDiscovery()
        fake.running = true
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake], names: AgentNameStore(directory: dir))
        var watched: [Set<Int>] = []
        hub.onProcesses = { watched.append($0) }
        fake.result = .found([Self.fakeSession("f1")])
        await hub.rescan()
        fake.running = false
        await hub.rescan()
        #expect(watched == [[10, 77], [10]])
    }

    @Test func eachRefreshTellsWhichProcessesTheListedConversationsRunIn() async {
        let fake = FakeDiscovery()
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake])
        var watched: [Set<Int>] = []
        hub.onProcesses = { watched.append($0) }
        var second = Self.fakeSession("f2")
        second.pid = 11
        fake.result = .found([Self.fakeSession("f1"), second])
        await hub.rescan()
        fake.result = .found([Self.fakeSession("f1")])
        await hub.rescan()
        await hub.rescan()
        #expect(watched == [[10, 11], [10]])
    }

    @Test func aPressRescansEveryAgentEvenWithNoHostTurnedOn() async {
        let fake = FakeDiscovery()
        let hub = AgentHub(transport: FakeTransport(), discovery: [fake])
        await hub.rescan()
        let before = fake.scans
        #expect(hub.startHostRefreshForPress() == nil)
        for _ in 0..<50 where fake.scans == before { await Task.yield() }
        #expect(fake.scans == before + 1)
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
        #expect(focus.focused.isEmpty)
    }

    final class Spoken {
        var results: [String] = []
        var endings: [String] = []
        var withdrawn: [String] = []
    }

    private func listening(_ hub: AgentHub, speaks: Bool = true) -> Spoken {
        let spoken = Spoken()
        hub.speaks = { speaks }
        hub.onResult = { _, _, answer, requested, _, _ in spoken.results.append("\(answer)|\(requested)") }
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

actor RequestedWaits {
    private(set) var all: [Duration] = []
    func record(_ wait: Duration) { all.append(wait) }
}
