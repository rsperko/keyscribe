import Foundation
import Testing

// The latch every async test in this target hands control through. Its bound is the thing under test here:
// an unbounded latch does not fail a test, it wedges the whole run, so these pin that an unfired latch ends
// as a NAMED failure and that the ordinary paths never trip that failure.
//
// The expiries are observed through `Signal`'s `onExpiry` seam rather than `withKnownIssue`, so exercising
// the failure path costs the run no standing "known issues" — a permanently yellow summary is how a suite
// stops being read.
struct SignalTests {
    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // `onExpiry` is @Sendable, so what it reports has to land somewhere shared.
    private final class Expiries: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        var reporter: @Sendable (String, SourceLocation) -> Void {
            { [self] message, _ in lock.withLock { messages.append(message) } }
        }
        var all: [String] { lock.withLock { messages } }
    }

    // The regression this type exists for: the wait must END, and say why. The elapsed check proves it
    // honored ITS OWN bound rather than some outer timeout quietly rescuing it.
    @Test func anUnfiredLatchFailsWithinItsBoundInsteadOfHanging() async {
        let expiries = Expiries()
        let clock = ContinuousClock()
        let start = clock.now

        await Signal("never-fired", onExpiry: expiries.reporter).wait(within: 0.2)

        #expect(clock.now - start < .seconds(2))
        #expect(expiries.all.count == 1)
    }

    // The failure has to name the latch: "signal never fired" for one of six latches in a wiring test costs
    // more time than it saves.
    @Test func theReportedExpiryNamesTheLatch() async {
        let expiries = Expiries()

        await Signal("engine.transcribeStarted", onExpiry: expiries.reporter).wait(within: 0.2)

        #expect(expiries.all.first?.contains("engine.transcribeStarted") == true)
    }

    @Test func aFiredLatchReportsNothing() async {
        let expiries = Expiries()
        let signal = Signal("fired", onExpiry: expiries.reporter)
        signal.fire()

        await signal.wait(within: 5)

        #expect(signal.hasFired)
        #expect(expiries.all.isEmpty)
    }

    // Fire-before-wait is the common ordering in these tests: the fake reaches its point of interest before
    // the test gets around to awaiting it.
    @Test func firingBeforeTheWaitIsNotMissed() async {
        let expiries = Expiries()
        let signal = Signal("early", onExpiry: expiries.reporter)
        signal.fire()
        let clock = ContinuousClock()
        let start = clock.now

        await signal.wait(within: 5)

        #expect(clock.now - start < .seconds(1))
        #expect(expiries.all.isEmpty)
    }

    // The copies this replaced kept ONE continuation property, so a second waiter overwrote the first —
    // stranding it forever and leaking a checked continuation. Both waiters must be released by one fire.
    @Test func oneFireReleasesEveryWaiter() async {
        let expiries = Expiries()
        let signal = Signal("multi", onExpiry: expiries.reporter)
        let counter = Counter()
        let first = Task { await signal.wait(within: 5); await counter.bump() }
        let second = Task { await signal.wait(within: 5); await counter.bump() }
        let parked = await settle { signal.waiterCount == 2 }
        #expect(parked, "both waiters must park before the fire, else this proves nothing")

        signal.fire()
        await first.value
        await second.value

        #expect(await counter.value == 2)
        #expect(expiries.all.isEmpty)
    }

    // Each wait owns its own deadline, so a short one expiring must not resume a longer one that is still
    // legitimately waiting — one shared waiter table makes that a real hazard, not a hypothetical.
    @Test func aShortWaitExpiringDoesNotDisturbALongerOne() async {
        let expiries = Expiries()
        let signal = Signal("independent", onExpiry: expiries.reporter)
        let longWaiter = Task { await signal.wait(within: 30) }
        #expect(await settle { signal.waiterCount == 1 })

        await signal.wait(within: 0.2)

        #expect(expiries.all.count == 1, "only the short wait should have expired")
        #expect(signal.waiterCount == 1, "the 30s waiter should still be parked")
        signal.fire()
        await longWaiter.value
    }

    private func settle(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
