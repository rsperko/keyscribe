import Foundation
import Testing
@testable import KeyScribeKit

// Records what the driver fed it and how it closed it; finalizeThrows models a mid-stream SDK
// failure at commit that must degrade to batch, never surface a partial.
private final class FakeSession: StreamingSpeechSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _appended: [[Float]] = []
    private var _appendCalls = 0
    private var _finalized = false
    private var _cancelled = false
    private let finalizeThrows: Bool
    private let appendThrowsAt: Int?   // 1-based append call at/after which append throws (nil = never)
    private let transcript: String
    init(transcript: String = "streamed", finalizeThrows: Bool = false, appendThrowsAt: Int? = nil) {
        self.transcript = transcript
        self.finalizeThrows = finalizeThrows
        self.appendThrowsAt = appendThrowsAt
    }

    var appendedChunks: [[Float]] { lock.withLock { _appended } }
    var appendedFrames: Int { lock.withLock { _appended.reduce(0) { $0 + $1.count } } }
    var finalized: Bool { lock.withLock { _finalized } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func append(samples: [Float]) async throws {
        let n = lock.withLock { _appendCalls += 1; return _appendCalls }
        if let at = appendThrowsAt, n >= at { throw FakeSessionError() }
        lock.withLock { _appended.append(samples) }
    }
    func finalizeTranscript() async throws -> String {
        lock.withLock { _finalized = true }
        if finalizeThrows { throw FakeSessionError() }
        return transcript
    }
    func cancel() async { lock.withLock { _cancelled = true } }
}

private struct FakeSessionError: Error {}

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double
    init(_ start: Double = 0) { t = start }
    func advance(_ d: Double) { lock.withLock { t += d } }
    func read() -> Double { lock.withLock { t } }
}

private final class SessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _built = 0
    private let make: @Sendable () -> FakeSession
    private let fails: Bool
    init(fails: Bool = false, make: @escaping @Sendable () -> FakeSession = { FakeSession() }) {
        self.make = make
        self.fails = fails
    }
    var built: Int { lock.withLock { _built } }
    var last: FakeSession? { lock.withLock { _last } }
    private var _last: FakeSession?
    func callable() -> @Sendable () async throws -> any StreamingSpeechSession {
        { [self] in
            lock.withLock { _built += 1 }
            if fails { throw FakeSessionError() }
            let s = make()
            lock.withLock { _last = s }
            return s
        }
    }
}

// makeSession blocks inside enter() until a test release()s it, so the test can fire
// cancel()/noteBackpressureDrop() via actor reentrancy while the driver is suspended mid-build.
private actor BuildGate {
    private var buildWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var isBuilding = false
    private var isReleased = false

    func enter() async {
        isBuilding = true
        for w in buildWaiters { w.resume() }
        buildWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilBuilding() async {
        guard !isBuilding else { return }
        await withCheckedContinuation { buildWaiters.append($0) }
    }
    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class GatedSessionFactory: @unchecked Sendable {
    let gate = BuildGate()
    private let lock = NSLock()
    private var _last: FakeSession?
    var last: FakeSession? { lock.withLock { _last } }
    func callable() -> @Sendable () async throws -> any StreamingSpeechSession {
        { [self] in
            await gate.enter()
            let s = FakeSession()
            lock.withLock { _last = s }
            return s
        }
    }
}

// append() blocks until released, modelling a slow/wedged replay append; cancel() releases it
// (the StreamingSpeechSession contract: cancel may unblock an in-flight append).
private actor BlockingAppendSession: StreamingSpeechSession {
    private var appendingWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var isAppending = false
    private var released = false
    private var didCancel = false

    func append(samples: [Float]) async throws {
        isAppending = true
        for w in appendingWaiters { w.resume() }
        appendingWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func finalizeTranscript() async throws -> String { "streamed" }
    func cancel() async {
        didCancel = true
        release()
    }
    func waitUntilAppending() async {
        guard !isAppending else { return }
        await withCheckedContinuation { appendingWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
    var cancelled: Bool { didCancel }
}

struct StreamingDictationDriverTests {
    private func policy(threshold: Double = 4) -> StreamingStartPolicy {
        StreamingStartPolicy(thresholdSeconds: threshold, sampleRate: 16000)
    }

    @Test func shortClipNeverCreatesASessionAndFallsBackToBatch() async {
        let factory = SessionFactory()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        await driver.ingest([Float](repeating: 0, count: 16000))   // 1 s, under 4 s
        let outcome = await driver.finish()
        #expect(factory.built == 0)
        #expect(outcome == .fallBackToBatch)
    }

    @Test func crossingThresholdCreatesSessionReplaysThenStreamsLive() async {
        let factory = SessionFactory()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        for _ in 0..<3 { await driver.ingest([Float](repeating: 0.1, count: 32000)) }
        let outcome = await driver.finish()
        #expect(factory.built == 1)
        #expect(outcome == .streamed("streamed"))
        #expect(factory.last?.appendedFrames == 96000)
        #expect(factory.last?.finalized == true)
    }

    @Test func finalizeThrowFallsBackToBatch() async {
        let factory = SessionFactory(make: { FakeSession(finalizeThrows: true) })
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        for _ in 0..<3 { await driver.ingest([Float](repeating: 0.1, count: 32000)) }
        let outcome = await driver.finish()
        #expect(factory.built == 1)
        #expect(factory.last?.finalized == true)
        #expect(outcome == .fallBackToBatch)
    }

    @Test func sessionBuildFailureFallsBackToBatch() async {
        let factory = SessionFactory(fails: true)
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        for _ in 0..<3 { await driver.ingest([Float](repeating: 0.1, count: 32000)) }
        let outcome = await driver.finish()
        #expect(factory.built == 1)
        #expect(outcome == .fallBackToBatch)
    }

    @Test func cancelClosesSessionWithoutFinalizing() async {
        let factory = SessionFactory()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        for _ in 0..<3 { await driver.ingest([Float](repeating: 0.1, count: 32000)) }
        await driver.cancel()
        #expect(factory.last?.cancelled == true)
        #expect(factory.last?.finalized == false)
    }

    @Test func ingestAfterCancelIsIgnored() async {
        let factory = SessionFactory()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        for _ in 0..<3 { await driver.ingest([Float](repeating: 0.1, count: 32000)) }
        let framesBefore = factory.last?.appendedFrames ?? -1
        await driver.cancel()
        await driver.ingest([Float](repeating: 0.1, count: 32000))
        #expect(factory.last?.appendedFrames == framesBefore)
    }

    @Test func cancelAfterFinishIsANoOp() async {
        let factory = SessionFactory()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        for _ in 0..<3 { await driver.ingest([Float](repeating: 0.1, count: 32000)) }
        _ = await driver.finish()
        await driver.cancel()
        #expect(factory.last?.finalized == true)
        #expect(factory.last?.cancelled == false)
    }

    @Test func appendThrowDuringReplayCancelsSessionAndFallsBackToBatch() async {
        let factory = SessionFactory(make: { FakeSession(appendThrowsAt: 1) })
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        for _ in 0..<3 { await driver.ingest([Float](repeating: 0.1, count: 32000)) }
        let outcome = await driver.finish()
        #expect(factory.built == 1)
        #expect(factory.last?.cancelled == true)
        #expect(factory.last?.finalized == false)
        #expect(outcome == .fallBackToBatch)
    }

    @Test func cancelDuringSessionBuildClosesTheOpenedSessionAndDoesNotLeakIt() async {
        let factory = GatedSessionFactory()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        let ingesting = Task { await driver.ingest([Float](repeating: 0.1, count: 64000)) }  // 4 s → build starts
        await factory.gate.waitUntilBuilding()
        await driver.cancel()                    // reentrant: runs while ingest is suspended in makeSession
        await factory.gate.release()
        await ingesting.value
        #expect(factory.last?.cancelled == true)
        #expect(factory.last?.finalized == false)
        #expect(await driver.didCreateSession == false)
        #expect(await driver.finish() == .fallBackToBatch)
    }

    @Test func backpressureDropDuringSessionBuildClosesTheOpenedSession() async {
        let factory = GatedSessionFactory()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        let ingesting = Task { await driver.ingest([Float](repeating: 0.1, count: 64000)) }
        await factory.gate.waitUntilBuilding()
        await driver.noteBackpressureDrop()
        await factory.gate.release()
        await ingesting.value
        #expect(factory.last?.cancelled == true)
        #expect(await driver.didCreateSession == false)
        #expect(await driver.finish() == .fallBackToBatch)
    }

    @Test func cancelDuringReplayAppendClosesTheOpeningSession() async {
        let session = BlockingAppendSession()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: { session })
        let ingesting = Task { await driver.ingest([Float](repeating: 0.1, count: 64000)) }  // opens, replay append blocks
        await session.waitUntilAppending()
        await driver.cancel()                        // reentrant while the replay append is suspended
        #expect(await session.cancelled == true)
        await session.release()                      // idempotent — cancel already released it
        await ingesting.value
        #expect(await driver.didCreateSession == false)
        #expect(await driver.finish() == .fallBackToBatch)
    }

    @Test func appendThrowOnLiveChunkCancelsSessionAndFallsBackToBatch() async {
        let factory = SessionFactory(make: { FakeSession(appendThrowsAt: 3) })
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        for _ in 0..<3 { await driver.ingest([Float](repeating: 0.1, count: 32000)) }
        let outcome = await driver.finish()
        #expect(factory.built == 1)
        #expect(factory.last?.cancelled == true)
        #expect(outcome == .fallBackToBatch)
    }

    @Test func backpressureDropTripsToBatch() async {
        let factory = SessionFactory()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        for _ in 0..<3 { await driver.ingest([Float](repeating: 0.1, count: 32000)) }   // session open + live
        #expect(factory.built == 1)
        await driver.noteBackpressureDrop()
        let outcome = await driver.finish()
        #expect(await driver.fellBehind)
        #expect(factory.last?.cancelled == true)
        #expect(factory.last?.finalized == false)
        #expect(outcome == .fallBackToBatch)
    }

    @Test func backpressureDropBeforeSessionOpenFallsBackToBatch() async {
        let factory = SessionFactory()
        let driver = StreamingDictationDriver(policy: policy(), makeSession: factory.callable())
        await driver.ingest([Float](repeating: 0.1, count: 16000))   // 1 s, under threshold — no session yet
        await driver.noteBackpressureDrop()
        await driver.ingest([Float](repeating: 0.1, count: 32000))
        let outcome = await driver.finish()
        #expect(factory.built == 0)
        #expect(await driver.fellBehind)
        #expect(outcome == .fallBackToBatch)
    }

    @Test func fallsBehindRealtimeTripsToBatch() async {
        let clock = StepClock()
        let factory = SessionFactory()
        let driver = StreamingDictationDriver(
            policy: policy(), maxLagSeconds: 5, now: { clock.read() }, makeSession: factory.callable())
        await driver.ingest([Float](repeating: 0.1, count: 32000))   // t=0: 2 s buffered
        await driver.ingest([Float](repeating: 0.1, count: 32000))   // t=0: 4 s → session opens, replay
        #expect(factory.built == 1)
        clock.advance(20)                                            // 20 s of wall-clock, only 4 s of audio
        await driver.ingest([Float](repeating: 0.1, count: 32000))   // live chunk → lag 20-6 > 5 → trip
        let outcome = await driver.finish()
        #expect(await driver.fellBehind)
        #expect(factory.last?.cancelled == true)
        #expect(outcome == .fallBackToBatch)
    }
}
