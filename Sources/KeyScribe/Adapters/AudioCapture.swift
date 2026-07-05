import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import KeyScribeKit
import os
import Synchronization

protocol AudioCapturing: AnyObject, Sendable {
    func start(sampleRate: Int) async throws -> URL
    // Bring capture up now but admit only frames at/after `admitAfterHostTime` (mach host time), so a start
    // cue playing under the bring-up never lands in the recording. 0 admits everything (no head gate).
    func start(sampleRate: Int, admitAfterHostTime: UInt64) async throws -> URL
    // Streaming variant (P3-1): each post-conversion mono chunk is also handed to `onSamples` on the writer
    // thread (never the realtime IO thread), so a streaming session can transcribe during capture. `onSamples`
    // nil = batch only. Default forwards to the 2-arg start, dropping the sink, so non-streaming doubles inherit.
    func start(sampleRate: Int, admitAfterHostTime: UInt64, onSamples: (@Sendable ([Float]) -> Void)?) async throws -> URL
    // Latest perceptual mic level (0…1), published from the realtime thread.
    var currentLevel: Float { get }
    func stop() -> URL?
    // Commit-on-release stop: let the callback deliver the buffer that holds the final word.
    func finishDraining() async -> URL?
    // The just-committed capture's in-memory mono PCM (record rate), or nil. Consumes it (one read per
    // capture). Valid only immediately after finishDraining() returns a URL, before the next arm. Default
    // nil so test doubles that only produce a WAV keep the file transcription path.
    func takeDrainedSamples() -> [Float]?
    func prewarm()
    // Rebuild and prewarm the idle unit after wake or long idle.
    func refreshBinding()
    // Empty/nil follows the system default.
    func setPreferredInputUID(_ uid: String?)
}

extension AudioCapturing {
    func prewarm() {}
    func refreshBinding() {}
    func finishDraining() async -> URL? { stop() }
    func takeDrainedSamples() -> [Float]? { nil }
    func setPreferredInputUID(_ uid: String?) {}
    var currentLevel: Float { 0 }
    // Default: ignore the admission boundary. Test doubles inherit this; AudioCapture overrides it.
    func start(sampleRate: Int, admitAfterHostTime: UInt64) async throws -> URL {
        try await start(sampleRate: sampleRate)
    }
    // Default: drop the streaming sink and take the batch path. A streaming double overrides this.
    func start(sampleRate: Int, admitAfterHostTime: UInt64, onSamples: (@Sendable ([Float]) -> Void)?) async throws -> URL {
        try await start(sampleRate: sampleRate, admitAfterHostTime: admitAfterHostTime)
    }
}

enum AudioCaptureError: Error {
    case formatUnavailable
    case preferredInputFailed
    case bringUpTimedOut
}

// Carries a specific unit instance into a queued teardown after `self.unit` may have changed.
private final class UnitBox: @unchecked Sendable {
    let unit: HALInputUnit
    init(_ unit: HALInputUnit) { self.unit = unit }
}

private final class CaptureSession: @unchecked Sendable {
    let url: URL
    let file: AVAudioFile
    // Drains the shared ring to `file` on its own thread (owns the resampler/converter). See CaptureWriter.
    let writer: CaptureWriter
    // Bounds mid-recording restart attempts for this capture.
    var configRestartCount = 0

    init(url: URL, file: AVAudioFile, writer: CaptureWriter) {
        self.url = url
        self.file = file
        self.writer = writer
    }
}

// Device-pinned microphone capture over a raw AUHAL input unit.
final class AudioCapture: AudioCapturing, @unchecked Sendable {
    // HAL control calls can block on transitioning devices, so they run off-main on a swappable queue.
    private var unit: HALInputUnit?
    private var configuredDeviceID: AudioDeviceID?
    private var controlQueue = DispatchQueue(label: "com.keyscribe.audio.0")
    private var generation = 0
    private let producerGeneration = Atomic<Int>(-1)
    // Consumed before the next bring-up to re-resolve the device on a fresh unit/queue.
    private var mustRebuild = false

    private let lock = NSLock()
    // Nil follows the system default; an absent preferred device falls back until it returns.
    private var preferredInputUID: String?
    private var session: CaptureSession?

    // Realtime-thread transport, touched lock-free from the CoreAudio IO thread.
    //
    // `ring` may be resized only while `capturing` is false and the previous writer has joined. The
    // `capturing` release/acquire pair publishes the current ring to the callback.
    private var ring = AudioSampleRing(slotCount: 8, maxFramesPerSlot: 8192, maxChannels: 8)
    private let capturing = Atomic<Bool>(false)
    private let levelBits = Atomic<UInt32>(Float(0).bitPattern)
    private let overloadCount = Atomic<Int>(0)
    // Stashed at teardown so diagnostics survive resizing the ring back to baseline.
    private var lastRingDroppedCount = 0
    // The committed capture's in-memory mono PCM (P2-1), captured when the writer joins on the commit
    // path only (flushConverter == true). Consumed once by the controller via takeDrainedSamples() right
    // after finishDraining() returns; a cancel/stop leaves it untouched (its audio is discarded). Guarded
    // by `lock`.
    private var lastDrainedSamples: [Float]?
    private var overloadListenerBlock: AudioObjectPropertyListenerBlock?
    // Joined by the next arm before resetting the shared ring.
    private var lastWriter: CaptureWriter?
    private var drainGate: TailDrainGate?
    private var drainContinuation: CheckedContinuation<Void, Never>?
    // Lets stale backstop timers fail closed when a newer drain has started.
    private var drainSequence = 0
    private var currentDrainID = 0

    // Bound for a single bring-up.
    private static let bringUpTimeout: Double = 2.0

    // Extra wait for interactive starts so a slow-but-successful device switch can be adopted.
    private static let bringUpGrace: Double = 2.0

    // Input topology listeners keep the idle/prewarmed unit bound to the effective device.
    private let deviceListenerQueue = DispatchQueue(label: "com.keyscribe.audio.device-listener")
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    // Touched only on `deviceListenerQueue`.
    private var topologyDebounce: DispatchWorkItem?
    private var lastEffectiveDeviceID: AudioDeviceID?

    // Mid-recording device-change recovery; restarts capture into the same file on the control queue.
    private var activeDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var activeListenedDeviceID: AudioDeviceID?
    private var activeDeviceDebounce: DispatchWorkItem?
    // Bounds flapping-device restarts per capture.
    private static let maxConfigRestarts = 5
    private static let activeDeviceSelectors: [AudioObjectPropertySelector] =
        [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate]

    init() {
        registerInputListeners()
    }

    deinit {
        if let defaultInputListenerBlock {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, deviceListenerQueue, defaultInputListenerBlock)
        }
        if let deviceListListenerBlock {
            var address = Self.deviceListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, deviceListenerQueue, deviceListListenerBlock)
        }
        removeActiveDeviceListener()
        unit?.dispose()
    }

    func setPreferredInputUID(_ uid: String?) {
        let normalized = (uid?.isEmpty == true) ? nil : uid
        let changed = lock.withLock {
            guard preferredInputUID != normalized else { return false }
            preferredInputUID = normalized
            return true
        }
        guard changed else { return }
        // A new preference re-resolves the effective device. Treat it like a device-topology change:
        // rebuild so the prewarmed unit rebinds, and re-prewarm while idle.
        let recording = lock.withLock { session != nil }
        markRebuild()
        if !recording { prewarm() }
    }

    // Latest perceptual level (0…1), published by the RT callback into an atomic and polled by the HUD meter.
    var currentLevel: Float { Float(bitPattern: levelBits.load(ordering: .relaxed)) }

    func start(sampleRate: Int) async throws -> URL {
        try await start(sampleRate: sampleRate, admitAfterHostTime: 0, onSamples: nil)
    }

    func start(sampleRate: Int, admitAfterHostTime: UInt64) async throws -> URL {
        try await start(sampleRate: sampleRate, admitAfterHostTime: admitAfterHostTime, onSamples: nil)
    }

    func start(sampleRate: Int, admitAfterHostTime: UInt64, onSamples: (@Sendable ([Float]) -> Void)?) async throws -> URL {
        rebuildIfNeeded()
        let (queue, generation) = currentQueueAndGeneration()
        let started = DispatchTime.now()
        do {
            // Non-destructive watchdog: adopt a bring-up that lands within the grace window; only the
            // DeadlineExceeded branch below (a genuinely wedged device) tears the half-open capture down.
            let url = try await runWithDeadline(seconds: Self.bringUpTimeout + Self.bringUpGrace) { [self] in
                try await bringUp(sampleRate: sampleRate, admitAfterHostTime: admitAfterHostTime, onSamples: onSamples, queue: queue, generation: generation)
            }
            let ms = Self.elapsedMs(since: started)
            let band = ms > Self.bringUpTimeout * 1000 ? " grace-adopted" : ""
            Log.audio.debug("bringUp=\(ms, privacy: .public)ms\(band, privacy: .public)")
            return url
        } catch is DeadlineExceeded {
            // The bring-up wedged. The main thread was never blocked — the stuck CoreAudio call is abandoned
            // on the (now unusable) control queue. Swap to a fresh generation + queue EAGERLY (not just a
            // flag consumed by the next dictation): the bump makes the wedged bring-up superseded RIGHT NOW,
            // so if it later un-wedges, every shared-state mutation in armSync/armUnit/bringUpUnit is gated on
            // its generation and no-ops — no stranded hot mic, no clobber of a newer capture. Then drop the
            // half-open file and surface a clean failure.
            Log.audio.error("bringUp timed out after \(Self.elapsedMs(since: started), privacy: .public)ms")
            swapToFreshGeneration()
            discardPendingCapture()
            throw AudioCaptureError.bringUpTimedOut
        }
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    // mach_absolute_time() ticks per second, from the timebase (nanos = ticks * numer / denom). Used to
    // place a cue-end admission boundary on the same host clock the RT buffers are stamped with.
    static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer > 0 else { return 1e9 }
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    // Host-time ticks spanning `seconds`, for offsetting `mach_absolute_time()` by a wall duration.
    static func hostTicks(seconds: Double) -> UInt64 {
        UInt64(max(0, (seconds * hostTicksPerSecond).rounded()))
    }

    private func bringUp(
        sampleRate: Int, admitAfterHostTime: UInt64, onSamples: (@Sendable ([Float]) -> Void)?,
        queue: DispatchQueue, generation: Int
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                do {
                    cont.resume(returning: try armSync(
                        sampleRate: sampleRate, admitAfterHostTime: admitAfterHostTime, onSamples: onSamples, generation: generation))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    // Realize the input HAL unit before the first dictation so capture starts without the one-time
    // unit-realization cost on the hot path. `configure` binds the device and initializes the unit; it does
    // NOT start the IOProc, so the mic indicator never lights. The caller gates this on a granted mic. Runs
    // off-main and watchdogged: a wedged prewarm flags a rebuild rather than stranding the next dictation.
    func prewarm() {
        rebuildIfNeeded()
        // Skip idle realization for Bluetooth; binding can hold the headset in HFP while idle.
        guard !effectiveInputIsBluetooth() else { return }
        let (queue, generation) = currentQueueAndGeneration()
        Task.detached { [self] in
            do {
                try await runWithDeadline(seconds: Self.bringUpTimeout) {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        queue.async { [self] in
                            if isGeneration(generation) { prewarmUnit(generation: generation) }
                            cont.resume()
                        }
                    }
                }
            } catch {
                markRebuild()
            }
        }
    }

    // Control queue only. Configure but do not start a unit for the current effective device.
    private func prewarmUnit(generation: Int) {
        guard let deviceID = effectiveDeviceID() else { return }
        let outgoing = lock.withLock { () -> (keep: Bool, dispose: HALInputUnit?) in
            guard self.generation == generation else { return (true, nil) }
            if unit != nil && configuredDeviceID == deviceID { return (true, nil) }
            let old = unit; unit = nil; configuredDeviceID = nil
            return (false, old)
        }
        outgoing.dispose?.dispose()
        if outgoing.keep { return }
        let candidate = makeUnit(generation: generation)
        do {
            try candidate.configure(deviceID: deviceID)
            let stored = lock.withLock { () -> Bool in
                guard self.generation == generation else { return false }
                unit = candidate; configuredDeviceID = deviceID
                return true
            }
            if !stored { candidate.dispose() }
        } catch {
            candidate.dispose()
        }
    }

    // Sets up the capture file and writer thread, then brings the unit up on the control queue. The ring is
    // reset, the writer starts, and `capturing` flips on before the unit's IOProc goes live.
    private func armSync(sampleRate: Int, admitAfterHostTime: UInt64 = 0,
                         onSamples: (@Sendable ([Float]) -> Void)? = nil, generation: Int) throws -> URL {
        guard let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false) else { throw AudioCaptureError.formatUnavailable }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: recordFormat.settings)

        // Bail before publishing shared state if a watchdog already superseded this arm.
        guard isGeneration(generation) else {
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.bringUpTimedOut
        }

        // Configure before sizing the ring; retry may bind a different default device.
        let target = captureTarget()
        let boundDeviceID: AudioDeviceID
        do {
            boundDeviceID = try configureCaptureDevice(target: target, generation: generation)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        // Quiescent window for resetting/replacing the shared ring before the IOProc starts.
        producerGeneration.store(-1, ordering: .releasing)
        capturing.store(false, ordering: .releasing)
        lock.withLock { lastWriter }?.finish(flushConverter: false)
        let desiredRing = Self.ringGeometry(for: boundDeviceID)
        if ring.matches(desiredRing) {
            ring.reset()
        } else {
            ring = AudioSampleRing(desiredRing)
            Log.audio.debug(
                "ring resized: slots=\(desiredRing.slotCount, privacy: .public) framesPerSlot=\(desiredRing.maxFramesPerSlot, privacy: .public)")
        }
        overloadCount.store(0, ordering: .relaxed)
        levelBits.store(Float(0).bitPattern, ordering: .relaxed)
        let writer = CaptureWriter(
            ring: ring, file: file, recordFormat: recordFormat,
            admitAfterHostTime: admitAfterHostTime, hostTicksPerSecond: Self.hostTicksPerSecond,
            onSamples: onSamples,
            observeHostTime: { [weak self] hostTime in self?.feedDrainGate(hostTime: hostTime) ?? false })
        let mySession = CaptureSession(url: url, file: file, writer: writer)
        // Publish only if this generation still owns the capture slot.
        let published = lock.withLock { () -> Bool in
            guard generation == self.generation else { return false }
            session = mySession
            lastWriter = writer
            return true
        }
        guard published else {
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.bringUpTimedOut
        }
        producerGeneration.store(generation, ordering: .releasing)
        capturing.store(true, ordering: .releasing)
        writer.start()

        // Start the IOProc last so the first buffer lands in the correctly-sized ring.
        do {
            try startConfiguredUnit(generation: generation)
        } catch {
            // A superseded arm must not unwind a newer generation's unit or session.
            if isGeneration(generation) {
                removeActiveDeviceListener()
                disposeUnitInline()
                discardPendingCapture()  // finishes this writer via the session, nils it, deletes the file
            } else {
                writer.finish(flushConverter: false)
                let wasOurs = lock.withLock { () -> Bool in
                    if session === mySession { session = nil; return true } else { return false }
                }
                if wasOurs { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
        guard isGeneration(generation) else { return url }
        installActiveDeviceListener(deviceID: boundDeviceID)
        return url
    }

    // Bind and initialize the target device, retrying a failed system default once.
    private func configureCaptureDevice(target: CaptureTarget, generation: Int) throws -> AudioDeviceID {
        guard let deviceID = target.deviceID else { throw AudioCaptureError.formatUnavailable }
        do {
            try configureUnit(deviceID: deviceID, generation: generation)
            return deviceID
        } catch {
            // A superseded configure must not retry or touch shared state.
            guard isGeneration(generation) else { throw error }
            disposeUnitInline()
            if target.isPreferredPresent { throw AudioCaptureError.preferredInputFailed }
            Thread.sleep(forTimeInterval: 0.25)
            guard let retryID = AudioInputDevices.systemDefaultInputID() else {
                throw AudioCaptureError.formatUnavailable
            }
            do {
                try configureUnit(deviceID: retryID, generation: generation)
                return retryID
            } catch {
                if isGeneration(generation) { disposeUnitInline() }
                throw AudioCaptureError.formatUnavailable
            }
        }
    }

    // Control queue only. Configure a fresh unit unless the resident one already matches.
    private func configureUnit(deviceID: AudioDeviceID, generation: Int) throws {
        guard isGeneration(generation) else { throw AudioCaptureError.bringUpTimedOut }
        if lock.withLock({ self.generation == generation && unit != nil && configuredDeviceID == deviceID }) {
            return
        }
        let fresh = makeUnit(generation: generation)
        try fresh.configure(deviceID: deviceID)
        let outgoing = lock.withLock { () -> (stored: Bool, dispose: HALInputUnit?) in
            guard self.generation == generation else { return (false, nil) }
            let old = unit
            unit = fresh; configuredDeviceID = deviceID
            return (true, old)
        }
        guard outgoing.stored else { fresh.dispose(); throw AudioCaptureError.bringUpTimedOut }
        outgoing.dispose?.dispose()
    }

    // Control queue only. Start the bound unit after the ring and writer are ready.
    private func startConfiguredUnit(generation: Int) throws {
        guard let liveUnit = lock.withLock({ self.generation == generation ? unit : nil }) else {
            throw AudioCaptureError.bringUpTimedOut
        }
        do {
            try liveUnit.start()
        } catch {
            if isGeneration(generation) { disposeUnitInline() }
            throw error
        }
    }

    private func makeUnit(generation: Int) -> HALInputUnit {
        HALInputUnit(handler: { [weak self] buffer, hostTime in
            // Realtime thread: gate, copy to the ring, and publish meter level only.
            guard let self,
                  Self.shouldAcceptRealtimeBuffer(
                    capturing: self.capturing.load(ordering: .acquiring),
                    producerGeneration: self.producerGeneration.load(ordering: .acquiring),
                    unitGeneration: generation
                  ) else { return }
            self.handle(buffer, hostTime: hostTime)
        })
    }

    // MARK: - Commit / cancel teardown

    func finishDraining() async -> URL? {
        await drainTail()
        return teardownAndFinalize()
    }

    private func drainTail() async {
        let releaseHostTime = mach_absolute_time()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let id = lock.withLock { () -> Int in
                drainSequence += 1
                currentDrainID = drainSequence
                drainGate = TailDrainGate(releaseHostTime: releaseHostTime)
                drainContinuation = cont
                return drainSequence
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.resumeDrain(id: id)
            }
        }
    }

    // Writer-thread callback for advancing the drain gate and sealing once it trips.
    @discardableResult
    private func feedDrainGate(hostTime: UInt64?) -> Bool {
        let (tripped, cont) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
            guard var gate = drainGate else { return (false, nil) }
            let outcome = gate.observe(bufferStartHostTime: hostTime)
            drainGate = gate
            guard outcome == .stop else { return (false, nil) }
            let c = drainContinuation
            drainContinuation = nil
            drainGate = nil
            return (true, c)
        }
        cont?.resume()
        return tripped
    }

    // Nil is a forced resume; non-nil backstops must still match the active drain id.
    private func resumeDrain(id: Int? = nil) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard Self.shouldResumeDrain(backstopID: id, currentDrainID: currentDrainID) else { return nil }
            let c = drainContinuation
            drainContinuation = nil
            drainGate = nil
            return c
        }
        cont?.resume()
    }

    static func shouldResumeDrain(backstopID: Int?, currentDrainID: Int) -> Bool {
        guard let backstopID else { return true }
        return backstopID == currentDrainID
    }

    // Close the WAV before detached unit teardown so transcription can start immediately.
    private func teardownAndFinalize() -> URL? {
        let (queue, generation) = currentQueueAndGeneration()
        let url = lock.withLock { session?.url }
        finishWriterAndCloseFile(flushConverter: true)
        if let url { CaptureArchive.archive(url, tag: "commit") }
        Task { [self] in
            do {
                try await runWithDeadline(seconds: Self.bringUpTimeout) {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        queue.async { [self] in
                            teardownUnit(generation: generation)
                            cont.resume()
                        }
                    }
                }
            } catch {
                markRebuild()
            }
        }
        return url
    }

    // Non-Bluetooth units are stopped for reuse; Bluetooth units are disposed to release HFP.
    private func teardownUnit(generation: Int) {
        guard lock.withLock({ Self.shouldTeardownUnit(generation: generation, currentGeneration: self.generation) })
        else { return }
        let bound = lock.withLock { configuredDeviceID }
        switch Self.teardownAction(boundDeviceIsBluetooth: bound.map(AudioInputDevices.isBluetooth)) {
        case .dispose:
            disposeUnitInline()
        case .stop:
            lock.withLock { unit }?.stop()
        }
    }

    static func shouldTeardownUnit(generation: Int, currentGeneration: Int) -> Bool {
        generation == currentGeneration
    }

    enum TeardownAction: Equatable {
        case stop
        case dispose
    }

    static func teardownAction(boundDeviceIsBluetooth: Bool?) -> TeardownAction {
        boundDeviceIsBluetooth == false ? .stop : .dispose
    }

    // Synchronously sever RT → ring → writer → file, join the writer, and release the session's file
    // reference so transcription never reads an open WAV.
    private func finishWriterAndCloseFile(flushConverter: Bool) {
        let s = lock.withLock { () -> CaptureSession? in let s = session; session = nil; return s }
        producerGeneration.store(-1, ordering: .releasing)
        capturing.store(false, ordering: .releasing)
        removeActiveDeviceListener()
        s?.writer.finish(flushConverter: flushConverter)
        // The writer thread has joined; its accumulated PCM is now stable. Keep it only on the commit path
        // (flushConverter) — cancel/stop/discard pass false and their audio is dropped with the session.
        if flushConverter, let s {
            let samples = s.writer.drainedSamples()
            lock.withLock { lastDrainedSamples = samples }
        }
        // Capture-health telemetry: both should be 0 in a healthy run. A non-zero `ringDropped` means the
        // writer thread could not keep up (the ring overran); `overloads` means CoreAudio saw the RT callback
        // miss its deadline. Either is the RT-path canary the ring split is meant to keep quiet.
        lastRingDroppedCount = ring.droppedCount
        Log.audio.debug(
            "capture ended: ringDropped=\(self.lastRingDroppedCount, privacy: .public) overloads=\(self.overloadCount.load(ordering: .relaxed), privacy: .public)")
        // Writer joined and `capturing` is false → the ring is quiescent (the same window armSync uses to
        // reassign it). A capture on a small-period pro interface can have grown it to ~16.7 MiB; a menu-bar
        // app then retains that for the app's lifetime, so shrink back to the baseline geometry here. The
        // next arm re-grows it for the bound device if needed. Zero hot-path cost.
        if !ring.matches(Self.baselineRingGeometry()) {
            ring = AudioSampleRing(Self.baselineRingGeometry())
        }
    }

    // Valid from capture end until the next arm resets the counters.
    func captureDiagnostics() -> (ringDropped: Int, overloads: Int) {
        (lastRingDroppedCount, overloadCount.load(ordering: .relaxed))
    }

    func takeDrainedSamples() -> [Float]? {
        lock.withLock { let s = lastDrainedSamples; lastDrainedSamples = nil; return s }
    }

    // Audio-discarding teardown for cancel()/over-limit abort. Close the file synchronously so the caller
    // can delete it, then queue only the potentially-blocking unit teardown.
    func stop() -> URL? {
        resumeDrain()
        let (queue, generation) = currentQueueAndGeneration()
        let url = lock.withLock { session?.url }
        finishWriterAndCloseFile(flushConverter: false)
        queue.async { [self] in teardownUnit(generation: generation) }
        return url
    }

    // Drop a half-open capture (bring-up threw or timed out): stop the writer and delete the partially
    // written file. Never touches the unit — a wedged one is abandoned via the rebuild flag.
    private func discardPendingCapture() {
        let s = lock.withLock { () -> CaptureSession? in let s = session; session = nil; return s }
        producerGeneration.store(-1, ordering: .releasing)
        capturing.store(false, ordering: .releasing)
        s?.writer.finish(flushConverter: false)
        if let s { try? FileManager.default.removeItem(at: s.url) }
    }

    // MARK: - Buffer handling (realtime IO thread)

    // Copy delivered frames into the shared ring and publish the meter level. The realtime path stays
    // lock-free, allocation-free, and syscall-free; resampling and file I/O happen on the writer thread.
    private func handle(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        ring.write(
            channelCount: channelCount, frameCount: frameCount,
            sampleRate: buffer.format.sampleRate, hostTime: hostTime ?? 0
        ) { c, dest in
            dest.baseAddress!.update(from: channels[c], count: frameCount)
        }
        storeLevel(channels[0], frameCount: frameCount)
    }

    // Publish the latest perceptual level for the HUD meter poll. RMS over channel 0 is an allocation-free
    // vDSP reduction; the result is stored as a Float bit pattern in an atomic the main actor reads.
    private func storeLevel(_ channel: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frameCount))
        levelBits.store(Self.perceptualLevel(rms).bitPattern, ordering: .relaxed)
    }

    // RMS is linear, so speech-range energy clusters near zero and a linear meter barely moves. Map to dB
    // and rescale a [floor, ceiling] window to 0...1 so normal speech spans most of the bar.
    private static func perceptualLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floor: Float = -52
        let ceiling: Float = -12
        return min(1, max(0, (db - floor) / (ceiling - floor)))
    }

    // MARK: - Unit lifecycle / rebuild

    private func currentQueue() -> DispatchQueue { lock.withLock { controlQueue } }
    private func currentGeneration() -> Int { lock.withLock { generation } }
    private func currentQueueAndGeneration() -> (queue: DispatchQueue, generation: Int) {
        lock.withLock { (controlQueue, generation) }
    }
    private func isGeneration(_ g: Int) -> Bool { lock.withLock { generation == g } }
    private func markRebuild() { lock.withLock { mustRebuild = true } }

    // MUST run on the control queue. Dispose the current unit (its realized I/O proc + device hold) and
    // clear the binding, so the next bring-up configures fresh.
    private func disposeUnitInline() {
        let outgoing = lock.withLock { () -> HALInputUnit? in
            let u = unit; unit = nil; configuredDeviceID = nil; return u
        }
        outgoing?.dispose()
    }

    private func rebuildIfNeeded() {
        guard lock.withLock({ mustRebuild }) else { return }
        swapToFreshGeneration()
    }

    // Bump to a fresh generation on a fresh serial control queue, abandoning the outgoing unit's queue. Used
    // both for a flagged rebuild (rebuildIfNeeded) and eagerly on a watchdog timeout, so the wedged bring-up
    // is superseded immediately. Dispose the outgoing unit on its OWN (outgoing) queue, async and
    // fire-and-forget: a HEALTHY outgoing unit gets an orderly dispose serialized off the caller; a WEDGED
    // one simply never disposes on the abandoned queue and the dead unit is left behind — the intended
    // abandonment, with no dealloc on the caller's thread.
    private func swapToFreshGeneration() {
        lock.lock()
        mustRebuild = false
        let outgoing = unit
        let outgoingQueue = controlQueue
        unit = nil
        configuredDeviceID = nil
        generation &+= 1
        controlQueue = DispatchQueue(label: "com.keyscribe.audio.\(generation)")
        lock.unlock()
        if let outgoing {
            let box = UnitBox(outgoing)
            outgoingQueue.async { box.unit.dispose() }
        }
    }

    // MARK: - Ring geometry

    // Target headroom the ring aims to hold so the writer's 5 ms poll plus jitter and a slow write can't
    // overrun it — 6× the poll tick. The 64-slot cap can hold an extreme tiny-buffer device below this target,
    // but never below the poll tick (see AudioSampleRing.geometry / its tests). 64 slots caps the worst-case
    // allocation at ~16.7 MiB.
    private static let ringMinHeadroom = 0.03
    private static let ringMinSlots = 8
    private static let ringMaxSlots = 64
    private static let ringMaxFramesPerSlot = 8192
    private static let ringMaxChannels = 8

    private static func baselineRingGeometry() -> AudioSampleRing.RingGeometry {
        AudioSampleRing.RingGeometry(
            slotCount: ringMinSlots, maxFramesPerSlot: ringMaxFramesPerSlot, maxChannels: ringMaxChannels)
    }

    // Geometry for `deviceID` (the device the imminent bring-up will bind). Reads its IO period + native rate
    // on the control queue (potentially-blocking CoreAudio reads, bounded by the bring-up watchdog). A nil
    // device or a failed read falls back to the baseline, so it never under-provisions.
    private static func ringGeometry(for deviceID: AudioDeviceID?) -> AudioSampleRing.RingGeometry {
        guard let deviceID else { return baselineRingGeometry() }
        return AudioSampleRing.geometry(
            deviceBufferFrames: Int(deviceBufferFrameSize(deviceID)),
            deviceSampleRate: deviceNativeSampleRate(deviceID),
            minHeadroom: ringMinHeadroom, minSlots: ringMinSlots, maxSlots: ringMaxSlots,
            maxFramesPerSlot: ringMaxFramesPerSlot, maxChannels: ringMaxChannels)
    }

    // The device's current IO buffer size in frames (one RT period = one ring slot); 0 on a failed read.
    private static func deviceBufferFrameSize(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    // The device's native input sample rate; with the buffer frame size it sets a period's duration. 0 on fail.
    private static func deviceNativeSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    // MARK: - Preferred-device resolution

    // The device a bring-up should bind: the preferred device if currently connected, else the system
    // default. nil only if even the default can't be read (no input at all).
    private func effectiveDeviceID() -> AudioDeviceID? {
        let uid = lock.withLock { preferredInputUID }
        if let uid, let id = AudioInputDevices.deviceID(forUID: uid) { return id }
        return AudioInputDevices.systemDefaultInputID()
    }

    private func captureTarget() -> CaptureTarget {
        Self.captureTarget(
            preferredUID: lock.withLock { preferredInputUID },
            resolvePreferred: AudioInputDevices.deviceID(forUID:),
            systemDefault: AudioInputDevices.systemDefaultInputID())
    }

    enum CaptureTarget: Equatable {
        case preferred(AudioDeviceID)
        case systemDefault(AudioDeviceID)
        case unavailable

        var deviceID: AudioDeviceID? {
            switch self {
            case let .preferred(id), let .systemDefault(id): return id
            case .unavailable: return nil
            }
        }
        // True only when a preferred device is configured AND currently connected. A failure to bring it up
        // is surfaced (don't silently record from a different mic); a default-follow failure is retried.
        var isPreferredPresent: Bool {
            if case .preferred = self { return true }
            return false
        }
    }

    // Resolve the device to capture from: a present preferred device wins; else the system default; else
    // nothing is available. Pure so the resolution + error-mapping policy is unit-tested without a device.
    static func captureTarget(
        preferredUID: String?, resolvePreferred: (String) -> AudioDeviceID?, systemDefault: AudioDeviceID?
    ) -> CaptureTarget {
        if let uid = preferredUID, !uid.isEmpty, let id = resolvePreferred(uid) { return .preferred(id) }
        if let systemDefault { return .systemDefault(systemDefault) }
        return .unavailable
    }

    // Client stream format for AUHAL after binding the device: Float32, non-interleaved, at the device's
    // native rate and channel count.
    static func clientStreamFormat(nativeSampleRate: Double, nativeChannels: UInt32) -> AVAudioFormat? {
        guard nativeSampleRate > 0, nativeChannels > 0 else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: nativeSampleRate,
            channels: AVAudioChannelCount(nativeChannels), interleaved: false)
    }

    // AUHAL reports 0 ch / 0 Hz for an output-only/mid-churn device; converting or writing that aborts.
    static func isUsableInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    // True when the *effective* input (preferred-if-present, else default) is a Bluetooth headset. Holding
    // such a device open forces it from A2DP (stereo music) to HFP (mono call mode), muting the user's
    // audio — so we avoid holding it while idle and dispose the unit after each dictation.
    private func effectiveInputIsBluetooth() -> Bool {
        guard let id = effectiveDeviceID() else { return false }
        return AudioInputDevices.isBluetooth(id)
    }

    // MARK: - Input topology listeners (idle)

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func registerInputListeners() {
        let handler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleInputTopologyChanged() }
        defaultInputListenerBlock = handler
        deviceListListenerBlock = handler
        var defaultAddr = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, deviceListenerQueue, handler)
        var listAddr = Self.deviceListAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, deviceListenerQueue, handler)
    }

    private func handleInputTopologyChanged() {
        // One physical plug/unplug fires this listener several times; coalesce a burst into a single action
        // by debouncing on the (serial) listener queue.
        topologyDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyTopologyChange() }
        topologyDebounce = work
        deviceListenerQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func applyTopologyChange() {
        let recording = lock.withLock { session != nil }
        let current = effectiveDeviceID()
        if recording {
            // A NEW preferred device appearing or the default switching (follow mode) changes the effective
            // device without the bound device dying — restart onto it. (A disconnect / format flip of the
            // bound device is caught by the active-device listener.)
            if current != lock.withLock({ configuredDeviceID }) { requestMidRecordingRestart() }
            return
        }
        // Skip the rebuild when the effective device is unchanged: the device list churns for reasons that
        // don't affect us. lastEffectiveDeviceID is touched only here (on deviceListenerQueue), no lock.
        guard current != lastEffectiveDeviceID else { return }
        lastEffectiveDeviceID = current
        markRebuild()
        prewarm()
    }

    // Idle-staleness refresh: the resident unit's cached binding rots in place over a long idle or a system
    // sleep (a dead HAL proxy), so the FIRST dictation afterward would otherwise pay a stale realization on
    // the hot path — or, at the watchdog edge, fail. Rebuild + re-prewarm while idle. No-op while recording.
    func refreshBinding() {
        let recording = lock.withLock { session != nil }
        guard !recording else { return }
        markRebuild()
        prewarm()
    }

    // MARK: - Mid-recording device-change recovery

    private func installActiveDeviceListener(deviceID: AudioDeviceID) {
        removeActiveDeviceListener()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleActiveDeviceChanged() }
        for selector in Self.activeDeviceSelectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &addr, deviceListenerQueue, block)
        }
        // Watch the device's IO-overload signal (does NOT trigger a restart — just counts + logs). This is the
        // ground-truth health check for the RT path: a healthy ring split keeps this at 0 even under load.
        let overload: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let n = self.overloadCount.add(1, ordering: .relaxed).newValue
            Log.audio.error("CoreAudio processor overload on capture device (count=\(n, privacy: .public))")
        }
        var overloadAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(deviceID, &overloadAddr, deviceListenerQueue, overload)
        lock.withLock {
            activeDeviceListenerBlock = block; activeListenedDeviceID = deviceID; overloadListenerBlock = overload
        }
    }

    private func removeActiveDeviceListener() {
        let (block, overload, deviceID, pending) = lock.withLock {
            () -> (AudioObjectPropertyListenerBlock?, AudioObjectPropertyListenerBlock?, AudioDeviceID?, DispatchWorkItem?) in
            let b = activeDeviceListenerBlock; let o = overloadListenerBlock
            let d = activeListenedDeviceID; let p = activeDeviceDebounce
            activeDeviceListenerBlock = nil; overloadListenerBlock = nil
            activeListenedDeviceID = nil; activeDeviceDebounce = nil
            return (b, o, d, p)
        }
        // Cancel a debounced restart already scheduled at +150 ms — otherwise it survives teardown and can
        // start a fresh, ownerless capture unit after the mic was supposed to be released (a stranded hot mic).
        pending?.cancel()
        guard let deviceID else { return }
        if let block {
            for selector in Self.activeDeviceSelectors {
                var addr = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(deviceID, &addr, deviceListenerQueue, block)
            }
        }
        if let overload {
            var overloadAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDeviceProcessorOverload, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(deviceID, &overloadAddr, deviceListenerQueue, overload)
        }
    }

    private func handleActiveDeviceChanged() {
        // The bound device disconnected or changed its sample rate (a Bluetooth A2DP↔HFP flip). Coalesce a
        // storm into one restart. The debounce work item is now also cancellable from the control queue
        // (teardown), so guard the reference under the lock.
        let work = DispatchWorkItem { [weak self] in self?.requestMidRecordingRestart() }
        let previous = lock.withLock { () -> DispatchWorkItem? in
            let p = activeDeviceDebounce; activeDeviceDebounce = work; return p
        }
        previous?.cancel()
        deviceListenerQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func requestMidRecordingRestart(expectedSession: CaptureSession? = nil, expectedGeneration: Int? = nil) {
        let queue = currentQueue()
        queue.async { [self] in
            // Bump the live session's restart counter (and bail if the capture already ended) in one
            // critical section, so the cap is enforced against exactly this capture's attempts.
            guard let (attempts, generation, sessionForRetry) = lock.withLock({ () -> (Int, Int, CaptureSession)? in
                guard let session else { return nil }
                if let expectedSession, session !== expectedSession { return nil }
                if let expectedGeneration, !Self.shouldRetryRestart(
                    generation: expectedGeneration, currentGeneration: self.generation, sameSession: true
                ) { return nil }
                session.configRestartCount += 1
                return (session.configRestartCount, self.generation, session)
            }) else { return }
            guard attempts <= Self.maxConfigRestarts else {
                Log.audio.error("mid-recording restart gave up after \(Self.maxConfigRestarts, privacy: .public) attempts — capture may be truncated")
                return
            }
            guard let deviceID = effectiveDeviceID() else { return }
            Log.audio.debug("mid-recording device change → restart attempt \(attempts, privacy: .public)")
            disposeUnitInline()
            do {
                let fresh = makeUnit(generation: generation)
                try fresh.configure(deviceID: deviceID)
                guard Self.shouldStartReplacementUnit(
                    generation: generation,
                    currentGeneration: lock.withLock { self.generation },
                    captureActive: lock.withLock { session != nil }) else {
                    fresh.dispose()
                    return
                }
                do {
                    try fresh.start()
                } catch {
                    fresh.dispose()
                    throw error
                }
                let stored = lock.withLock { () -> Bool in
                    guard self.generation == generation, session != nil else { return false }
                    unit = fresh; configuredDeviceID = deviceID
                    return true
                }
                if !stored {
                    fresh.dispose()
                    return
                }
                installActiveDeviceListener(deviceID: deviceID)
            } catch {
                // A restart can fail transiently precisely because the device is mid-transition (the Bluetooth
                // A2DP↔HFP case that triggered it). Giving up here left the rest of the dictation recording
                // dead air with no signal. Instead schedule a bounded retry — still governed by
                // maxConfigRestarts via configRestartCount — so a device that settles a beat later is picked
                // back up; only after the cap does the partial capture finalize on release.
                disposeUnitInline()
                queue.asyncAfter(deadline: .now() + 0.25) { [self] in
                    requestMidRecordingRestart(expectedSession: sessionForRetry, expectedGeneration: generation)
                }
            }
        }
    }

    static func shouldStartReplacementUnit(generation: Int, currentGeneration: Int, captureActive: Bool) -> Bool {
        generation == currentGeneration && captureActive
    }

    static func shouldRetryRestart(generation: Int, currentGeneration: Int, sameSession: Bool) -> Bool {
        generation == currentGeneration && sameSession
    }

    static func shouldAcceptRealtimeBuffer(capturing: Bool, producerGeneration: Int, unitGeneration: Int) -> Bool {
        capturing && producerGeneration == unitGeneration
    }
}
