import Foundation
import Testing

// One-shot latch for handing control between a test and the code under test: a fake calls `fire()` when it
// reaches the point of interest and the test `await`s `wait()` to get there deterministically, instead of
// sleeping and hoping.
//
// THE BOUND IS THE POINT, and it is what the ten hand-rolled copies this replaces all lacked. An unbounded
// latch does not turn a broken expectation into a failing test — it wedges the whole test PROCESS.
// swift-testing records a failed `#expect` and keeps going, so a test whose premise no longer holds walks
// straight past its own red assertion into a wait nothing will ever satisfy; the run then reports NO result
// for ANY test, and the real one-line failure is invisible. Measured: one stale mode-routing test hid 2439
// passing tests behind a hang that only a SIGKILL ended.
//
// On expiry this records an issue naming the latch and RETURNS, so the caller proceeds to fail on its own
// assertions with the cause already spelled out. Same reasoning as the bounded polling helpers in this
// target (`SpeechModelsModelTests.waitUntil`, `HistoryRetentionSweepTests.pollUntil`) — this closes the
// continuation-latch shape those never covered.
//
// Fire-before-wait safe, and multi-waiter safe: each `wait` carries its own deadline and is resumed
// exactly once, so a second waiter can never strand the first (the copies kept a single continuation
// property, where a second waiter silently clobbered — and leaked — the first).
final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var nextToken = 0
    private var fired = false
    private let name: String
    private let reportExpiry: @Sendable (String, SourceLocation) -> Void

    // `onExpiry` exists so the bound can be TESTED without the run reporting a known issue forever:
    // `withKnownIssue` would mark this suite as carrying known issues on every run, which is exactly the
    // kind of standing yellow that trains people to ignore the summary line. It also lets an XCTest-based
    // suite route an expiry to `XCTFail`, since `Issue.record` does nothing outside a swift-testing test.
    // The name is what an expiry reports, so give it one wherever a test holds more than one latch.
    init(
        _ name: String = "signal",
        onExpiry: (@Sendable (String, SourceLocation) -> Void)? = nil
    ) {
        self.name = name
        self.reportExpiry = onExpiry ?? { message, location in
            Issue.record(Comment(rawValue: message), sourceLocation: location)
        }
    }

    var hasFired: Bool { lock.withLock { fired } }

    // Only SignalTests needs this, to park both waiters before firing — without it the multi-waiter
    // guarantee cannot be tested deterministically, because a fire that beats the waiters proves nothing.
    var waiterCount: Int { lock.withLock { waiters.count } }

    func fire() {
        lock.lock()
        fired = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending.values { waiter.resume(returning: false) }
    }

    // Ten seconds is ~2x the entire suite's wall time, so it cannot flake on a loaded machine, while still
    // failing fast enough to be usable interactively.
    func wait(within seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async {
        let token = lock.withLock { () -> Int in
            nextToken += 1
            return nextToken
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.expire(token)
        }
        let expired = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            waiters[token] = continuation
            lock.unlock()
        }
        timer.cancel()
        guard expired else { return }
        let message = "\(name) never fired within \(seconds)s — the awaited event did not happen, so the "
            + "code under test never reached it. Assertions after this point are unreliable."
        reportExpiry(message, sourceLocation)
    }

    private func expire(_ token: Int) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: token)
        lock.unlock()
        waiter?.resume(returning: true)
    }
}
