import AVFoundation
import Foundation
import Testing
import XCTest
@testable import KeyScribeApp

private actor VADTestCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private actor VADReceived {
    private(set) var counts: [Int] = []

    func record(_ samples: [Float]) {
        counts.append(samples.count)
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

// `Issue.record` — the shared `Signal`'s default expiry report — does nothing outside a swift-testing test,
// so this XCTest suite routes an expiry to `XCTFail` instead. Bounded for the same reason either way: a
// release that never arrives must fail THIS test, not wedge the run with no result for any test.
private func gateSignal(_ name: String) -> Signal {
    Signal(name, onExpiry: { message, _ in XCTFail(message) })
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
                return SpeechPresenceManager { _ in [0.9] }
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
                return SpeechPresenceManager { _ in [0.9] }
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
        let gate = gateSignal("loadManager.gate")
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            modelPresent: { true },
            loadManager: {
                _ = await attempts.increment()
                await gate.wait()
                return SpeechPresenceManager { _ in [0.9] }
            })
        let url = url

        async let prewarm: Void = detector.prewarm()
        async let reading = detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        while await attempts.value == 0 { await Task.yield() }
        gate.fire()
        _ = await (prewarm, reading)

        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 1)
    }

    func testTimedOutInferencePreventsConcurrentInferenceUntilItSettles() async {
        let calls = VADTestCounter()
        let gate = gateSignal("inference.gate")
        let settled = gateSignal("inference.settled")
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 0.01,
            modelPresent: { true },
            loadManager: {
                SpeechPresenceManager { _ in
                    let call = await calls.increment()
                    if call == 1 {
                        await gate.wait()
                        settled.fire()
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

        gate.fire()
        await settled.wait()
        while await detector.inferenceInFlight() { await Task.yield() }
        let third = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)

        XCTAssertTrue(third.modelUsed)
        let finalCalls = await calls.value
        XCTAssertEqual(finalCalls, 2)
    }

    func testLongTakeGetsAProportionallyLongerInferenceBudget() async {
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 0.01,
            deadlinePerAudioSecond: 0.1,
            modelPresent: { true },
            loadManager: {
                SpeechPresenceManager { _ in
                    try await Task.sleep(for: .milliseconds(100))
                    return [0.9, 0.9]
                }
            })
        await detector.prewarm()

        let long = await detector.read(
            samples: [Float](repeating: 0.5, count: 16_000 * 20), url: url, sampleRate: 16_000)

        XCTAssertTrue(long.modelUsed)
        XCTAssertEqual(long.presence, .speech)
    }

    func testShortTakeKeepsTheBaseInferenceBudget() async {
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 0.01,
            deadlinePerAudioSecond: 0.1,
            modelPresent: { true },
            loadManager: {
                SpeechPresenceManager { _ in
                    try await Task.sleep(for: .milliseconds(500))
                    return [0.9, 0.9]
                }
            })
        await detector.prewarm()

        let short = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)

        XCTAssertFalse(short.modelUsed)
    }

    func testAColdLoadDoesNotSpendTheInferenceBudget() async {
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 0.05,
            loadDeadlineSeconds: 5,
            modelPresent: { true },
            loadManager: {
                try await Task.sleep(for: .milliseconds(200))
                return SpeechPresenceManager { _ in [0.9, 0.9] }
            })

        let reading = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)

        XCTAssertTrue(reading.modelUsed)
    }

    func testALoadPastItsBudgetFailsOpenAndIsReusedOnceItLands() async {
        let attempts = VADTestCounter()
        let gate = gateSignal("load.gate")
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            loadDeadlineSeconds: 0.02,
            modelPresent: { true },
            loadManager: {
                _ = await attempts.increment()
                await gate.wait()
                return SpeechPresenceManager { _ in [0.9, 0.9] }
            })

        let first = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        XCTAssertFalse(first.modelUsed)

        gate.fire()
        await detector.prewarm()
        let second = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)

        XCTAssertTrue(second.modelUsed)
        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 1)
    }

    func testNon16kSamplesAreResampledInMemoryBeforeTheModel() async {
        let received = VADReceived()
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 5,
            modelPresent: { true },
            loadManager: {
                SpeechPresenceManager { samples in
                    await received.record(samples)
                    return [0.9, 0.9]
                }
            })

        let reading = await detector.read(
            samples: Self.tone(seconds: 1, rate: 24_000), url: url, sampleRate: 24_000)

        XCTAssertTrue(reading.modelUsed)
        let counts = await received.counts
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(Double(counts.first ?? 0), 16_000, accuracy: 256)
    }

    func testWavOnlyTakeIsDecodedOnceAt16kForTheModel() async throws {
        let wav = try Self.writeWAV(Self.tone(seconds: 1, rate: 16_000), rate: 16_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let received = VADReceived()
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 5,
            modelPresent: { true },
            loadManager: {
                SpeechPresenceManager { samples in
                    await received.record(samples)
                    return [0.9, 0.9]
                }
            })

        let reading = await detector.read(samples: nil, url: wav, sampleRate: 16_000)

        XCTAssertTrue(reading.modelUsed)
        XCTAssertEqual(reading.presence, .speech)
        let counts = await received.counts
        XCTAssertEqual(counts, [16_000])
    }

    func testDigitallySilentWavOnlyTakeIsSuppressedWithoutTheModel() async throws {
        let wav = try Self.writeWAV([Float](repeating: 0, count: 16_000), rate: 16_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let calls = VADTestCounter()
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 5,
            modelPresent: { true },
            loadManager: {
                SpeechPresenceManager { _ in
                    _ = await calls.increment()
                    return [0.9, 0.9]
                }
            })

        let reading = await detector.read(samples: nil, url: wav, sampleRate: 16_000)

        XCTAssertEqual(reading.presence, .noSpeech)
        XCTAssertFalse(reading.modelUsed)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testDigitallySilentWavOnlyTakeIsSuppressedBeforeTheModelIsAcquired() async throws {
        let wav = try Self.writeWAV([Float](repeating: 0, count: 16_000), rate: 16_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let loads = VADTestCounter()
        let missing = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            modelPresent: { false })
        let unloaded = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            modelPresent: { true },
            loadManager: {
                _ = await loads.increment()
                return SpeechPresenceManager { _ in [0.9, 0.9] }
            })

        let withoutModel = await missing.read(samples: nil, url: wav, sampleRate: 16_000)
        let beforeLoad = await unloaded.read(samples: nil, url: wav, sampleRate: 16_000)

        XCTAssertEqual(withoutModel.presence, .noSpeech)
        XCTAssertEqual(beforeLoad.presence, .noSpeech)
        let loadCount = await loads.value
        XCTAssertEqual(loadCount, 0)
    }

    func testAPreparationPastItsBudgetBlocksTheNextUntilItSettles() async {
        let prepares = VADTestCounter()
        let gate = gateSignal("prepare.gate")
        let settled = gateSignal("prepare.settled")
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 0.02,
            modelPresent: { true },
            loadManager: { SpeechPresenceManager { _ in [0.9, 0.9] } },
            prepareInput: { samples, _, _ in
                if await prepares.increment() == 1 {
                    await gate.wait()
                    settled.fire()
                }
                return samples ?? []
            })
        await detector.prewarm()

        let first = await detector.read(samples: [0.5], url: url, sampleRate: 24_000)
        let second = await detector.read(samples: [0.5], url: url, sampleRate: 24_000)
        XCTAssertFalse(first.modelUsed)
        XCTAssertFalse(second.modelUsed)
        let preparesWhileStuck = await prepares.value
        XCTAssertEqual(preparesWhileStuck, 1)

        gate.fire()
        await settled.wait()
        while await detector.preparationInFlight() { await Task.yield() }
        let third = await detector.read(samples: [0.5], url: url, sampleRate: 24_000)

        XCTAssertTrue(third.modelUsed)
        let finalPrepares = await prepares.value
        XCTAssertEqual(finalPrepares, 2)
    }

    func testInMemoryTakeIsNotPreparedWhileAnInferenceIsStillRunning() async {
        let prepares = VADTestCounter()
        let gate = gateSignal("inference.gate")
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 0.02,
            modelPresent: { true },
            loadManager: {
                SpeechPresenceManager { _ in
                    await gate.wait()
                    return [0.9, 0.9]
                }
            },
            prepareInput: { samples, _, _ in
                _ = await prepares.increment()
                return samples ?? []
            })
        await detector.prewarm()

        _ = await detector.read(samples: [0.5], url: url, sampleRate: 24_000)
        let second = await detector.read(samples: [0.5], url: url, sampleRate: 24_000)
        gate.fire()

        XCTAssertFalse(second.modelUsed)
        let prepareCount = await prepares.value
        XCTAssertEqual(prepareCount, 1)
    }

    func testDigitallySilentWavOnlyTakeIsSuppressedWhileAnInferenceIsStillRunning() async throws {
        let wav = try Self.writeWAV([Float](repeating: 0, count: 16_000), rate: 16_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let gate = gateSignal("inference.gate")
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 0.02,
            modelPresent: { true },
            loadManager: {
                SpeechPresenceManager { _ in
                    await gate.wait()
                    return [0.9, 0.9]
                }
            })
        await detector.prewarm()

        _ = await detector.read(samples: [0.5], url: url, sampleRate: 16_000)
        let inFlight = await detector.inferenceInFlight()
        let silent = await detector.read(samples: nil, url: wav, sampleRate: 16_000)
        gate.fire()

        XCTAssertTrue(inFlight)
        XCTAssertEqual(silent.presence, .noSpeech)
    }

    func testUnreadableWavOnlyTakeFailsOpen() async {
        let detector = SpeechPresenceDetector(
            modelsDir: URL(fileURLWithPath: "/tmp"),
            deadlineSeconds: 5,
            modelPresent: { true },
            loadManager: { SpeechPresenceManager { _ in [0, 0] } })

        let reading = await detector.read(
            samples: nil, url: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav"),
            sampleRate: 16_000)

        XCTAssertEqual(reading.presence, .speech)
        XCTAssertFalse(reading.modelUsed)
    }

    private static func tone(seconds: Double, rate: Int) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(Double($0) * 2 * .pi * 440 / Double(rate))) * 0.5 }
    }

    private static func writeWAV(_ samples: [Float], rate: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vad-detector-\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        return url
    }
}
