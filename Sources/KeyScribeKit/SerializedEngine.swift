import Foundation

// Makes engine load/transcribe/evict safe under concurrency (engines-models.md §1.1, §1.4). Base
// adapters (Whisper/Qwen/Moonshine) hold their SDK handle in `nonisolated(unsafe)` storage assuming
// load/evict never overlap a dictation — which the Settings/first-run download, launch preload,
// self-test, and memory-pressure paths violate (concurrent loads race the handle; an evict under a live
// transcribe is a use-after-close for Moonshine's ONNX session). This actor decorator enforces:
//
//  - **Two load levels, forwarded faithfully:** a cheap runtime warm (`loadIfNeeded()`, no progress) vs
//    the install path (`load(progress:)`, which reports download/compile progress). Forwarded separately,
//    not collapsed, so a warm-on-press stays silent while the Settings install still reports progress and
//    verifies a complete download (base loads idempotent).
//  - **Single-flight load, per level:** concurrent warms share one `base.loadIfNeeded`, installs one
//    `base.load`. A runtime waiter may ride an install (superset); an install waiter never rides a
//    runtime load (would skip the install's download/verify).
//  - **Exclusive base access:** an async lock serializes `base.load*`/`transcribe`/`evict` so the
//    non-Sendable handle is never touched by two ops at once.
//  - **Evict awaits settlement:** waits for in-flight loads (both levels) and the transcribe lock, so it
//    never tears the handle down under a running (or deadline-abandoned) transcribe.
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
    public nonisolated var benefitsFromWarmupClip: Bool { base.benefitsFromWarmupClip }
    public nonisolated var supportsSampleInput: Bool { base.supportsSampleInput }
    public nonisolated var supportsStreaming: Bool { base.supportsStreaming }
    public nonisolated func verifyInstalled(in modelsDir: URL) -> Bool? { base.verifyInstalled(in: modelsDir) }

    // Forward under the exclusive lock so prepare never races a base op on the non-Sendable handle.
    // Without this override the protocol-extension no-op would silently swallow the base implementation.
    public func prepareForDictation() async {
        await acquire()
        defer { release() }
        await base.prepareForDictation()
    }

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
    // Runs even after a runtime warm so the bias model is eager-compiled before the first biased
    // dictation (base.load is idempotent about the part already loaded).
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

    // Ensures the runtime model is loaded. PRECONDITION: caller holds the exclusive lock — keeping load
    // and transcribe in one critical section means an evict (or the Settings file delete after it) can't
    // slip between them, so base.transcribe never runs against a torn-down engine. The bias model loads
    // lazily inside base.transcribe when terms are present, never forced here.
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

    // Same exclusive-lock + load-then-transcribe discipline as the WAV path. Without this override the
    // protocol default throws sampleInputUnsupported even though the base supports samples.
    public func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        await acquire()
        defer { release() }
        try await ensureRuntimeLocked()
        return try await base.transcribe(samples: samples, sampleRate: sampleRate, biasTerms: biasTerms)
    }

    // A streaming session holds the non-Sendable handle for the whole recording, so it must hold the
    // exclusive lock for that whole span, not just this method. Hand back a wrapper that releases the lock
    // exactly once on every terminal path (build-throw, finalize success/throw, cancel) — a leaked lock
    // wedges every later transcribe, hangs evict, and deadlocks the controller's post-throw batch fallback.
    public func makeStreamingSession(sampleRate: Int, biasTerms: [String]) async throws -> any StreamingSpeechSession {
        await acquire()
        do {
            try await ensureRuntimeLocked()
            let session = try await base.makeStreamingSession(sampleRate: sampleRate, biasTerms: biasTerms)
            return LockedStreamingSession(base: session) { [weak self] in await self?.release() }
        } catch {
            release()
            throw error
        }
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

// Releases the SerializedEngine's exclusive lock exactly once, whichever terminal path (finalize
// success/throw, cancel) fires. The once-guard makes a double-release (cancel after a failed finalize)
// impossible.
private final class LockedStreamingSession: StreamingSpeechSession, @unchecked Sendable {
    private let base: any StreamingSpeechSession
    private let onTerminate: @Sendable () async -> Void
    private let releaseLock = NSLock()
    private var released = false

    init(base: any StreamingSpeechSession, onTerminate: @escaping @Sendable () async -> Void) {
        self.base = base
        self.onTerminate = onTerminate
    }

    func append(samples: [Float]) async throws { try await base.append(samples: samples) }

    func finalizeTranscript() async throws -> String {
        do {
            let text = try await base.finalizeTranscript()
            await terminate()
            return text
        } catch {
            await terminate()
            throw error
        }
    }

    func cancel() async {
        await base.cancel()
        await terminate()
    }

    private func terminate() async {
        let first = releaseLock.withLock { () -> Bool in
            if released { return false }
            released = true
            return true
        }
        if first { await onTerminate() }
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
