import Foundation
import Testing
@testable import KeyScribeKit

// Stands in for a CoreML/MLX SDK call that ignores cancellation and runs to completion regardless.
// Thread.sleep is banned directly in async contexts, so it's wrapped in a plain sync function.
private func nonCooperativeBlock(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

struct DeadlineTests {
    @Test func returnsResultWhenOperationFinishesInTime() async throws {
        let value = try await runWithDeadline(seconds: 5) { "done" }
        #expect(value == "done")
    }

    @Test func throwsAtDeadlineEvenWhenOperationIgnoresCancellation() async {
        let start = Date()
        await #expect(throws: DeadlineExceeded.self) {
            try await runWithDeadline(seconds: 0.1) {
                nonCooperativeBlock(seconds: 2)
                return "late"
            }
        }
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    // The same late-landing operation a tight deadline discards is adopted under a widened one.
    // Mirrors AudioCapture.start() waiting bringUpTimeout + bringUpGrace: without the grace window, a
    // stale-binding re-realization at ~2s surfaced as a spurious "Could not start the microphone".
    @Test func adoptsALateResultWithinTheGraceWindowButNotPastIt() async throws {
        await #expect(throws: DeadlineExceeded.self) {
            try await runWithDeadline(seconds: 0.15) {
                nonCooperativeBlock(seconds: 0.3)
                return "adopted"
            }
        }
        let value = try await runWithDeadline(seconds: 0.6) {
            nonCooperativeBlock(seconds: 0.3)
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

    // A cancelled timer must not still resume DeadlineExceeded. With the old `try?`-swallowed sleep,
    // timeout.cancel() woke the sleep and the timer resumed failure anyway, racing the success and
    // intermittently reporting a spurious timeout. Run many close-races to catch the race reliably.
    @Test func cancelledTimerNeverResumesFailureAfterFastSuccess() async throws {
        for _ in 0..<200 {
            let value = try await runWithDeadline(seconds: 0.05) {
                nonCooperativeBlock(seconds: 0.02)
                return "in-time"
            }
            #expect(value == "in-time")
        }
    }

    // onSettled fires when the operation truly finishes, not at the deadline — even on a wedged op the
    // deadline already abandoned, so it lands after the DeadlineExceeded throw.
    @Test func onSettledFiresAfterAbandonedOperationTrulyFinishes() async {
        let settled = Counter()
        await #expect(throws: DeadlineExceeded.self) {
            try await runWithDeadline(seconds: 0.1) {
                nonCooperativeBlock(seconds: 0.5)
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

    // While a non-cooperative op is abandoned-but-alive (deadline fired, work still running), a second
    // run must be rejected with Busy rather than starting a concurrent transcribe.
    @Test func secondRunWhileFirstIsWedgedThrowsBusy() async {
        let gate = SingleFlightDeadline()
        let concurrent = Counter()
        async let first: Void = {
            try? await gate.run(seconds: 0.1) {
                await concurrent.bump()
                nonCooperativeBlock(seconds: 0.6)
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
            try await gate.run(seconds: 0.1) { nonCooperativeBlock(seconds: 0.4) }
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

    // A cancel landing before the gate is entered must not launch the operation: the transcribe/finalize
    // op runs as an unstructured task holding the engine lock until it truly settles, so starting one for
    // an already-cancelled dictation would hold the gate Busy against the next dictation and delete a
    // fresh WAV. run() bails with CancellationError before setting inFlight, so the closure never runs.
    @Test func aCancelledCallerNeverEntersTheGate() async {
        let gate = SingleFlightDeadline()
        let ran = Counter()
        let t = Task {
            // Wait for cancellation before entering the gate, else the closure could race ahead of cancel().
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
