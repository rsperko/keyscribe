import Foundation
import Testing
@testable import KeyScribeKit

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func fire() {
        open = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

// Records what the base engine actually did, and whether an evict ever overlapped a running transcribe.
// Models the two-level load split the real engines have: `loadIfNeeded()` is a silent runtime warm, while
// `load(progress:)` is the install path that also reports progress and verifies a complete download.
// `loadBodies` counts the full/install bodies; `runtimeBodies` counts the runtime-only bodies.
private final class SpyEngine: SpeechEngine, @unchecked Sendable {
    let id = "spy"
    let displayName = "Spy"
    let supportsRecognitionBias = false

    private let lock = NSLock()
    private var _loadBodies = 0
    private var _runtimeBodies = 0
    private var _loaded = false
    private var _installBodyRan = false
    private var _evicted = false
    private var _transcribing = false
    private var _evictOverlappedTranscribe = false
    private var _failNextLoad = false
    private var _concurrentTranscribes = 0
    private var _maxConcurrentTranscribes = 0

    private let loadGate: Gate?
    private let transcribeGate: Gate?
    private let streamFinalizeThrows: Bool
    private let makeStreamingSessionThrows: Bool
    init(loadGate: Gate? = nil, transcribeGate: Gate? = nil, failNextLoad: Bool = false,
         streamFinalizeThrows: Bool = false, makeStreamingSessionThrows: Bool = false) {
        self.loadGate = loadGate
        self.transcribeGate = transcribeGate
        self._failNextLoad = failNextLoad
        self.streamFinalizeThrows = streamFinalizeThrows
        self.makeStreamingSessionThrows = makeStreamingSessionThrows
    }

    let supportsStreaming = true
    private var _lastStreamingSession: SpyStreamingSession?
    var lastStreamingSession: SpyStreamingSession? { lock.withLock { _lastStreamingSession } }
    func makeStreamingSession(sampleRate: Int, biasTerms: [String]) async throws -> any StreamingSpeechSession {
        if makeStreamingSessionThrows { throw FakeLoadError() }
        let session = SpyStreamingSession(finalizeThrows: streamFinalizeThrows)
        lock.withLock { _lastStreamingSession = session }
        return session
    }

    var loadBodies: Int { lock.withLock { _loadBodies } }
    var runtimeBodies: Int { lock.withLock { _runtimeBodies } }
    var loaded: Bool { lock.withLock { _loaded } }
    var installBodyRan: Bool { lock.withLock { _installBodyRan } }
    var evicted: Bool { lock.withLock { _evicted } }
    var evictOverlappedTranscribe: Bool { lock.withLock { _evictOverlappedTranscribe } }
    var maxConcurrentTranscribes: Int { lock.withLock { _maxConcurrentTranscribes } }

    private var _prepareCount = 0
    var prepareCount: Int { lock.withLock { _prepareCount } }
    func prepareForDictation() async { lock.withLock { _prepareCount += 1 } }

    let benefitsFromWarmupClip = false

    let supportsSampleInput = true
    private var _sampleTranscribeCalled = false
    private var _lastSampleRate = 0
    var sampleTranscribeCalled: Bool { lock.withLock { _sampleTranscribeCalled } }
    var lastSampleRate: Int { lock.withLock { _lastSampleRate } }
    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        lock.withLock { _sampleTranscribeCalled = true; _lastSampleRate = sampleRate }
        return "samples-text"
    }

    private func failIfRequested() throws {
        let shouldFail = lock.withLock {
            if _failNextLoad { _failNextLoad = false; return true }
            return false
        }
        if shouldFail { throw FakeLoadError() }
    }

    func loadIfNeeded() async throws {
        lock.withLock { _runtimeBodies += 1 }
        if let loadGate { await loadGate.wait() }
        try failIfRequested()
        lock.withLock { _loaded = true }
    }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        lock.withLock { _loadBodies += 1 }
        if let loadGate { await loadGate.wait() }
        try failIfRequested()
        progress?(ModelLoadProgress(phase: "Ready", fraction: 1))
        lock.withLock { _loaded = true; _installBodyRan = true }
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        lock.withLock {
            _transcribing = true
            _concurrentTranscribes += 1
            _maxConcurrentTranscribes = max(_maxConcurrentTranscribes, _concurrentTranscribes)
        }
        if let transcribeGate { await transcribeGate.wait() }
        lock.withLock {
            _transcribing = false
            _concurrentTranscribes -= 1
        }
        return "text"
    }

    func evict() async {
        lock.withLock {
            if _transcribing { _evictOverlappedTranscribe = true }
            _evicted = true
            _loaded = false
            _installBodyRan = false
        }
    }
}

private final class SpyStreamingSession: StreamingSpeechSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _appended: [Float] = []
    private var _finalized = false
    private var _cancelled = false
    private let finalizeThrows: Bool
    init(finalizeThrows: Bool) { self.finalizeThrows = finalizeThrows }

    var appendedCount: Int { lock.withLock { _appended.count } }
    var finalized: Bool { lock.withLock { _finalized } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func append(samples: [Float]) async throws { lock.withLock { _appended.append(contentsOf: samples) } }
    func finalizeTranscript() async throws -> String {
        lock.withLock { _finalized = true }
        if finalizeThrows { throw FakeLoadError() }
        return "stream-text"
    }
    func cancel() async { lock.withLock { _cancelled = true } }
}

private struct FakeLoadError: Error {}

private final class ProgressFractions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ fraction: Double) {
        lock.withLock { values.append(fraction) }
    }

    var all: [Double] {
        lock.withLock { values }
    }
}

struct SerializedEngineTests {
    @Test func prepareForDictationForwardsToBase() async {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        await engine.prepareForDictation()
        #expect(spy.prepareCount == 1)
    }

    @Test func benefitsFromWarmupClipForwardsFromBase() {
        let engine = SerializedEngine(SpyEngine())
        #expect(engine.benefitsFromWarmupClip == false)
    }

    @Test func supportsSampleInputForwardsFromBase() {
        let engine = SerializedEngine(SpyEngine())
        #expect(engine.supportsSampleInput)
    }

    @Test func transcribeSamplesForwardsToBaseAndEnsuresRuntimeModel() async throws {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        let text = try await engine.transcribe(samples: [0, 0.1, -0.1], sampleRate: 24000, biasTerms: [])
        #expect(text == "samples-text")
        #expect(spy.sampleTranscribeCalled)
        #expect(spy.lastSampleRate == 24000)
        #expect(spy.runtimeBodies == 1)   // ensureRuntimeLocked ran before the base transcribe
        #expect(spy.loadBodies == 0)
    }

    @Test func concurrentLoadsRunBaseLoadOnce() async throws {
        let gate = Gate()
        let spy = SpyEngine(loadGate: gate)
        let engine = SerializedEngine(spy)
        async let a: Void = try engine.load(progress: nil)
        async let b: Void = try engine.load(progress: nil)
        try await Task.sleep(for: .milliseconds(30))   // let both reach their await while base.load is gated
        #expect(spy.loadBodies == 1)
        await gate.fire()
        _ = try await (a, b)
        #expect(spy.loadBodies == 1)
        #expect(spy.loaded)
    }

    @Test func concurrentLoadProgressIsDeliveredToEveryCaller() async throws {
        let gate = Gate()
        let spy = SpyEngine(loadGate: gate)
        let engine = SerializedEngine(spy)
        let a = ProgressFractions()
        let b = ProgressFractions()
        async let first: Void = try engine.load { a.append($0.fraction) }
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = try engine.load { b.append($0.fraction) }
        try await Task.sleep(for: .milliseconds(20))
        await gate.fire()
        _ = try await (first, second)
        #expect(a.all == [1])
        #expect(b.all == [1])
        #expect(spy.loadBodies == 1)
    }

    @Test func failedLoadClearsBeforeWaitersReturnSoImmediateRetryReloads() async throws {
        let gate = Gate()
        let spy = SpyEngine(loadGate: gate, failNextLoad: true)
        let engine = SerializedEngine(spy)
        async let first: Void = try engine.load(progress: nil)
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = try engine.load(progress: nil)
        try await Task.sleep(for: .milliseconds(20))
        await gate.fire()
        do {
            try await first
            #expect(Bool(false))
        } catch is FakeLoadError {
        } catch {
            #expect(Bool(false))
        }
        do {
            try await second
            #expect(Bool(false))
        } catch is FakeLoadError {
        } catch {
            #expect(Bool(false))
        }
        try await engine.load(progress: nil)
        #expect(spy.loadBodies == 2)
        #expect(spy.loaded)
    }

    @Test func evictWaitsForInFlightLoad() async throws {
        let gate = Gate()
        let spy = SpyEngine(loadGate: gate)
        let engine = SerializedEngine(spy)
        async let load: Void = try engine.load(progress: nil)
        try await Task.sleep(for: .milliseconds(20))
        async let evict: Void = engine.evict()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!spy.evicted)         // evict is blocked waiting for the load
        await gate.fire()
        _ = try await load
        await evict
        #expect(spy.evicted)
        #expect(!spy.loaded)          // proves evict ran AFTER the load settled, not before
    }

    @Test func evictWaitsForInFlightTranscribe() async throws {
        let gate = Gate()
        let spy = SpyEngine(transcribeGate: gate)
        let engine = SerializedEngine(spy)
        try await engine.loadIfNeeded()
        async let t: String = try engine.transcribe(wavURL: URL(fileURLWithPath: "/x"), biasTerms: [])
        try await Task.sleep(for: .milliseconds(20))
        async let evict: Void = engine.evict()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!spy.evicted)         // evict blocked on the transcribe lock
        await gate.fire()
        _ = try await t
        await evict
        #expect(spy.evicted)
        #expect(!spy.evictOverlappedTranscribe)
    }

    @Test func loadAndTranscribeAreOneOperationVersusEvict() async throws {
        let loadGate = Gate()
        let spy = SpyEngine(loadGate: loadGate)   // base.load blocks; base.transcribe is instant
        let engine = SerializedEngine(spy)
        async let t: String = try engine.transcribe(wavURL: URL(fileURLWithPath: "/x"), biasTerms: [])
        try await Task.sleep(for: .milliseconds(20))   // transcribe now holds the lock, stuck in base.load
        async let evict: Void = engine.evict()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!spy.evicted)                           // evict cannot acquire while transcribe holds it
        await loadGate.fire()
        let text = try await t
        await evict
        #expect(text == "text")                         // the transcribe ran
        #expect(!spy.evictOverlappedTranscribe)         // evict landed strictly after, never mid-transcribe
        #expect(spy.evicted)
    }

    @Test func concurrentTranscribesOnTheSameEngineNeverRunSimultaneously() async throws {
        let gate = Gate()
        let spy = SpyEngine(transcribeGate: gate)
        let engine = SerializedEngine(spy)
        try await engine.loadIfNeeded()
        async let first: String = try engine.transcribe(wavURL: URL(fileURLWithPath: "/a"), biasTerms: [])
        try await Task.sleep(for: .milliseconds(20))
        async let second: String = try engine.transcribe(wavURL: URL(fileURLWithPath: "/b"), biasTerms: [])
        try await Task.sleep(for: .milliseconds(20))
        await gate.fire()
        _ = try await (first, second)
        #expect(spy.maxConcurrentTranscribes == 1)
    }

    @Test func supportsStreamingForwardsFromBase() {
        let engine = SerializedEngine(SpyEngine())
        #expect(engine.supportsStreaming)
    }

    @Test func makeStreamingSessionForwardsAppendAndFinalize() async throws {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        let session = try await engine.makeStreamingSession(sampleRate: 16000, biasTerms: [])
        #expect(spy.runtimeBodies == 1)   // ensureRuntimeLocked ran before the base session was built
        try await session.append(samples: [0, 0.1, -0.1])
        try await session.append(samples: [0.2])
        let text = try await session.finalizeTranscript()
        #expect(text == "stream-text")
        #expect(spy.lastStreamingSession?.appendedCount == 4)
        #expect(spy.lastStreamingSession?.finalized == true)
    }

    @Test func streamingSessionHoldsLockUntilFinalize() async throws {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        let session = try await engine.makeStreamingSession(sampleRate: 16000, biasTerms: [])
        async let evict: Void = engine.evict()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!spy.evicted)             // evict blocked on the lock the session holds
        _ = try await session.finalizeTranscript()
        await evict
        #expect(spy.evicted)              // released on finalize, so evict could proceed
    }

    @Test func streamingSessionReleasesLockOnFinalizeThrow() async throws {
        let spy = SpyEngine(streamFinalizeThrows: true)
        let engine = SerializedEngine(spy)
        let session = try await engine.makeStreamingSession(sampleRate: 16000, biasTerms: [])
        do {
            _ = try await session.finalizeTranscript()
            #expect(Bool(false))
        } catch is FakeLoadError {
        } catch {
            #expect(Bool(false))
        }
        let text = try await engine.transcribe(wavURL: URL(fileURLWithPath: "/x"), biasTerms: [])
        #expect(text == "text")           // did not deadlock → the lock was released on the throw
    }

    @Test func streamingSessionReleasesLockOnCancel() async throws {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        let session = try await engine.makeStreamingSession(sampleRate: 16000, biasTerms: [])
        await session.cancel()
        #expect(spy.lastStreamingSession?.cancelled == true)
        let text = try await engine.transcribe(wavURL: URL(fileURLWithPath: "/x"), biasTerms: [])
        #expect(text == "text")           // lock released on cancel → no deadlock
    }

    @Test func makeStreamingSessionReleasesLockWhenBuildThrows() async throws {
        let spy = SpyEngine(makeStreamingSessionThrows: true)
        let engine = SerializedEngine(spy)
        do {
            _ = try await engine.makeStreamingSession(sampleRate: 16000, biasTerms: [])
            #expect(Bool(false))
        } catch is FakeLoadError {
        } catch {
            #expect(Bool(false))
        }
        let text = try await engine.transcribe(wavURL: URL(fileURLWithPath: "/x"), biasTerms: [])
        #expect(text == "text")           // lock released on the build throw → no deadlock
    }

    @Test func evictOnUnloadedEngineIsANoOp() async {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        await engine.evict()
        #expect(!spy.evicted)
    }

    @Test func metadataForwardsWithoutLoading() {
        let engine = SerializedEngine(SpyEngine())
        #expect(engine.id == "spy")
        #expect(engine.supportsRecognitionBias == false)
    }

    @Test func runtimeWarmRunsOnlyTheRuntimeBodyNotInstall() async throws {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        try await engine.loadIfNeeded()
        #expect(spy.runtimeBodies == 1)
        #expect(spy.loadBodies == 0)
        #expect(spy.loaded)
        #expect(!spy.installBodyRan)
    }

    @Test func installLoadRunsTheInstallBody() async throws {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        try await engine.load(progress: nil)
        #expect(spy.loadBodies == 1)
        #expect(spy.installBodyRan)
    }

    @Test func installAfterAWarmStillRunsTheInstallBody() async throws {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        try await engine.loadIfNeeded()
        #expect(!spy.installBodyRan)
        try await engine.load(progress: nil)
        #expect(spy.loadBodies == 1)
        #expect(spy.installBodyRan)
    }

    @Test func warmAfterAnInstallIsANoOp() async throws {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        try await engine.load(progress: nil)
        try await engine.loadIfNeeded()
        #expect(spy.runtimeBodies == 0)   // the full load already covered runtime
        #expect(spy.loadBodies == 1)
    }

    @Test func transcribeEnsuresOnlyTheRuntimeModel() async throws {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        _ = try await engine.transcribe(wavURL: URL(fileURLWithPath: "/x"), biasTerms: [])
        #expect(spy.runtimeBodies == 1)
        #expect(spy.loadBodies == 0)
        #expect(!spy.installBodyRan)
    }

    @Test func concurrentWarmsRunBaseRuntimeLoadOnce() async throws {
        let gate = Gate()
        let spy = SpyEngine(loadGate: gate)
        let engine = SerializedEngine(spy)
        async let a: Void = try engine.loadIfNeeded()
        async let b: Void = try engine.loadIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(spy.runtimeBodies == 1)
        await gate.fire()
        _ = try await (a, b)
        #expect(spy.runtimeBodies == 1)
        #expect(spy.loaded)
        #expect(!spy.installBodyRan)
    }
}
