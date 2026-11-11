import Foundation
import Testing
@testable import KeyScribeKit

struct AgentCommandQueueTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private func command(_ id: String) -> AgentCommand { .submit(id: id, expectedSession: "s1", text: "hello \(id)", expiresAt: .distantFuture) }
    private let quiet = AgentCommandQueue.activeWindow + 1

    @Test func aConnectionGapWithdrawsEverythingTheSessionHadOutstanding() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1))
        queue.enqueue(command("r2"), for: "s1", at: at(1))
        queue.enqueue(.submit(id: "r3", expectedSession: "s2", text: "other", expiresAt: .distantFuture), for: "s2", at: at(1))

        let withdrawn = queue.connectionGap(session: "s1", instance: "i1")
        #expect(withdrawn.map(\.command.id).sorted() == ["r1", "r2"])
        #expect(withdrawn.allSatisfy { $0.reason == .connectionGap })
        #expect(withdrawn.first { $0.command.id == "r1" }?.handedOff == true)
        #expect(withdrawn.first { $0.command.id == "r2" }?.handedOff == false)

        queue.hello(session: "s1", instance: "i2", connection: "i2", at: at(2))
        #expect(queue.poll(session: "s1", instance: "i2", connection: "i2", at: at(2)) == [])
        queue.tick(at: at(20))
        #expect(queue.poll(session: "s1", instance: "i2", connection: "i2", at: at(20)) == [])
    }

    @Test func theQueueIsSettledOnlyWhenNoCommandWaitsToBeCollectedOrAcknowledged() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        #expect(queue.isSettled)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        #expect(!queue.isSettled)
        _ = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1))
        #expect(!queue.isSettled)
        queue.ack("r1", instance: "i1", connection: "i1")
        #expect(queue.isSettled)
    }

    @Test func aQueuedCommandIsDeliveredToThePollingInstance() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        let r1 = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1))
        #expect(r1 == [command("r1")])
        let r2 = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(2))
        #expect(r2 == [])
    }

    @Test func anAcknowledgedCommandIsNeverRedelivered() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1))
        queue.ack("r1", instance: "i1", connection: "i1")
        queue.tick(at: at(2 + AgentCommandQueue.ackTimeout))
        let r3 = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(3 + AgentCommandQueue.ackTimeout))
        #expect(r3 == [])
    }

    @Test func anUnacknowledgedCommandIsRedeliveredAfterTheTimeout() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1))
        queue.tick(at: at(1 + AgentCommandQueue.ackTimeout - 0.1))
        let r4 = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1 + AgentCommandQueue.ackTimeout - 0.1))
        #expect(r4 == [])
        queue.tick(at: at(1 + AgentCommandQueue.ackTimeout + 0.1))
        let r5 = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1 + AgentCommandQueue.ackTimeout + 0.2))
        #expect(r5 == [command("r1")])
    }

    @Test func aCommandAnotherInstanceCollectedIsNeverReplayedToTheNewOne() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "old", connection: "old", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "old", connection: "old", at: at(1))
        queue.hello(session: "s1", instance: "new", connection: "new", at: at(2))
        queue.tick(at: at(2 + AgentCommandQueue.ackTimeout))
        #expect(queue.poll(session: "s1", instance: "new", connection: "new", at: at(1 + quiet)) == [])
        let later = queue.undeliverable(at: at(1 + quiet))
        #expect(later.map(\.command) == [command("r1")])
        #expect(later.map(\.handedOff) == [true])
    }

    @Test func aNewConnectionLeavesWhatTheOldOneCollectedUncertainAndKeepsTheRestForReview() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "c1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", connection: "c1", at: at(1))
        queue.enqueue(command("r2"), for: "s1", instance: "i1", at: at(1))

        let withdrawn = queue.hello(session: "s1", instance: "i1", connection: "c2", at: at(2))
        #expect(withdrawn.map(\.command.id) == ["r1"])
        #expect(withdrawn.map(\.reason) == [.connectionGap])
        #expect(withdrawn.map(\.handedOff) == [true])
        queue.tick(at: at(3 + AgentCommandQueue.ackTimeout))
        #expect(queue.poll(session: "s1", instance: "i1", connection: "c2", at: at(3 + AgentCommandQueue.ackTimeout)) == [command("r2")])
    }

    @Test func aSupersededConnectionIsToldToRegisterAndKeepsNothingAlive() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "c1", at: t0)
        queue.hello(session: "s1", instance: "i1", connection: "c2", at: at(1))
        #expect(queue.isCurrent(instance: "i1", connection: "c2"))
        #expect(!queue.isCurrent(instance: "i1", connection: "c1"))
        #expect(!queue.isCurrent(instance: "i9", connection: "c2"))
        #expect(queue.poll(session: "s1", instance: "i1", connection: "c1", at: at(2)) == nil)
        queue.touch(instance: "i1", connection: "c1", at: at(quiet))
        #expect(!queue.isLive(session: "s1", at: at(1 + quiet)))
    }

    @Test func retiringSomeInstancesWithdrawsOnlyTheirSessionsCommands() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "c1", at: t0)
        queue.hello(session: "s2", instance: "i2", connection: "c2", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        queue.enqueue(.submit(id: "r2", expectedSession: "s2", text: "other", expiresAt: .distantFuture), for: "s2", at: t0)
        #expect(queue.retire(instances: ["i1"]).map(\.command.id) == ["r1"])
        #expect(!queue.isCurrent(instance: "i1", connection: "c1"))
        #expect(queue.isCurrent(instance: "i2", connection: "c2"))
        #expect(queue.poll(session: "s2", instance: "i2", connection: "c2", at: at(1))?.map(\.id) == ["r2"])
    }

    @Test func retiringWithdrawsEveryCommandAndEndsEveryConnection() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "c1", at: t0)
        queue.hello(session: "s2", instance: "i2", connection: "c2", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", connection: "c1", at: at(1))
        queue.enqueue(command("r2"), for: "s2", at: at(1))
        #expect(queue.retire() == [
            .init(command: command("r1"), reason: .retired, handedOff: true),
            .init(command: command("r2"), reason: .retired, handedOff: false),
        ])
        #expect(!queue.isCurrent(instance: "i1", connection: "c1"))
        #expect(!queue.isLive(session: "s2", at: at(1)))
        #expect(queue.poll(session: "s1", instance: "i1", connection: "c1", at: at(2)) == nil)
        queue.tick(at: at(2 + AgentCommandQueue.ackTimeout))
        #expect(queue.undeliverable(at: at(3 + AgentCommandQueue.ackTimeout)).isEmpty)
    }

    @Test func anAcknowledgmentFromAnotherConnectionClearsNothing() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "c1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", connection: "c1", at: at(1))
        queue.ack("r1", instance: "i1", connection: "c0")
        queue.ack("r1", instance: "i2", connection: "c1")
        queue.tick(at: at(2 + AgentCommandQueue.ackTimeout))
        #expect(queue.poll(session: "s1", instance: "i1", connection: "c1", at: at(2 + AgentCommandQueue.ackTimeout)) == [command("r1")])
    }

    @Test func untargetedCommandsAreRefusedWhileTwoTerminalsShareTheSession() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "left", connection: "left", at: t0)
        queue.hello(session: "s1", instance: "right", connection: "right", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: at(1))
        let left = queue.poll(session: "s1", instance: "left", connection: "left", at: at(2))
        #expect(left == [])
        for second in stride(from: 2.0, through: 1 + AgentCommandQueue.ambiguityGrace, by: 1) {
            queue.touch(instance: "left", connection: "left", at: at(second))
            queue.touch(instance: "right", connection: "right", at: at(second))
        }
        let refused = queue.undeliverable(at: at(1.5 + AgentCommandQueue.ambiguityGrace))
        #expect(refused.map(\.command) == [command("r1")])
        #expect(refused.map(\.reason) == [.ambiguous])
        #expect(refused.map(\.handedOff) == [false])
    }

    @Test func aCommandForOneInstanceReachesOnlyThatInstance() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "left", connection: "left", at: t0)
        queue.hello(session: "s1", instance: "right", connection: "right", at: t0)
        queue.enqueue(command("r1"), for: "s1", instance: "left", at: t0)
        let r13 = queue.poll(session: "s1", instance: "right", connection: "right", at: at(1))
        #expect(r13 == [])
        let r14 = queue.poll(session: "s1", instance: "left", connection: "left", at: at(1))
        #expect(r14 == [command("r1")])
    }

    @Test func aCommandForAnInstanceThatWentAwayIsReportedNotStranded() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "old", connection: "old", at: t0)
        queue.enqueue(command("r1"), for: "s1", instance: "old", at: t0)
        queue.hello(session: "s1", instance: "new", connection: "new", at: at(1))
        let other = queue.poll(session: "s1", instance: "new", connection: "new", at: at(quiet))
        #expect(other == [])
        let refused = queue.undeliverable(at: at(quiet))
        #expect(refused.map(\.command) == [command("r1")])
        #expect(refused.map(\.reason) == [.instanceGone])
        #expect(refused.map(\.handedOff) == [false])
        #expect(queue.undeliverable(at: at(quiet + 1)).isEmpty)
    }

    @Test func aHandedOffCommandWhoseInstanceWentAwayIsUncertainNotUnsent() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "old", connection: "old", at: t0)
        queue.enqueue(command("r1"), for: "s1", instance: "old", at: t0)
        _ = queue.poll(session: "s1", instance: "old", connection: "old", at: at(1))
        queue.tick(at: at(2 + quiet))
        let refused = queue.undeliverable(at: at(2 + quiet))
        #expect(refused.map(\.reason) == [.instanceGone])
        #expect(refused.map(\.handedOff) == [true])
    }

    @Test func commandsForOneSessionNeverReachAnother() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "a", connection: "a", at: t0)
        queue.hello(session: "s2", instance: "b", connection: "b", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        let r9 = queue.poll(session: "s2", instance: "b", connection: "b", at: at(1))
        #expect(r9 == [])
    }

    @Test func anInstanceTheQueueDoesNotKnowIsToldToRegister() {
        var queue = AgentCommandQueue()
        #expect(queue.poll(session: "s1", instance: "i1", connection: "i1", at: t0) == nil)
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        #expect(queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1)) == [])
        #expect(queue.poll(session: "s2", instance: "i1", connection: "i1", at: at(2)) == nil)
    }

    @Test func aSessionIsLiveOnlyWhileAnInstanceKeepsPollingOrWaiting() {
        var queue = AgentCommandQueue()
        #expect(!queue.isLive(session: "s1", at: t0))
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        #expect(queue.isLive(session: "s1", at: at(1)))
        queue.touch(instance: "i1", connection: "i1", at: at(20))
        #expect(queue.isLive(session: "s1", at: at(21)))
        #expect(!queue.isLive(session: "s1", at: at(20 + quiet)))
    }

    @Test func activeInstancesAreListedNewestFirst() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "left", connection: "left", at: t0)
        queue.hello(session: "s1", instance: "right", connection: "right", at: at(1))
        #expect(queue.activeInstances(session: "s1", at: at(2)) == ["right", "left"])
    }

    @Test func aCommandHandedOffOnceCannotBeWithdrawnEvenAfterRequeueing() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1))
        queue.tick(at: at(2 + AgentCommandQueue.ackTimeout))
        let withdrawn = queue.withdraw("r1")
        #expect(!withdrawn)
        let redelivered = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(3 + AgentCommandQueue.ackTimeout))
        #expect(redelivered == [command("r1")])
    }

    @Test func anExpiredFocusIsNeverDeliveredEvenAfterTheConnectorReconnects() {
        var queue = AgentCommandQueue()
        queue.enqueue(.focus(id: "f1", expectedSession: "s1", expiresAt: at(3)), for: "s1", at: t0)
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: at(4))
        #expect(queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(4)) == [])
    }

    @Test func aForgottenSessionIsNotPolledOrLiveUntilItSaysHelloAgain() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "c1", at: t0)
        queue.hello(session: "s2", instance: "i2", connection: "c2", at: t0)
        queue.forget(session: "s1")
        #expect(queue.poll(session: "s1", instance: "i1", connection: "c1", at: at(1)) == nil)
        #expect(!queue.isLive(session: "s1", at: at(1)))
        #expect(queue.poll(session: "s2", instance: "i2", connection: "c2", at: at(1)) == [])
        queue.hello(session: "s1", instance: "i1", connection: "c3", at: at(2))
        #expect(queue.poll(session: "s1", instance: "i1", connection: "c3", at: at(2)) == [])
    }

    @Test func anExpiredSubmitIsNeverDeliveredAndIsReportedAsExpiredNotHandedOff() {
        var queue = AgentCommandQueue()
        let submit = AgentCommand.submit(id: "r1", expectedSession: "s1", text: "x", expiresAt: at(3))
        queue.enqueue(submit, for: "s1", at: t0)
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: at(4))
        #expect(queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(4)) == [])
        #expect(queue.undeliverable(at: at(4)) == [.init(command: submit, reason: .expired, handedOff: false)])
        #expect(queue.undeliverable(at: at(5)).isEmpty)
    }

    @Test func aSubmitThatExpiresAfterTheConnectorCollectedItStaysHandedOff() {
        var queue = AgentCommandQueue()
        let submit = AgentCommand.submit(id: "r1", expectedSession: "s1", text: "x", expiresAt: at(3))
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        queue.enqueue(submit, for: "s1", at: t0)
        #expect(queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1)) == [submit])
        queue.tick(at: at(2 + AgentCommandQueue.ackTimeout))
        #expect(queue.undeliverable(at: at(3 + AgentCommandQueue.ackTimeout)).map(\.handedOff) == [true])
    }

    @Test func aFocusRequeuedAfterItExpiredIsDropped() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        let focus = AgentCommand.focus(id: "f1", expectedSession: "s1", expiresAt: at(3))
        queue.enqueue(focus, for: "s1", at: t0)
        #expect(queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1)) == [focus])
        queue.tick(at: at(2 + AgentCommandQueue.ackTimeout))
        #expect(queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(3 + AgentCommandQueue.ackTimeout)) == [])
    }

    @Test func withdrawingAQueuedCommandWorksUntilItIsDelivered() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", connection: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        let r10 = queue.withdraw("r1")
        #expect(r10)
        let r11 = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(1))
        #expect(r11 == [])
        queue.enqueue(command("r2"), for: "s1", at: at(1))
        _ = queue.poll(session: "s1", instance: "i1", connection: "i1", at: at(2))
        let r12 = queue.withdraw("r2")
        #expect(!r12)
    }
}

struct AgentBridgeCodecTests {
    @Test func commandsRoundTripAsJSON() throws {
        let commands: [AgentCommand] = [
            .submit(id: "r1", expectedSession: "s1", text: "/usr/local/bin is missing", expiresAt: Date(timeIntervalSince1970: 1_793_400_008.5)),
            .status(id: "r5", expectedSession: "s1", text: "🎙 keyscribe"),
            .focus(id: "r6", expectedSession: "s1", expiresAt: Date(timeIntervalSince1970: 1_793_400_000.25)),
        ]
        let data = try AgentBridgeCodec.encode(commands)
        #expect(try AgentBridgeCodec.decodeCommands(data) == commands)
    }

    @Test func eventsDecodeFromTheConnectorsWireFormat() throws {
        let json = """
        {"op":"hello","protocol":1,"agent":"claude","agentVersion":"2.1.314","instance":"i1","session":"s1","pid":4242}
        """
        let event = try AgentBridgeCodec.decodeEvent(Data(json.utf8))
        #expect(event == .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "2.1.314", instance: "i1", session: "s1", pid: 4242)))
    }

    @Test func aConnectorAnnouncesWhatItCanDoAndAnswersAFocus() throws {
        let hello = #"{"op":"hello","protocol":1,"agent":"claude","instance":"i1","session":"s1","pid":0,"features":["focus"]}"#
        #expect(try AgentBridgeCodec.decodeEvent(Data(hello.utf8))
            == .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s1", pid: 0, features: ["focus"])))
        #expect(try AgentBridgeCodec.decodeEvent(Data(#"{"op":"focused","request":"r6"}"#.utf8)) == .focused(request: "r6"))
        let titled = #"{"op":"hello","protocol":1,"agent":"claude","instance":"i1","session":"s1","pid":0,"title":"Fix focus"}"#
        #expect(try AgentBridgeCodec.decodeEvent(Data(titled.utf8))
            == .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s1", pid: 0, title: "Fix focus")))
        #expect(try AgentBridgeCodec.decodeEvent(Data(#"{"op":"title","session":"s1","text":"Renamed"}"#.utf8))
            == .title(session: "s1", text: "Renamed"))
    }

    @Test func aConnectorReportsWhatItWaitsForAndWhenItStops() throws {
        let opened = #"{"op":"waiting","session":"s1","waiting":{"kind":"select","title":"Allow?","tool":"bash","detail":"rm -rf build","said":"Cleaning up."}}"#
        #expect(try AgentBridgeCodec.decodeEvent(Data(opened.utf8))
            == .waiting(session: "s1", prompt: AgentPrompt(kind: "select", title: "Allow?", tool: "bash", detail: "rm -rf build", said: "Cleaning up.")))
        #expect(try AgentBridgeCodec.decodeEvent(Data(#"{"op":"waiting","session":"s1","waiting":{}}"#.utf8))
            == .waiting(session: "s1", prompt: AgentPrompt()))
        #expect(try AgentBridgeCodec.decodeEvent(Data(#"{"op":"waiting","session":"s1"}"#.utf8)) == .waiting(session: "s1", prompt: nil))
        let hello = #"{"op":"hello","protocol":1,"agent":"pi","instance":"i1","session":"s1","pid":0,"waiting":{"title":"Which?"}}"#
        #expect(try AgentBridgeCodec.decodeEvent(Data(hello.utf8))
            == .hello(.init(protocolVersion: 1, agent: "pi", agentVersion: "", instance: "i1", session: "s1", pid: 0, waiting: AgentPrompt(title: "Which?"))))
        #expect(AgentEvent.waiting(session: "s1", prompt: nil).renamingSession { "pi:" + $0 } == .waiting(session: "pi:s1", prompt: nil))
    }

    @Test func aConnectorReportsTheTerminalEnvironmentOnlyItsOwnProcessCanRead() throws {
        let hello = #"{"op":"hello","protocol":1,"agent":"claude","instance":"i1","session":"s1","pid":0,"environment":{"ZELLIJ_PANE_ID":"3"}}"#
        #expect(try AgentBridgeCodec.decodeEvent(Data(hello.utf8)) == .hello(.init(
            protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s1", pid: 0, environment: ["ZELLIJ_PANE_ID": "3"])))
    }

    @Test func aConnectorWithoutARegistryReportsItsWorkingDirectoryOnHello() throws {
        let hello = #"{"op":"hello","protocol":1,"agent":"pi","instance":"i1","session":"s1","pid":77,"cwd":"/src/api"}"#
        #expect(try AgentBridgeCodec.decodeEvent(Data(hello.utf8))
            == .hello(.init(protocolVersion: 1, agent: "pi", agentVersion: "", instance: "i1", session: "s1", pid: 77, cwd: "/src/api")))
        let bare = #"{"op":"hello","protocol":1,"agent":"claude","instance":"i1","session":"s1","pid":0}"#
        guard case .hello(let plain) = try AgentBridgeCodec.decodeEvent(Data(bare.utf8)) else { Issue.record("not a hello"); return }
        #expect(plain.cwd == nil)
    }

    @Test func aConnectorAsksForTheReplyToBeReadAloudAndReportsItsRunningTurnOnHello() throws {
        #expect(try AgentBridgeCodec.decodeEvent(Data(#"{"op":"notify","session":"s1","turn":"t4","on":true}"#.utf8))
            == .notify(session: "s1", turn: "t4", on: true))
        #expect(try AgentBridgeCodec.decodeEvent(Data(#"{"op":"notify","session":"s1","on":false}"#.utf8))
            == .notify(session: "s1", turn: "", on: false))
        #expect(throws: AgentBridgeCodec.CodecError.malformed) { try AgentBridgeCodec.decodeEvent(Data(#"{"op":"notify","session":"s1"}"#.utf8)) }
        #expect(AgentEvent.notify(session: "s1", turn: "t4", on: true).renamingSession { "pi:" + $0 } == .notify(session: "pi:s1", turn: "t4", on: true))
        #expect(AgentEvent.notify(session: "pi:s1", turn: "", on: true).session == "pi:s1")
        let hello = #"{"op":"hello","protocol":3,"agent":"pi","instance":"i1","session":"s1","pid":0,"features":["notify"],"turn":"t4"}"#
        #expect(try AgentBridgeCodec.decodeEvent(Data(hello.utf8))
            == .hello(.init(protocolVersion: 3, agent: "pi", agentVersion: "", instance: "i1", session: "s1", pid: 0, features: ["notify"], turn: "t4")))
    }

    @Test func everyEventNamesTheSessionItConcernsAndRequestEventsNameNone() throws {
        let hello = AgentEvent.hello(.init(protocolVersion: 1, agent: "pi", agentVersion: "", instance: "i1", session: "pi:s1", pid: 0))
        #expect(hello.session == "pi:s1")
        #expect(AgentEvent.typed(session: "pi:s1").session == "pi:s1")
        #expect(AgentEvent.turnStarted(session: "pi:s1", turn: "t1").session == "pi:s1")
        #expect(AgentEvent.turnComplete(session: "pi:s1", reason: "complete", answer: "").session == "pi:s1")
        #expect(AgentEvent.title(session: "pi:s1", text: "x").session == "pi:s1")
        #expect(AgentEvent.ack(request: "r1").session == nil)
        #expect(AgentEvent.submitted(request: "r1", turn: "t1").session == nil)
        #expect(AgentEvent.refused(request: "r1", reason: "draft").session == nil)
        #expect(AgentEvent.focused(request: "r1").session == nil)
        #expect(AgentEvent.undelivered(request: "r1", reason: "retired", handedOff: false).session == nil)
    }

    @Test func aSubmitCarriesThePromptCountItWasDecidedAgainst() throws {
        let fenced: [AgentCommand] = [.submit(id: "r1", expectedSession: "s1", text: "x", expectedPrompts: 3, expiresAt: .distantFuture)]
        let data = try AgentBridgeCodec.encode(fenced)
        #expect(String(decoding: data, as: UTF8.self).contains(#""expectedPrompts":3"#))
        #expect(try AgentBridgeCodec.decodeCommands(data) == fenced)
        let unfenced = try AgentBridgeCodec.encode([.submit(id: "r1", expectedSession: "s1", text: "x", expiresAt: .distantFuture)])
        #expect(!String(decoding: unfenced, as: UTF8.self).contains("expectedPrompts"))
    }

    @Test func aSubmitCarriesTheImagesItNamesOnlyWhenThereAreSome() throws {
        let attached: [AgentCommand] = [.submit(id: "r1", expectedSession: "s1", text: "see /tmp/a.png", expiresAt: .distantFuture, images: ["/tmp/a.png"])]
        let data = try AgentBridgeCodec.encode(attached)
        #expect(String(decoding: data, as: UTF8.self).contains(#""images":["\/tmp\/a.png"]"#) || String(decoding: data, as: UTF8.self).contains(#""images":["/tmp/a.png"]"#))
        #expect(try AgentBridgeCodec.decodeCommands(data) == attached)
        let plain = try AgentBridgeCodec.encode([.submit(id: "r1", expectedSession: "s1", text: "x", expiresAt: .distantFuture)])
        #expect(!String(decoding: plain, as: UTF8.self).contains("images"))
        let renamed = attached[0].renamingSession { "pi:" + $0 }
        #expect(renamed == .submit(id: "r1", expectedSession: "pi:s1", text: "see /tmp/a.png", expiresAt: .distantFuture, images: ["/tmp/a.png"]))
    }

    @Test func aSubmitWithoutADeadlineIsMalformed() {
        let undated = #"[{"op":"submit","id":"r1","expectedSession":"s1","text":"x"}]"#
        #expect(throws: (any Error).self) { try AgentBridgeCodec.decodeCommands(Data(undated.utf8)) }
    }

    @Test func helloAndTypedReportTheUsersPromptCount() throws {
        let hello = #"{"op":"hello","protocol":1,"agent":"claude","instance":"i1","session":"s1","pid":0,"prompts":4}"#
        #expect(try AgentBridgeCodec.decodeEvent(Data(hello.utf8))
            == .hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "s1", pid: 0, prompts: 4)))
        #expect(try AgentBridgeCodec.decodeEvent(Data(#"{"op":"typed","session":"s1","prompts":5}"#.utf8)) == .typed(session: "s1", prompts: 5))
    }

    @Test func helloReportsItsTurnAndWhetherItResumesAfterAGap() throws {
        let fresh = #"{"op":"hello","protocol":1,"agent":"claude","instance":"i1","session":"s1","pid":0,"features":["readiness"],"idle":true,"gap":false}"#
        guard case .hello(let hello) = try AgentBridgeCodec.decodeEvent(Data(fresh.utf8)) else { Issue.record("not a hello"); return }
        #expect(hello.knownIdle)
        #expect(hello.gap == false)
        #expect(!hello.resumesAfterGap)

        let gap = #"{"op":"hello","protocol":1,"agent":"claude","instance":"i1","session":"s1","pid":0,"features":["readiness"],"gap":true}"#
        guard case .hello(let resumed) = try AgentBridgeCodec.decodeEvent(Data(gap.utf8)) else { Issue.record("not a hello"); return }
        #expect(resumed.resumesAfterGap)
        #expect(!resumed.knownIdle)
    }

    @Test func aConnectorWithoutReadinessAlwaysResumesAfterAGap() throws {
        let old = #"{"op":"hello","protocol":1,"agent":"claude","instance":"i1","session":"s1","pid":0,"features":["focus"],"idle":true,"gap":false}"#
        guard case .hello(let hello) = try AgentBridgeCodec.decodeEvent(Data(old.utf8)) else { Issue.record("not a hello"); return }
        #expect(hello.resumesAfterGap)
        #expect(!hello.knownIdle)
    }

    @Test func helloAndEveryEventNameTheConnectionTheyBelongTo() throws {
        let hello = #"{"op":"hello","protocol":2,"agent":"claude","instance":"i1","session":"s1","pid":0,"connection":"c1"}"#
        guard case .hello(let decoded) = try AgentBridgeCodec.decodeEvent(Data(hello.utf8)) else { Issue.record("not a hello"); return }
        #expect(decoded.connection == "c1")
        let typed = Data(#"{"op":"typed","session":"s1","instance":"i1","connection":"c1"}"#.utf8)
        let frame = try AgentBridgeCodec.decodeFrame(typed)
        #expect(frame.event == .typed(session: "s1"))
        #expect(frame.envelope == .init(instance: "i1", connection: "c1"))
        #expect(try AgentBridgeCodec.decodeFrame(Data(#"{"op":"ack","request":"r1"}"#.utf8)).envelope == .init(instance: nil, connection: nil))
    }

    @Test func aCompletionWithoutAnAnswerStillDecodes() throws {
        #expect(try AgentBridgeCodec.decodeEvent(Data(#"{"op":"turnComplete","session":"s1","reason":"answer"}"#.utf8))
            == .turnComplete(session: "s1", reason: "answer", answer: ""))
    }

    @Test func unknownOpsAndOversizeFramesAreRejected() {
        #expect(throws: AgentBridgeCodec.CodecError.unknownOp("explode")) {
            try AgentBridgeCodec.decodeEvent(Data(#"{"op":"explode"}"#.utf8))
        }
        let huge = Data(repeating: 0x20, count: AgentBridgeCodec.maxFrameBytes + 1)
        #expect(throws: AgentBridgeCodec.CodecError.tooLarge) { try AgentBridgeCodec.decodeEvent(huge) }
    }

    @Test(arguments: [
        (#"{"op":"ack","request":"r1"}"#, AgentEvent.ack(request: "r1")),
        (#"{"op":"submitted","request":"r1","turn":"t9"}"#, .submitted(request: "r1", turn: "t9")),
        (#"{"op":"refused","request":"r1","reason":"stopLocked"}"#, .refused(request: "r1", reason: "stopLocked")),
        (#"{"op":"typed","session":"s1"}"#, .typed(session: "s1")),
        (#"{"op":"turnStarted","session":"s1","turn":"t7"}"#, .turnStarted(session: "s1", turn: "t7")),
        (#"{"op":"turnComplete","session":"s1","reason":"answer","answer":"done"}"#, .turnComplete(session: "s1", reason: "answer", answer: "done")),
    ])
    func eachEventShapeDecodes(json: String, expected: AgentEvent) throws {
        #expect(try AgentBridgeCodec.decodeEvent(Data(json.utf8)) == expected)
    }
}
