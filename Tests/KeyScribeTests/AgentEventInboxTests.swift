import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentEventInboxTests {
    final class Delivered: @unchecked Sendable {
        var batches: [[AgentEvent]] = []
    }

    final class Timers: @unchecked Sendable {
        var armed: [DispatchWorkItem] = []
        func fire() {
            guard !armed.isEmpty else { return }
            let due = armed.removeFirst()
            if !due.isCancelled { due.perform() }
        }
    }

    private func inbox(_ delivered: Delivered, _ timers: Timers) -> AgentEventInbox {
        AgentEventInbox(helloWait: 0.15, later: { _, item in timers.armed.append(item) }) { delivered.batches.append($0) }
    }

    private func hello(_ session: String) -> AgentEvent {
        .hello(.init(protocolVersion: 3, agent: "claude", agentVersion: "", instance: session, session: "claude:\(session)", pid: 1))
    }

    private func yielded() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func hellosArrivingTogetherAreDeliveredAsOneBatchOnceTheirBurstEnds() async {
        let delivered = Delivered(), timers = Timers()
        let inbox = inbox(delivered, timers)
        for i in 0..<50 { inbox.add(hello("s\(i)")) }
        await yielded()
        #expect(delivered.batches.isEmpty)
        #expect(timers.armed.count == 1)
        timers.fire()
        #expect(delivered.batches.map(\.count) == [50])
    }

    @Test func anAnswerToARequestIsDeliveredAtOnceAfterTheEventsBeforeIt() async {
        let delivered = Delivered(), timers = Timers()
        let inbox = inbox(delivered, timers)
        inbox.add(hello("s1"))
        inbox.add(.turnStarted(session: "claude:s1", turn: "t1"))
        inbox.add(.submitted(request: "r1", turn: "t1"))
        await yielded()
        #expect(delivered.batches == [[hello("s1"), .turnStarted(session: "claude:s1", turn: "t1"), .submitted(request: "r1", turn: "t1")]])
    }

    @Test func stateEventsAfterEachHelloWaitWithTheBurstSoItStaysOneBatch() async {
        let delivered = Delivered(), timers = Timers()
        let inbox = inbox(delivered, timers)
        for i in 0..<50 {
            inbox.add(hello("s\(i)"))
            inbox.add(.shown(session: "claude:s\(i)", on: false))
            inbox.add(.title(session: "claude:s\(i)", text: "t\(i)"))
        }
        await yielded()
        #expect(delivered.batches.isEmpty)
        timers.fire()
        #expect(delivered.batches.map(\.count) == [150])
    }

    @Test func aBurstAfterAnAnswerWaitsItsOwnFullWindow() async {
        let delivered = Delivered(), timers = Timers()
        let inbox = inbox(delivered, timers)
        inbox.add(hello("s0"))
        inbox.add(.ack(request: "r1"))
        await yielded()
        #expect(delivered.batches.map(\.count) == [2])
        for i in 1...20 { inbox.add(hello("s\(i)")) }
        timers.fire()
        #expect(delivered.batches.map(\.count) == [2])
        timers.fire()
        #expect(delivered.batches.map(\.count) == [2, 20])
    }

    @Test(arguments: [
        AgentEvent.shown(session: "claude:s1", on: true),
        .typed(session: "claude:s1"),
        .turnComplete(session: "claude:s1", reason: "answer", answer: "Done."),
        .title(session: "claude:s1", text: "docs"),
    ])
    func withNoHelloBurstOpenAnEventIsDeliveredAtOnce(_ event: AgentEvent) async {
        let delivered = Delivered(), timers = Timers()
        let inbox = inbox(delivered, timers)
        inbox.add(event)
        await yielded()
        #expect(delivered.batches == [[event]])
        #expect(timers.armed.isEmpty)
    }

    @Test func aTurnEventDuringABurstDeliversTheBurstAndItselfAtOnceInOrder() async {
        let delivered = Delivered(), timers = Timers()
        let inbox = inbox(delivered, timers)
        inbox.add(hello("s1"))
        inbox.add(.shown(session: "claude:s1", on: true))
        inbox.add(.turnStarted(session: "claude:s1", turn: "t1"))
        await yielded()
        #expect(delivered.batches == [[hello("s1"), .shown(session: "claude:s1", on: true), .turnStarted(session: "claude:s1", turn: "t1")]])
    }

    @Test func drainingDeliversWhatWaitsAtOnce() {
        let delivered = Delivered(), timers = Timers()
        let inbox = inbox(delivered, timers)
        inbox.add(hello("s1"))
        inbox.drain()
        inbox.drain()
        #expect(delivered.batches == [[hello("s1")]])
    }
}
