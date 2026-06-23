import Foundation
import Testing
@testable import KeyScribeKit

// A synchronous block that never observes Task cancellation — stands in for a CoreML/MLX SDK call
// that runs to completion regardless. (Thread.sleep is banned directly in async contexts; calling it
// through a plain sync function is exactly the real-world shape we need to bound.)
private func nonCooperativeBlock(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

struct DeadlineTests {
    @Test func returnsResultWhenOperationFinishesInTime() async throws {
        let value = try await runWithDeadline(seconds: 5) { "done" }
        #expect(value == "done")
    }

    @Test func throwsAtDeadlineEvenWhenOperationIgnoresCancellation() async {
        // Thread.sleep is a synchronous, non-cooperative block — it never observes Task cancellation.
        // The fixed helper must still return at the deadline rather than wait the full 2s.
        let start = Date()
        await #expect(throws: DeadlineExceeded.self) {
            try await runWithDeadline(seconds: 0.1) {
                nonCooperativeBlock(seconds: 2)
                return "late"
            }
        }
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test func propagatesOperationError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await runWithDeadline(seconds: 5) { throw Boom() }
        }
    }
}
