import Foundation
import XCTest
@testable import KeyScribe

private actor VADTestCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private final class VADTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class VADTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 0)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class SpeechPresenceDetectorTests: XCTestCase {
    private struct Failure: Error {}
    private let url = URL(fileURLWithPath: "/tmp/unused-vad-test.wav")

    func testTransientLoadFailureRecoversWithoutRelaunch() async {
        let attempts = VADTestCounter()
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            loadRetryBaseSeconds: 0,
            modelPresent: { true },
            loadManager: {
                if await attempts.increment() == 1 { throw Failure() }
                return SpeechPresenceManager { _, _, _ in [0.9] }
            })

        let first = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        let second = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)

        XCTAssertFalse(first.modelUsed)
        XCTAssertTrue(second.modelUsed)
        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 2)
    }

    func testLoadFailuresUseBoundedRetryDelay() async {
        let attempts = VADTestCounter()
        let clock = VADTestClock()
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            loadRetryBaseSeconds: 10,
            now: { clock.now() },
            modelPresent: { true },
            loadManager: {
                if await attempts.increment() == 1 { throw Failure() }
                return SpeechPresenceManager { _, _, _ in [0.9] }
            })

        _ = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        _ = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        let attemptsBeforeDelay = await attempts.value
        XCTAssertEqual(attemptsBeforeDelay, 1)

        clock.advance(by: 10)
        let recovered = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        let finalAttempts = await attempts.value
        XCTAssertTrue(recovered.modelUsed)
        XCTAssertEqual(finalAttempts, 2)
    }

    func testConcurrentLoadersShareOneInFlightTask() async {
        let attempts = VADTestCounter()
        let gate = VADTestGate()
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            modelPresent: { true },
            loadManager: {
                _ = await attempts.increment()
                await gate.wait()
                return SpeechPresenceManager { _, _, _ in [0.9] }
            })
        let url = url

        async let prewarm: Void = detector.prewarm()
        async let reading = detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        while await attempts.value == 0 { await Task.yield() }
        gate.release()
        _ = await (prewarm, reading)

        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 1)
    }

    func testTimedOutInferencePreventsConcurrentInferenceUntilItSettles() async {
        let calls = VADTestCounter()
        let gate = VADTestGate()
        let settled = VADTestGate()
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 0.01,
            modelPresent: { true },
            loadManager: {
                SpeechPresenceManager { _, _, _ in
                    let call = await calls.increment()
                    if call == 1 {
                        await gate.wait()
                        settled.release()
                    }
                    return [0.9]
                }
            })

        let first = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        let second = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        XCTAssertFalse(first.modelUsed)
        XCTAssertFalse(second.modelUsed)
        let callsBeforeRelease = await calls.value
        XCTAssertEqual(callsBeforeRelease, 1)

        gate.release()
        await settled.wait()
        while await detector.inferenceInFlight() { await Task.yield() }
        let third = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)

        XCTAssertTrue(third.modelUsed)
        let finalCalls = await calls.value
        XCTAssertEqual(finalCalls, 2)
    }
}
