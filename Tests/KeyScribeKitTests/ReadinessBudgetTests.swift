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

    @Test func aFasterTransportNeverShortensTheBudget() {
        let budget = ReadinessBudget(allowed: 9.0)
        budget.allow(atLeast: 4.0)
        #expect(budget.allowedSeconds == 9.0)
    }

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
