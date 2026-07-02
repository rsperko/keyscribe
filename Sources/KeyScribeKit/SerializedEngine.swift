import Foundation

// One place that makes engine load/transcribe/evict safe under concurrency (engines-models.md §1.1,
// §1.4). The concrete adapters (Whisper/Qwen/Moonshine) hold their SDK handle in `nonisolated(unsafe)`
// storage and assume "load/evict happen between dictations, never during one" — an assumption the
// Settings download, first-run download, launch preload, self-test, and memory-pressure paths all
// violate, giving concurrent loads that data-race the handle and evictions that tear the handle down
// under a live transcribe (a use-after-close for Moonshine's ONNX session). This actor decorator wraps
// every engine at the registry so those guarantees hold centrally, once:
//
//  - **Single-flight load:** concurrent `load`/`loadIfNeeded` callers share ONE in-flight Task, so the
//    model compiles once no matter how many paths race to warm it.
//  - **Exclusive base access:** a private async lock serializes each `base.load` / `base.transcribe` /
//    `base.evict`, so the non-Sendable SDK handle is never touched by two operations at once.
//  - **Evict awaits settlement:** `evict` waits for an in-flight load to finish and for the transcribe
//    lock, so it never tears the handle down under a running (or deadline-abandoned) transcribe.
public actor SerializedEngine: SpeechEngine {
    private let base: any SpeechEngine
    private var loaded = false
    private var loadInFlight: Task<Void, Error>?
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

    public func loadIfNeeded() async throws { try await load(progress: nil) }

    public func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        if loaded { return }
        let fanout = loadProgress ?? LoadProgressFanout()
        loadProgress = fanout
        let observer = fanout.add(progress)
        defer {
            if let observer { fanout.remove(observer) }
        }
        if let task = loadInFlight { try await task.value; return }
        let task = Task { try await self.performLoad(progress: fanout.report) }
        loadInFlight = task
        try await task.value
    }

    private func performLoad(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        do {
            await acquire()
            defer { release() }
            try await ensureLoadedLocked(progress: progress)
            loadInFlight = nil
            loadProgress = nil
        } catch {
            loadInFlight = nil
            loadProgress = nil
            throw error
        }
    }

    // Loads the base engine if it isn't already loaded. PRECONDITION: the caller holds the exclusive
    // lock. Keeping the load inside the same critical section as the subsequent transcribe means an
    // evict (or the Settings file delete that follows it) can never slip between "load" and "transcribe"
    // — the whole load→transcribe is one protected operation, so base.transcribe never runs against an
    // engine another op just tore down (or whose files were just deleted).
    private func ensureLoadedLocked(progress: (@Sendable (ModelLoadProgress) -> Void)? = nil) async throws {
        if loaded { return }
        try await base.load(progress: progress)
        loaded = true
    }

    public func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        await acquire()
        defer { release() }
        try await ensureLoadedLocked()
        return try await base.transcribe(wavURL: wavURL, biasTerms: biasTerms)
    }

    public func evict() async {
        // Never evict a half-loaded engine or race base.load: wait for an in-flight load to settle first.
        if let task = loadInFlight { _ = try? await task.value }
        // Then take the exclusive lock, which an in-flight (or deadline-abandoned) transcribe still holds
        // — so base.evict never closes the SDK handle out from under a running transcribe.
        await acquire()
        defer { release() }
        guard loaded else { return }
        await base.evict()
        loaded = false
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
