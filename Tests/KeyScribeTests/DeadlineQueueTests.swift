import Foundation
import Testing
@testable import KeyScribeApp

struct DeadlineQueueTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }

    @Test func finishedWorkReturnsItsValue() async {
        let queue = DeadlineQueue(label: "test.deadline.finish")
        guard case .finished(let value) = await queue.run(within: 1, { 42 }) else {
            Issue.record("expected the work to finish")
            return
        }
        #expect(value == 42)
    }

    @Test func workThatOutlivesItsDeadlineIsReportedExpired() async {
        let queue = DeadlineQueue(label: "test.deadline.slow")
        let result = await queue.run(within: 0.05) { Thread.sleep(forTimeInterval: 0.3); return true }
        guard case .expired = result else {
            Issue.record("expected expiry")
            return
        }
    }

    @Test func workQueuedBehindABlockedCallNeverStartsAfterItsDeadline() async {
        let queue = DeadlineQueue(label: "test.deadline.queued")
        let release = DispatchSemaphore(value: 0)
        let ran = Counter()
        let blocker = Task { await queue.run(within: 5) { release.wait(); return 0 } }
        try? await Task.sleep(for: .milliseconds(50))
        let queued = await queue.run(within: 0.05) { ran.bump(); return 1 }
        guard case .expired = queued else {
            Issue.record("expected the queued call to expire")
            return
        }
        release.signal()
        _ = await blocker.value
        _ = await queue.run(within: 1) { 0 }
        #expect(ran.count == 0)
    }
}
