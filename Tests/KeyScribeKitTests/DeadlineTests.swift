import Foundation
import Testing
@testable import KeyScribeKit

// Stands in for a CoreML/MLX SDK call that ignores cancellation and runs to completion regardless.
// Blocks on a DEDICATED thread, never a cooperative-pool one: `Thread.sleep` inside a Task parks a pool
// thread, and enough of these running in parallel starve the very deadline timer under test — the test then
// fails for lack of a scheduler, not because the deadline misbehaved. Suspending on a continuation the
// detached thread resumes preserves what is being modelled (cancellation does not shorten it) without
// consuming the pool.
private func nonCooperativeBlock(seconds: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: seconds)
            continuation.resume()
        }
    }
}

struct DeadlineTests {
    @Test func returnsResultWhenOperationFinishesInTime() async throws {
        let value = try await runWithDeadline(seconds: 5) { "done" }
        #expect(value == "done")
    }

    @Test func throwsAtDeadlineEvenWhenOperationIgnoresCancellation() async {
        let finished = Latch()
        await #expect(throws: DeadlineExceeded.self) {
            try await runWithDeadline(seconds: 0.1) {
                await nonCooperativeBlock(seconds: 2)
                finished.set()
                return "late"
            }
        }
        #expect(!finished.isSet)
    }

    @Test func adoptsALateResultWithinTheGraceWindowButNotPastIt() async throws {
        await #expect(throws: DeadlineExceeded.self) {
            try await runWithDeadline(seconds: 0.15) {
                await nonCooperativeBlock(seconds: 0.3)
                return "adopted"
            }
        }
        let value = try await runWithDeadline(seconds: 0.6) {
            await nonCooperativeBlock(seconds: 0.3)
            return "adopted"
        }
        #expect(value == "adopted")
    }

    @Test func propagatesOperationError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await runWithDeadline(seconds: 5) { throw Boom() }
        }
    }

    @Test func cancelledTimerNeverResumesFailureAfterFastSuccess() async throws {
        for _ in 0..<200 {
            let value = try await runWithDeadline(seconds: 0.05) {
                await nonCooperativeBlock(seconds: 0.02)
                return "in-time"
            }
            #expect(value == "in-time")
        }
    }

    @Test func onSettledFiresAfterAbandonedOperationTrulyFinishes() async {
        let settled = Counter()
        await #expect(throws: DeadlineExceeded.self) {
            try await runWithDeadline(seconds: 0.1) {
                await nonCooperativeBlock(seconds: 0.5)
                return "late"
            } onSettled: {
                Task { await settled.bump() }
            }
        }
        #expect(await settled.value == 0)
        try? await Task.sleep(for: .seconds(1))
        #expect(await settled.value == 1)
    }
}

private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

struct SingleFlightDeadlineTests {
    @Test func runsAndReturns() async throws {
        let gate = SingleFlightDeadline()
        let value = try await gate.run(seconds: 5) { "done" }
        #expect(value == "done")
    }

    @Test func secondRunWhileFirstIsWedgedThrowsBusy() async {
        let gate = SingleFlightDeadline()
        let concurrent = Counter()
        async let first: Void = {
            try? await gate.run(seconds: 0.1) {
                await concurrent.bump()
                await nonCooperativeBlock(seconds: 0.6)
            }
        }()
        try? await Task.sleep(for: .seconds(0.2))
        await #expect(throws: SingleFlightDeadline.Busy.self) {
            try await gate.run(seconds: 0.1) {
                await concurrent.bump()
                return "second"
            }
        }
        _ = await first
        #expect(await concurrent.value == 1)
    }

    @Test func gateReopensAfterOperationSettles() async throws {
        let gate = SingleFlightDeadline()
        await #expect(throws: DeadlineExceeded.self) {
            try await gate.run(seconds: 0.1) { await nonCooperativeBlock(seconds: 0.4) }
        }
        try await Task.sleep(for: .seconds(0.6))
        let value = try await gate.run(seconds: 5) { "ok" }
        #expect(value == "ok")
    }

    @Test func backToBackRunsOnTheSameTaskNeverObserveBusy() async throws {
        let gate = SingleFlightDeadline()
        for i in 0..<2000 {
            let value = try await gate.run(seconds: 5) { i }
            #expect(value == i)
        }
    }

    @Test func reEntryAfterOperationErrorNeverObservesBusy() async throws {
        struct Boom: Error {}
        let gate = SingleFlightDeadline()
        for _ in 0..<500 {
            _ = try? await gate.run(seconds: 5) { throw Boom() }
            let value = try await gate.run(seconds: 5) { "ok" }
            #expect(value == "ok")
        }
    }

    @Test func reEntryAfterOperationThrownCancellationNeverObservesBusy() async throws {
        let gate = SingleFlightDeadline()
        for _ in 0..<500 {
            _ = try? await gate.run(seconds: 5) { throw CancellationError() }
            _ = try? await gate.run(seconds: 5) { throw DeadlineExceeded() }
            let value = try await gate.run(seconds: 5) { "ok" }
            #expect(value == "ok")
        }
    }

    @Test func aCancelledCallerNeverEntersTheGate() async {
        let gate = SingleFlightDeadline()
        let ran = Counter()
        let t = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await gate.run(seconds: 5) {
                await ran.bump()
                return "x"
            }
        }
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
        #expect(await ran.value == 0)
        #expect(await gate.isBusy == false)
    }
}
