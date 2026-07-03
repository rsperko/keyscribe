import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import KeyScribeKit
import os
import Synchronization

protocol AudioCapturing: AnyObject, Sendable {
    func start(sampleRate: Int) async throws -> URL
    // Latest perceptual mic level (0…1), published from the RT thread and polled by the controller's HUD
    // meter while recording — no per-buffer main-actor hop.
    var currentLevel: Float { get }
    func stop() -> URL?
    // Commit-on-release stop: let the callback deliver the buffer that holds the final word.
    func finishDraining() async -> URL?
    func prewarm()
    // Rebuild and prewarm the idle unit after wake or long idle.
    func refreshBinding()
    // The user's preferred capture device UID (empty/nil = follow the system default). The adapter holds
    // it standing — the idle device listener consults it independently of any start()/prewarm() call.
    func setPreferredInputUID(_ uid: String?)
}

extension AudioCapturing {
    func prewarm() {}
    func refreshBinding() {}
    func finishDraining() async -> URL? { stop() }
    func setPreferredInputUID(_ uid: String?) {}
    // Real capture publishes a live meter level from the RT thread into an atomic; the controller polls it
    // while recording. Fakes have no meter, so default to silence.
    var currentLevel: Float { 0 }
}

enum AudioCaptureError: Error {
    case formatUnavailable
    case preferredInputFailed
    // Bring-up did not return within the watchdog window — the device (classically a Bluetooth headset
    // mid A2DP↔HFP switch, or a half-transitioned/dead input) wedged a synchronous CoreAudio call. The
    // main thread was never blocked; the dictation fails gracefully and the next attempt rebuilds on a
    // fresh unit + queue.
    case bringUpTimedOut
}

// Carries a specific unit instance into the control queue's @Sendable teardown closure. The instance
// matters: a rebuild may swap self.unit before the queued teardown runs, and we must dispose the one we
// intended to. HALInputUnit is confined to the control queue, so this is safe.
private final class UnitBox: @unchecked Sendable {
    let unit: HALInputUnit
    init(_ unit: HALInputUnit) { self.unit = unit }
}

// All state for one in-flight capture, created on the control queue when a dictation arms and dropped under
// `lock` at teardown. The RT callback copies into the shared ring rather than touching the session.
private final class CaptureSession: @unchecked Sendable {
    let url: URL
    let file: AVAudioFile
    // Drains the shared ring to `file` on its own thread (owns the resampler/converter). See CaptureWriter.
    let writer: CaptureWriter
    // Mid-recording restart attempts for THIS capture; bounds a flapping device. Reset to 0 by being a
    // fresh session per capture.
    var configRestartCount = 0

    init(url: URL, file: AVAudioFile, writer: CaptureWriter) {
        self.url = url
        self.file = file
        self.writer = writer
    }
}

// Device-pinned microphone capture over a raw AUHAL input unit. The unit binds the chosen device directly
// and matches the client format to the device's native format, so selecting a non-default mic has no global
// system-default side effect. All unit control runs off the main thread under a watchdog.
final class AudioCapture: AudioCapturing, @unchecked Sendable {
    // Every HALInputUnit control call (configure/start/stop/dispose) runs on this serial queue, NEVER on
    // the main thread: a transitioning audio device can make those calls block for a long time (or
    // indefinitely), and doing that on `@MainActor` froze the whole app + event tap. Off-main, the worst
    // case is one wedged background thread, bounded by the bring-up watchdog. The queue is swapped (with a
    // fresh unit) when a wedge is detected, so the next dictation never queues behind the stuck call.
    private var unit: HALInputUnit?
    private var configuredDeviceID: AudioDeviceID?
    private var controlQueue = DispatchQueue(label: "com.keyscribe.audio.0")
    private var generation = 0
    private let producerGeneration = Atomic<Int>(-1)
    // Set when a bring-up wedged (watchdog) or a device change invalidated the binding. Consumed by
    // rebuildIfNeeded() before the next bring-up: a fresh unit re-resolves the current effective device; a
    // fresh queue escapes a possibly-wedged one.
    private var mustRebuild = false

    private let lock = NSLock()
    // The user's preferred capture device UID (nil/empty = follow system default). Resolved live each
    // bring-up: preferred device if present, else system default — so an absent preferred device follows
    // the default, and the device-list listener re-prewarms when it returns.
    private var preferredInputUID: String?
    // The single per-dictation capture object (file, writer, restart counter). Non-nil only while a capture
    // is live; created on the control queue in armSync, dropped atomically at teardown.
    private var session: CaptureSession?

    // RT-thread transport, touched lock-free from the CoreAudio IO thread. `capturing` gates the callback
    // (false ⇒ drop the buffer); `levelBits` holds the latest perceptual level for the controller's meter poll.
    //
    // `ring` is a `var` because `armSync` adapts its geometry to the bound device's IO period (baselineRing for
    // the common ~10 ms period; more slots for a small pro-interface buffer). It is reset-in-place or REPLACED
    // ONLY inside the quiescent arm window — after `capturing` is set false and the previous writer joined, and
    // before `capturing` is set true again. The new pointer is published to the RT thread by that
    // `capturing.store(true, .releasing)`, paired with the callback's `capturing.load(.acquiring)`; the ring is
    // never reassigned while `capturing` is true (the mid-recording restart keeps its ring), so the producer
    // and this assignment never overlap.
    private var ring = AudioSampleRing(slotCount: 8, maxFramesPerSlot: 8192, maxChannels: 8)
    private let capturing = Atomic<Bool>(false)
    private let levelBits = Atomic<UInt32>(Float(0).bitPattern)
    // CoreAudio's count of IO-cycle overloads on the bound device for this capture. A healthy capture keeps
    // it at 0.
    private let overloadCount = Atomic<Int>(0)
    private var overloadListenerBlock: AudioObjectPropertyListenerBlock?
    // The most recently created writer, kept so the NEXT capture's arm can JOIN it before it resets the
    // shared ring — closing the narrow window where a cancel's async teardown is still draining the ring on
    // the outgoing control queue while a new dictation arms on a freshly-swapped one. Touched under `lock`.
    private var lastWriter: CaptureWriter?
    // Set while a commit-on-release drain is in flight: each delivered buffer feeds the gate, and the
    // continuation is resumed once a buffer covers the release instant (or a backstop timeout fires).
    private var drainGate: TailDrainGate?
    private var drainContinuation: CheckedContinuation<Void, Never>?
    // Monotonic id for the in-flight drain. The 300 ms backstop captures the id of the drain it was armed
    // for and is ignored if a newer drain has since started — otherwise a backstop from dictation N could
    // resume dictation N+1's drain early and clip its final word (the exact bug the gate prevents).
    private var drainSequence = 0
    private var currentDrainID = 0

    // Bound for a single bring-up. A healthy prewarmed unit starts in a few ms; a legitimately slow
    // Bluetooth profile switch can take several hundred ms; an indefinite wedge is the failure we abandon.
    private static let bringUpTimeout: Double = 2.0

    // Extra window the INTERACTIVE start() path waits past `bringUpTimeout` before hard-failing, so a
    // bring-up that lands just late is ADOPTED rather than discarded. Waiting longer here CANNOT reintroduce
    // the original main-thread freeze: bring-up runs on the off-main control queue, so the main actor only
    // `await`s (never blocks); the deadline exists solely to surface a TRULY wedged device as a clean
    // failure instead of hanging forever. prewarm keeps the tight `bringUpTimeout` — it is background work.
    private static let bringUpGrace: Double = 2.0

    // Two listeners on the system's input topology. While idle the prewarmed unit caches a device binding
    // that nothing refreshes, so a device switch would otherwise leave the hot path bound to a gone/stale
    // device. We watch BOTH the default-input selector (covers "follow the system default") AND the device
    // list (covers a preferred device appearing/disappearing). Either change flags a rebuild and re-prewarms
    // off-main so the next bring-up resolves the current effective device.
    private let deviceListenerQueue = DispatchQueue(label: "com.keyscribe.audio.device-listener")
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    // Coalesces a storm of topology callbacks (one physical plug/unplug fires the listener several times)
    // into a single rebuild, and skips the rebuild when the effective device did not actually change. Both
    // fields are touched ONLY on `deviceListenerQueue`, so they need no lock.
    private var topologyDebounce: DispatchWorkItem?
    private var lastEffectiveDeviceID: AudioDeviceID?

    // Mid-recording device-change recovery (the AUHAL replacement for AVAudioEngineConfigurationChange,
    // which raw AUHAL does not post). While RECORDING we listen on the BOUND device for disconnect
    // (`DeviceIsAlive`) and a sample-rate change (a Bluetooth A2DP↔HFP flip), and restart capture into the
    // same file on the control queue. Touched on the control queue (install/remove) only; the block fires
    // on `deviceListenerQueue`.
    private var activeDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var activeListenedDeviceID: AudioDeviceID?
    private var activeDeviceDebounce: DispatchWorkItem?
    // Bounds a flapping device: each restart attempt increments the live session's counter; past the cap we
    // stop retrying and let the release→finishDraining path finalize the partial capture. The counter lives
    // on the CaptureSession, so it resets to 0 with each fresh capture.
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
        rebuildIfNeeded()
        let (queue, generation) = currentQueueAndGeneration()
        let started = DispatchTime.now()
        do {
            // Non-destructive watchdog: adopt a bring-up that lands within the grace window; only the
            // DeadlineExceeded branch below (a genuinely wedged device) tears the half-open capture down.
            let url = try await runWithDeadline(seconds: Self.bringUpTimeout + Self.bringUpGrace) { [self] in
                try await bringUp(sampleRate: sampleRate, queue: queue, generation: generation)
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

    private func bringUp(
        sampleRate: Int, queue: DispatchQueue, generation: Int
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                do {
                    cont.resume(returning: try armSync(sampleRate: sampleRate, generation: generation))
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
        // Initializing the HAL unit binds and HOLDS the input device. On a Bluetooth headset that pins it to
        // HFP (mono call mode) and mutes the user's music even while idle — the reported bug. Skip the idle
        // realization there and pay the one-time cost on the next dictation instead. Wired/built-in inputs
        // have no A2DP/HFP penalty, so they keep fast prewarm.
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

    // MUST run on the control queue. Configure (but do not start) a unit bound to the current effective
    // device, reusing an already-warm one for that device. Generation-checked at the store: a rebuild that
    // lands DURING the slow configure() supersedes this prewarm, so the freshly-configured candidate is
    // disposed instead of clobbering (and leaking) the new generation's live unit.
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
    private func armSync(sampleRate: Int, generation: Int) throws -> URL {
        guard let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false) else { throw AudioCaptureError.formatUnavailable }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: recordFormat.settings)

        // Bail BEFORE touching any shared state if this arm is already superseded (its generation was bumped
        // by a watchdog swap while it sat queued behind a wedged control queue). A superseded arm that
        // published `session`/`capturing`/the writer would leave the adapter thinking a dead capture is live
        // — suppressing idle behavior, leaking the WAV, and letting a spurious restart push into a
        // consumer-less ring. Everything up to here is a local; drop the file and throw.
        guard isGeneration(generation) else {
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.bringUpTimedOut
        }

        // CONFIGURE the capture device FIRST — bind + initialize the unit, but do NOT start its IOProc yet, so
        // no buffer is delivered until the ring is sized. The retry-to-default lives here because the documented
        // "just-connected device fails while its HAL proxy initializes" failure is an `AudioUnitInitialize`
        // (configure) failure; `configureCaptureDevice` returns the device actually bound (post-retry), so the
        // ring below is sized for EXACTLY the device that will deliver — the geometry can never disagree with
        // the bound device, even on the retry path.
        let target = captureTarget()
        let boundDeviceID: AudioDeviceID
        do {
            boundDeviceID = try configureCaptureDevice(target: target, generation: generation)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        // Gate the RT producer off and join any previous writer before resetting/replacing the shared ring. The
        // just-configured unit's IOProc is NOT started yet, so no buffer is in flight; this is the sole
        // quiescent window in which the ring may be reassigned, and the `capturing.store(true, .releasing)`
        // below publishes the (possibly new) ring to the RT thread.
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
            observeHostTime: { [weak self] hostTime in self?.feedDrainGate(hostTime: hostTime) ?? false })
        let mySession = CaptureSession(url: url, file: file, writer: writer)
        // Publish ONLY if still current, atomically with the generation read: a bump between the guard above
        // and here means a newer generation now owns the capture slot, so do NOT clobber its session — bail and
        // clean up this arm's own local file (the writer was never started, so there is no thread; a bump also
        // disposed our just-configured unit via swapToFreshGeneration, so it does not leak).
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

        // Start the IOProc LAST: `capturing` is already true and the writer already draining, so the first
        // delivered buffer lands in the correctly-sized ring with no head clip.
        do {
            try startConfiguredUnit(generation: generation)
        } catch {
            // Only unwind SHARED capture state (unit/listener) if this bring-up still owns the current
            // generation — a superseded arm must not touch a newer generation's unit/listener. The writer +
            // session + file are THIS arm's own, so always tear them down: finish the writer thread, and clear
            // the shared session ONLY if it still points at our capture by identity (a newer generation may
            // have already published its own, which we must not clobber). `capturing` is intentionally left to
            // the next arm's reset — flipping it false here could race a newer generation's `capturing = true`.
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

    // Resolve + CONFIGURE the capture device (bind + initialize the unit; the IOProc is NOT started here),
    // returning the device actually bound so armSync can size the ring for exactly it. Get the RIGHT microphone
    // live; if a PRESENT preferred device fails, surface that (do not silently record from a different mic).
    // When following the system default, retry once after a beat (a just-connected device can fail the first
    // `AudioUnitInitialize` while its HAL proxy initializes) before giving up. On the control queue.
    private func configureCaptureDevice(target: CaptureTarget, generation: Int) throws -> AudioDeviceID {
        guard let deviceID = target.deviceID else { throw AudioCaptureError.formatUnavailable }
        do {
            try configureUnit(deviceID: deviceID, generation: generation)
            return deviceID
        } catch {
            // Superseded (watchdog-abandoned, generation bumped): do not clobber the newer generation's unit
            // and do not retry — just propagate. The retry path below owns shared state and must only run for
            // the current generation.
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

    // Reuse a resident/prewarmed unit already bound to `deviceID` (a no-op — it is already configured);
    // otherwise configure a fresh one and swap it in under the lock ONLY if this arm still owns the current
    // generation. Does NOT start the IOProc. A superseded configure disposes its own freshly-built unit and
    // throws without touching shared state — so a watchdog-abandoned call can't strand a hot mic. On the
    // control queue.
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

    // Start the IOProc of the unit `configureUnit` bound. Runs after the ring is sized and the writer is
    // draining, so the first delivered buffer is captured. Disposes the unit on a start failure (current
    // generation only) so a configured-but-dead unit does not keep holding the device. On the control queue.
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
            // On the CoreAudio realtime IO thread. Do ONLY lock-free, allocation-free, syscall-free work:
            // gate on `capturing`, copy the frames into the ring, publish the meter level. Everything heavy
            // (resample, file write, drain-gate arbitration) runs on the writer thread draining the ring.
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

    // Called by the WRITER thread once per written slot with that slot's host time (nil ⇒ the RT layer had
    // no valid host time; the gate has a buffer-count fallback). Advances the drain gate and, if it trips,
    // resumes the drain awaiter. Returns true on the trip so the writer seals (flush + stop writing). During
    // normal recording (no drain armed) it is a cheap locked no-op returning false. Off the RT thread.
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

    // `id == nil` is the wildcard resume (gate-covered, or the forced resume from stop()) and always fires.
    // A non-nil id is the backstop's own drain id: it resumes only if it is still the current drain, so a
    // stale backstop cannot resume a newer drain.
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

    // Pure resume-arbitration for the tail drain: a nil id (gate/forced) always resumes; a backstop's own id
    // resumes only while it is still the current drain. Keeps a stale backstop from clipping a newer drain.
    static func shouldResumeDrain(backstopID: Int?, currentDrainID: Int) -> Bool {
        guard let backstopID else { return true }
        return backstopID == currentDrainID
    }

    // Finalize and close the WAV, then return its URL immediately — transcription can start the moment
    // the file is closed and must not wait out the unit teardown (ms wired, 100 ms+ while a Bluetooth unit
    // releases HFP, up to the deadline when wedged). The teardown runs detached: it is generation-guarded
    // so it can never stop or dispose a newer capture's unit, and on a wedge it only flags a rebuild for
    // the next dictation. Mirrors stop()'s fire-and-forget teardown, plus the deadline/markRebuild watchdog.
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
        // Capture-health telemetry: both should be 0 in a healthy run. A non-zero `ringDropped` means the
        // writer thread could not keep up (the ring overran); `overloads` means CoreAudio saw the RT callback
        // miss its deadline. Either is the RT-path canary the ring split is meant to keep quiet.
        Log.audio.debug(
            "capture ended: ringDropped=\(self.ring.droppedCount, privacy: .public) overloads=\(self.overloadCount.load(ordering: .relaxed), privacy: .public)")
    }

    // Valid from capture end until the next arm resets the counters.
    func captureDiagnostics() -> (ringDropped: Int, overloads: Int) {
        (ring.droppedCount, overloadCount.load(ordering: .relaxed))
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
