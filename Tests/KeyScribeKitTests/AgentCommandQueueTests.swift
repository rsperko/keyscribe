import Foundation
import Testing
@testable import KeyScribeKit

struct AgentCommandQueueTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private func command(_ id: String) -> AgentCommand { .submit(id: id, expectedSession: "s1", text: "hello \(id)") }
    private let quiet = AgentCommandQueue.activeWindow + 1

    @Test func aQueuedCommandIsDeliveredToThePollingInstance() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        let r1 = queue.poll(session: "s1", instance: "i1", at: at(1))
        #expect(r1 == [command("r1")])
        let r2 = queue.poll(session: "s1", instance: "i1", at: at(2))
        #expect(r2 == [])
    }

    @Test func anAcknowledgedCommandIsNeverRedelivered() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", at: at(1))
        queue.ack("r1")
        queue.tick(at: at(2 + AgentCommandQueue.ackTimeout))
        let r3 = queue.poll(session: "s1", instance: "i1", at: at(3 + AgentCommandQueue.ackTimeout))
        #expect(r3 == [])
    }

    @Test func anUnacknowledgedCommandIsRedeliveredAfterTheTimeout() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", at: at(1))
        queue.tick(at: at(1 + AgentCommandQueue.ackTimeout - 0.1))
        let r4 = queue.poll(session: "s1", instance: "i1", at: at(1 + AgentCommandQueue.ackTimeout - 0.1))
        #expect(r4 == [])
        queue.tick(at: at(1 + AgentCommandQueue.ackTimeout + 0.1))
        let r5 = queue.poll(session: "s1", instance: "i1", at: at(1 + AgentCommandQueue.ackTimeout + 0.2))
        #expect(r5 == [command("r1")])
    }

    @Test func afterAReloadTheNewInstanceReceivesOnceTheOldOneGoesQuiet() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "old", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "old", at: at(1))
        queue.hello(session: "s1", instance: "new", at: at(2))
        let early = queue.poll(session: "s1", instance: "new", at: at(2))
        #expect(early == [])
        let later = queue.poll(session: "s1", instance: "new", at: at(1 + quiet))
        #expect(later == [command("r1")])
        #expect(queue.undeliverable(at: at(1 + quiet)).isEmpty)
    }

    @Test func untargetedCommandsAreRefusedWhileTwoTerminalsShareTheSession() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "left", at: t0)
        queue.hello(session: "s1", instance: "right", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: at(1))
        let left = queue.poll(session: "s1", instance: "left", at: at(2))
        #expect(left == [])
        for second in stride(from: 2.0, through: 1 + AgentCommandQueue.ambiguityGrace, by: 1) {
            queue.touch(instance: "left", at: at(second))
            queue.touch(instance: "right", at: at(second))
        }
        let refused = queue.undeliverable(at: at(1.5 + AgentCommandQueue.ambiguityGrace))
        #expect(refused.map(\.command) == [command("r1")])
        #expect(refused.map(\.reason) == [.ambiguous])
        #expect(refused.map(\.handedOff) == [false])
    }

    @Test func aCommandForOneInstanceReachesOnlyThatInstance() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "left", at: t0)
        queue.hello(session: "s1", instance: "right", at: t0)
        queue.enqueue(command("r1"), for: "s1", instance: "left", at: t0)
        let r13 = queue.poll(session: "s1", instance: "right", at: at(1))
        #expect(r13 == [])
        let r14 = queue.poll(session: "s1", instance: "left", at: at(1))
        #expect(r14 == [command("r1")])
    }

    @Test func aCommandForAnInstanceThatWentAwayIsReportedNotStranded() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "old", at: t0)
        queue.enqueue(command("r1"), for: "s1", instance: "old", at: t0)
        queue.hello(session: "s1", instance: "new", at: at(1))
        let other = queue.poll(session: "s1", instance: "new", at: at(quiet))
        #expect(other == [])
        let refused = queue.undeliverable(at: at(quiet))
        #expect(refused.map(\.command) == [command("r1")])
        #expect(refused.map(\.reason) == [.instanceGone])
        #expect(refused.map(\.handedOff) == [false])
        #expect(queue.undeliverable(at: at(quiet + 1)).isEmpty)
    }

    @Test func aHandedOffCommandWhoseInstanceWentAwayIsUncertainNotUnsent() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "old", at: t0)
        queue.enqueue(command("r1"), for: "s1", instance: "old", at: t0)
        _ = queue.poll(session: "s1", instance: "old", at: at(1))
        queue.tick(at: at(2 + quiet))
        let refused = queue.undeliverable(at: at(2 + quiet))
        #expect(refused.map(\.reason) == [.instanceGone])
        #expect(refused.map(\.handedOff) == [true])
    }

    @Test func commandsForOneSessionNeverReachAnother() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "a", at: t0)
        queue.hello(session: "s2", instance: "b", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        let r9 = queue.poll(session: "s2", instance: "b", at: at(1))
        #expect(r9 == [])
    }

    @Test func anInstanceTheQueueDoesNotKnowIsToldToRegister() {
        var queue = AgentCommandQueue()
        #expect(queue.poll(session: "s1", instance: "i1", at: t0) == nil)
        queue.hello(session: "s1", instance: "i1", at: t0)
        #expect(queue.poll(session: "s1", instance: "i1", at: at(1)) == [])
        #expect(queue.poll(session: "s2", instance: "i1", at: at(2)) == nil)
    }

    @Test func aSessionIsLiveOnlyWhileAnInstanceKeepsPollingOrWaiting() {
        var queue = AgentCommandQueue()
        #expect(!queue.isLive(session: "s1", at: t0))
        queue.hello(session: "s1", instance: "i1", at: t0)
        #expect(queue.isLive(session: "s1", at: at(1)))
        queue.touch(instance: "i1", at: at(20))
        #expect(queue.isLive(session: "s1", at: at(21)))
        #expect(!queue.isLive(session: "s1", at: at(20 + quiet)))
    }

    @Test func activeInstancesAreListedNewestFirst() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "left", at: t0)
        queue.hello(session: "s1", instance: "right", at: at(1))
        #expect(queue.activeInstances(session: "s1", at: at(2)) == ["right", "left"])
    }

    @Test func aCommandHandedOffOnceCannotBeWithdrawnEvenAfterRequeueing() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        _ = queue.poll(session: "s1", instance: "i1", at: at(1))
        queue.tick(at: at(2 + AgentCommandQueue.ackTimeout))
        let withdrawn = queue.withdraw("r1")
        #expect(!withdrawn)
        let redelivered = queue.poll(session: "s1", instance: "i1", at: at(3 + AgentCommandQueue.ackTimeout))
        #expect(redelivered == [command("r1")])
    }

    @Test func withdrawingAQueuedCommandWorksUntilItIsDelivered() {
        var queue = AgentCommandQueue()
        queue.hello(session: "s1", instance: "i1", at: t0)
        queue.enqueue(command("r1"), for: "s1", at: t0)
        let r10 = queue.withdraw("r1")
        #expect(r10)
        let r11 = queue.poll(session: "s1", instance: "i1", at: at(1))
        #expect(r11 == [])
        queue.enqueue(command("r2"), for: "s1", at: at(1))
        _ = queue.poll(session: "s1", instance: "i1", at: at(2))
        let r12 = queue.withdraw("r2")
        #expect(!r12)
    }
}

struct AgentBridgeCodecTests {
    @Test func commandsRoundTripAsJSON() throws {
        let commands: [AgentCommand] = [
            .submit(id: "r1", expectedSession: "s1", text: "/usr/local/bin is missing"),
            .abort(id: "r2", expectedSession: "s1", expectedTurn: "t7"),
            .fill(id: "r3", expectedSession: "s1", text: "use approach B"),
            .offerButton(id: "r4", expectedSession: "s1", text: "use approach B"),
            .status(id: "r5", expectedSession: "s1", text: "🎙 keyscribe"),
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
