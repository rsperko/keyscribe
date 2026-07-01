import Foundation
import Testing
@testable import KeyScribeKit

// A one-shot async gate: callers `wait()` until someone `fire()`s.
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
private final class SpyEngine: SpeechEngine, @unchecked Sendable {
    let id = "spy"
    let displayName = "Spy"
    let supportsRecognitionBias = false

    private let lock = NSLock()
    private var _loadBodies = 0
    private var _loaded = false
    private var _evicted = false
    private var _transcribing = false
    private var _evictOverlappedTranscribe = false

    private let loadGate: Gate?
    private let transcribeGate: Gate?
    init(loadGate: Gate? = nil, transcribeGate: Gate? = nil) {
        self.loadGate = loadGate
        self.transcribeGate = transcribeGate
    }

    var loadBodies: Int { lock.withLock { _loadBodies } }
    var loaded: Bool { lock.withLock { _loaded } }
    var evicted: Bool { lock.withLock { _evicted } }
    var evictOverlappedTranscribe: Bool { lock.withLock { _evictOverlappedTranscribe } }

    func loadIfNeeded() async throws { try await load(progress: nil) }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        lock.withLock { _loadBodies += 1 }
        if let loadGate { await loadGate.wait() }
        lock.withLock { _loaded = true }
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        lock.withLock { _transcribing = true }
        if let transcribeGate { await transcribeGate.wait() }
        lock.withLock { _transcribing = false }
        return "text"
    }

    func evict() async {
        lock.withLock {
            if _transcribing { _evictOverlappedTranscribe = true }
            _evicted = true
            _loaded = false
        }
    }
}

struct SerializedEngineTests {
    // 1.1: two concurrent loads share ONE base.load — the model compiles once, no racing handle write.
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

    // 1.4a: an evict issued while a load is in flight must not drop the eviction — it waits for the load
    // to settle, then evicts. If evict raced ahead of load, the final state would be loaded (evict sets
    // loaded=false, then the completing load sets it true); waiting yields evicted + not loaded.
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

    // 1.4b: an evict must never close the SDK handle out from under a running transcribe (Moonshine's
    // ONNX close = use-after-close/crash). evict waits for the transcribe lock to free.
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

    // The load a transcribe triggers must be in the SAME critical section as base.transcribe, so an
    // evict (and the Settings file delete that follows it) can't slip in after the load settles but
    // before the transcribe runs. Here evict is blocked the whole time the transcribe holds the lock —
    // across its load AND its base.transcribe — so it never overlaps and lands strictly after.
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

    @Test func evictOnUnloadedEngineIsANoOp() async {
        let spy = SpyEngine()
        let engine = SerializedEngine(spy)
        await engine.evict()
        #expect(!spy.evicted)         // nothing to tear down
    }

    @Test func metadataForwardsWithoutLoading() {
        let engine = SerializedEngine(SpyEngine())
        #expect(engine.id == "spy")
        #expect(engine.supportsRecognitionBias == false)
    }
}
