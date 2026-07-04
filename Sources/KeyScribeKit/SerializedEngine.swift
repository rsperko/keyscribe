import Foundation

// One place that makes engine load/transcribe/evict safe under concurrency (engines-models.md §1.1,
// §1.4). The concrete adapters (Whisper/Qwen/Moonshine) hold their SDK handle in `nonisolated(unsafe)`
// storage and assume "load/evict happen between dictations, never during one" — an assumption the
// Settings download, first-run download, launch preload, self-test, and memory-pressure paths all
// violate, giving concurrent loads that data-race the handle and evictions that tear the handle down
// under a live transcribe (a use-after-close for Moonshine's ONNX session). This actor decorator wraps
// every engine at the registry so those guarantees hold centrally, once:
//
//  - **Two load levels, forwarded faithfully:** the base engines distinguish a cheap runtime warm
//    (`loadIfNeeded()` — Parakeet loads only the transcription model) from the install path
//    (`load(progress:)` — Parakeet ALSO loads the bias/CTC model). This decorator forwards each flavor
//    to its base counterpart instead of collapsing both into `load(progress:)`, so an empty-dictionary
//    user's warm-on-press never pays the bias model's CoreML load (and never risks a network re-fetch),
//    while the install path still eager-loads it — even after a runtime warm already ran (full ⊋ runtime,
//    and the base loads are idempotent). For the engines where the two are identical the behavior is
//    unchanged.
//  - **Single-flight load, per level:** concurrent warms share ONE `base.loadIfNeeded`; concurrent
//    installs share ONE `base.load`. A runtime waiter may ride an in-flight install (it is a superset),
//    but an install waiter never rides a runtime load (that would skip the bias model).
//  - **Exclusive base access:** a private async lock serializes each `base.load*` / `base.transcribe` /
//    `base.evict`, so the non-Sendable SDK handle is never touched by two operations at once.
//  - **Evict awaits settlement:** `evict` waits for in-flight loads (both levels) to finish and for the
//    transcribe lock, so it never tears the handle down under a running (or deadline-abandoned) transcribe.
public actor SerializedEngine: SpeechEngine {
    private let base: any SpeechEngine
    private var runtimeLoaded = false   // base.loadIfNeeded() has completed
    private var fullLoaded = false      // base.load(progress:) has completed (implies runtimeLoaded)
    private var runtimeInFlight: Task<Void, Error>?
    private var fullInFlight: Task<Void, Error>?
    private var loadProgress: LoadProgressFanout?

    // A fair async mutex guarding every access to the wrapped engine's non-Sendable state.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ base: any SpeechEngine) { self.base = base }

    // Metadata is immutable on the base, so it forwards without isolation.
    public nonisolated var id: String { base.id }
    public nonisolated var displayName: String { base.displayName }
    public nonisolated var supportsRecognitionBias: Bool { base.supportsRecognitionBias }
    public nonisolated var captureSampleRate: Int { base.captureSampleRate }
    public nonisolated var installDirNames: [String] { base.installDirNames }
    public nonisolated func verifyInstalled(in modelsDir: URL) -> Bool? { base.verifyInstalled(in: modelsDir) }

    private func acquire() async {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
    }

    private func release() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    // Runtime warm (warm-on-press / launch preload): ensure only the transcription model. Rides an
    // in-flight install (a superset), else an in-flight/new runtime load. Never triggers the bias load.
    public func loadIfNeeded() async throws {
        if runtimeLoaded || fullLoaded { return }
        if let task = fullInFlight { try await task.value; return }
        if let task = runtimeInFlight { try await task.value; return }
        let task = Task { try await self.performRuntimeLoad() }
        runtimeInFlight = task
        try await task.value
    }

    // Install path (Settings download/verify, first-run): ensure the FULL load (transcription + bias).
    // Must run even when a runtime warm already loaded the transcription model, so the bias model is
    // eager-compiled before the first biased dictation — base.load is idempotent about the part already
    // loaded.
    public func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        if fullLoaded { return }
        let fanout = loadProgress ?? LoadProgressFanout()
        loadProgress = fanout
        let observer = fanout.add(progress)
        defer {
            if let observer { fanout.remove(observer) }
        }
        if let task = fullInFlight { try await task.value; return }
        let task = Task { try await self.performFullLoad(progress: fanout.report) }
        fullInFlight = task
        try await task.value
    }

    private func performRuntimeLoad() async throws {
        do {
            await acquire()
            defer { release() }
            if !runtimeLoaded && !fullLoaded {
                try await base.loadIfNeeded()
                runtimeLoaded = true
            }
            runtimeInFlight = nil
        } catch {
            runtimeInFlight = nil
            throw error
        }
    }

    private func performFullLoad(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        do {
            await acquire()
            defer { release() }
            if !fullLoaded {
                try await base.load(progress: progress)
                fullLoaded = true
                runtimeLoaded = true
            }
            fullInFlight = nil
            loadProgress = nil
        } catch {
            fullInFlight = nil
            loadProgress = nil
            throw error
        }
    }

    // Ensures the runtime model is loaded. PRECONDITION: the caller holds the exclusive lock. Keeping the
    // load inside the same critical section as the subsequent transcribe means an evict (or the Settings
    // file delete that follows it) can never slip between "load" and "transcribe" — the whole
    // load→transcribe is one protected operation, so base.transcribe never runs against an engine another
    // op just tore down (or whose files were just deleted). The bias model, when needed, loads lazily
    // inside base.transcribe (only when bias terms are present), so transcribe never forces it here.
    private func ensureRuntimeLocked() async throws {
        if runtimeLoaded || fullLoaded { return }
        try await base.loadIfNeeded()
        runtimeLoaded = true
    }

    public func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        await acquire()
        defer { release() }
        try await ensureRuntimeLocked()
        return try await base.transcribe(wavURL: wavURL, biasTerms: biasTerms)
    }

    public func evict() async {
        // Never evict a half-loaded engine or race a base load: wait for in-flight loads (either level) to
        // settle first.
        if let task = fullInFlight { _ = try? await task.value }
        if let task = runtimeInFlight { _ = try? await task.value }
        // Then take the exclusive lock, which an in-flight (or deadline-abandoned) transcribe still holds
        // — so base.evict never closes the SDK handle out from under a running transcribe.
        await acquire()
        defer { release() }
        guard runtimeLoaded || fullLoaded else { return }
        await base.evict()
        runtimeLoaded = false
        fullLoaded = false
    }
}

private final class LoadProgressFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (ModelLoadProgress) -> Void] = [:]
    private var last: ModelLoadProgress?

    func add(_ observer: (@Sendable (ModelLoadProgress) -> Void)?) -> UUID? {
        guard let observer else { return nil }
        let id = UUID()
        let current: ModelLoadProgress?
        lock.lock()
        observers[id] = observer
        current = last
        lock.unlock()
        if let current { observer(current) }
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    func report(_ progress: ModelLoadProgress) {
        let callbacks: [@Sendable (ModelLoadProgress) -> Void]
        lock.lock()
        last = progress
        callbacks = Array(observers.values)
        lock.unlock()
        for callback in callbacks { callback(progress) }
    }
}
