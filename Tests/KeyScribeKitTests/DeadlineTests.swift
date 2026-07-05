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
        let start = Date()
        await #expect(throws: DeadlineExceeded.self) {
            try await runWithDeadline(seconds: 0.1) {
                nonCooperativeBlock(seconds: 2)
                return "late"
            }
        }
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    // The SAME late-landing operation a tight deadline throws away is ADOPTED under a widened one — a
    // bring-up that lands just past the base watchdog is returned, not discarded. Mirrors
    // AudioCapture.start() waiting bringUpTimeout + bringUpGrace, not bringUpTimeout alone; without the
    // grace window the stale-binding re-realization at ~2s surfaced as a spurious "Could not start the
    // microphone".
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

    // A success that lands just before the deadline cancels the timer — the cancelled timer must NOT
    // then resume DeadlineExceeded. With the old `try?`-swallowed sleep, timeout.cancel() woke the
    // sleep and the timer proceeded to resume failure anyway, racing the success and intermittently
    // reporting a spurious "timed out" on a transcription that finished in time. Run many close-races.
    @Test func cancelledTimerNeverResumesFailureAfterFastSuccess() async throws {
        for _ in 0..<200 {
            let value = try await runWithDeadline(seconds: 0.05) {
                nonCooperativeBlock(seconds: 0.02)
                return "in-time"
            }
            #expect(value == "in-time")
        }
    }

    // onSettled fires when the operation TRULY finishes, even on a wedged op that the deadline already
    // abandoned — so it lands after the DeadlineExceeded throw, not at the deadline.
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
    // run is rejected with Busy rather than starting a concurrent transcribe.
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

    // Once the wedged op truly settles the gate reopens and the next run proceeds normally.
    @Test func gateReopensAfterOperationSettles() async throws {
        let gate = SingleFlightDeadline()
        await #expect(throws: DeadlineExceeded.self) {
            try await gate.run(seconds: 0.1) { nonCooperativeBlock(seconds: 0.4) }
        }
        try await Task.sleep(for: .seconds(0.6))
        let value = try await gate.run(seconds: 5) { "ok" }
        #expect(value == "ok")
    }

    // A cancel landing before the gate is entered must NOT launch the operation. The transcribe/finalize
    // op runs as an unstructured task that keeps the engine lock until it truly settles, so starting one
    // for a dictation the user already cancelled would hold the gate `Busy` against the next dictation
    // ("Still finishing the previous dictation") and delete a fresh WAV. run() bails with CancellationError
    // before setting inFlight, so the closure never runs and the gate stays open.
    @Test func aCancelledCallerNeverEntersTheGate() async {
        let gate = SingleFlightDeadline()
        let ran = Counter()
        let t = Task {
            // Observe cancellation BEFORE entering the gate, else the closure could run to completion ahead
            // of cancel() and the test would race — the point is that the gate rejects an already-cancelled
            // caller, so cancellation must be in effect at the moment run() is entered.
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
