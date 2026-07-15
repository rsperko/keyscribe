import Foundation
import Testing
@testable import KeyScribeKit

// Reports each read of a real budget, so a test can raise it strictly AFTER the deadline machinery committed
// to the original value — the ordering that distinguishes "extensible" from "raised before it started".
private final class ReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var continuation: CheckedContinuation<Void, Never>?
    let budget: ReadinessBudget

    init(allowed: Double) { budget = ReadinessBudget(allowed: allowed) }

    func allowedSeconds() -> Double {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            reads += 1
            let c = continuation
            continuation = nil
            return c
        }
        c?.resume()
        return budget.allowedSeconds
    }

    // Returns once the timer has read the budget at least once, i.e. it is armed on the current value.
    func waitUntilRead() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let already: Bool = lock.withLock {
                if reads > 0 { return true }
                continuation = cont
                return false
            }
            if already { cont.resume() }
        }
    }
}

struct ReadinessBudgetTests {
    @Test func aSlowerTransportRaisesTheBudget() {
        let budget = ReadinessBudget(allowed: 4.0)
        #expect(budget.allowedSeconds == 4.0)
        budget.allow(atLeast: 9.0)
        #expect(budget.allowedSeconds == 9.0)
    }

    // Churn back onto a fast route must not claw back time already granted to a slow one mid-negotiation.
    @Test func aFasterTransportNeverShortensTheBudget() {
        let budget = ReadinessBudget(allowed: 9.0)
        budget.allow(atLeast: 4.0)
        #expect(budget.allowedSeconds == 9.0)
    }

    // The whole point: a raise that lands AFTER the timer armed on the old value must still be honored, or a
    // route that rebinds onto a slower transport mid-flight dies at the deadline it no longer deserves. The
    // barrier removes the scheduling assumption — the timer has provably read the original budget first.
    @Test func aBudgetRaisedAfterTheTimerArmedIsHonored() async throws {
        let probe = ReadProbe(allowed: 0.3)
        let value = try await runWithBudget(allowedSeconds: { probe.allowedSeconds() }) {
            await probe.waitUntilRead()            // the timer is now armed on 0.3 s
            probe.budget.allow(atLeast: 30.0)      // ...and only then does the rebind buy more time
            try await Task.sleep(for: .milliseconds(900))  // three times the original cliff
            return "delivered"
        }
        #expect(value == "delivered")
    }

    // And the window still ends things: an operation that never finishes dies at its (unraised) budget.
    //
    // The error IDENTITY is the contract, not merely that it throws. Callers branch on DeadlineExceeded to
    // separate a timeout from an ordinary failure (a hung model load is terminal, a transient one retries), and
    // the operation here is cancellation-aware — so a timeout that cancels the work before claiming the gate
    // lets the work's own CancellationError win the race and report a timeout as a plain failure.
    @Test func anOperationThatOutlivesItsBudgetIsAbandoned() async {
        let budget = ReadinessBudget(allowed: 0.02)
        var returned: String?
        var thrown: (any Error)?
        do {
            returned = try await runWithBudget(allowedSeconds: { budget.allowedSeconds }) {
                try await Task.sleep(for: .seconds(30))
                return "never"
            }
        } catch {
            thrown = error
        }
        #expect(returned == nil)
        #expect(thrown is DeadlineExceeded)
    }
}
