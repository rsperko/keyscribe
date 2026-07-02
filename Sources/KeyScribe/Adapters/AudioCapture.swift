import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import KeyScribeKit
import os

protocol AudioCapturing: AnyObject, Sendable {
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL
    func stop() -> URL?
    // Commit-on-release stop: let the callback deliver the buffer that holds the final word before tearing
    // the unit down, so the tail is not clipped. Falls back to an immediate stop for test fakes.
    func finishDraining() async -> URL?
    func prewarm()
    // Rebuild + re-prewarm the idle unit's device binding without any topology change having fired. A
    // resident unit's cached CoreAudio binding can rot in place while the app sits idle (or the system
    // sleeps), so the caller drives this on wake / after long idle to refresh the hot path.
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

// Boxes the (non-Sendable) live buffer + a one-shot flag for AVAudioConverter's @Sendable input block.
// Reused across buffers (the callback delivers serially, like the shared outBuffer it sits beside) so the
// resampling path does not heap-allocate on every delivered buffer.
private final class FeedOnce: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    var consumed = false
}

// Carries a specific unit instance into the control queue's @Sendable teardown closure. The instance
// matters: a rebuild may swap self.unit before the queued teardown runs, and we must dispose the one we
// intended to. HALInputUnit is confined to the control queue, so this is safe.
private final class UnitBox: @unchecked Sendable {
    let unit: HALInputUnit
    init(_ unit: HALInputUnit) { self.unit = unit }
}

// Device-pinned microphone capture over a raw AUHAL input unit (HALInputUnit). The unit binds the chosen
// device on its own `CurrentDevice` and matches the client format to the device's native format, so
// selecting a non-default mic has NO global side effect — we NEVER change the macOS system default input
// (the antipattern the previous AVAudioEngine implementation used to dodge -10868, and that every other
// reputable recorder avoids). All engine control (`configure`/`start`/`stop`/`dispose`) runs off the main
// thread on a serial queue under a watchdog, because those calls can block on a transitioning device.
final class AudioCapture: AudioCapturing, @unchecked Sendable {
    // Every HALInputUnit control call (configure/start/stop/dispose) runs on this serial queue, NEVER on
    // the main thread: a transitioning audio device can make those calls block for a long time (or
    // indefinitely), and doing that on `@MainActor` froze the whole app + event tap. Off-main, the worst
    // case is one wedged background thread, bounded by the bring-up watchdog. The queue is swapped (with a
    // fresh unit) when a wedge is detected, so the next dictation never queues behind the stuck call.
    private var unit: HALInputUnit?
    private var configuredDeviceID: AudioDeviceID?
    // The generation the currently-stored unit belongs to. A bring-up that was abandoned by the watchdog
    // (its generation superseded) keeps running on its now-orphaned queue; when it finally stores its unit
    // it stamps this with its OWN generation, so the eager-rebuild cleanup queued behind it can dispose that
    // late unit without touching a newer generation's live unit.
    private var configuredGeneration: Int?
    private var controlQueue = DispatchQueue(label: "com.keyscribe.audio.0")
    private var generation = 0
    // Set when a bring-up wedged (watchdog) or a device change invalidated the binding. Consumed by
    // rebuildIfNeeded() before the next bring-up: a fresh unit re-resolves the current effective device; a
    // fresh queue escapes a possibly-wedged old one.
    private var mustRebuild = false

    private let lock = NSLock()
    // The user's preferred capture device UID (nil/empty = follow system default). Resolved live each
    // bring-up: preferred device if present, else system default — so an absent preferred device follows
    // the default, and the device-list listener re-prewarms when it returns.
    private var preferredInputUID: String?
    private var file: AVAudioFile?
    private var currentURL: URL?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var recordFormat: AVAudioFormat?
    // Resamples the mic's native format down to the engine's target rate/mono so the WAV is written at the
    // rate STT wants — no oversized capture file, no decode-time resample. Built lazily from the format the
    // callback actually delivers and rebuilt if the hardware format changes mid-stream. Reused across
    // callbacks (the callback fires serially).
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var outBuffer: AVAudioPCMBuffer?
    private let feed = FeedOnce()
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
    // Bounds a flapping device: each restart attempt increments this; past the cap we stop retrying and let
    // the release→finishDraining path finalize the partial capture. Reset when a new capture is armed.
    private var configRestartCount = 0
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
        let recording = lock.withLock { currentURL != nil }
        markRebuild()
        if !recording { prewarm() }
    }

    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL {
        rebuildIfNeeded()
        let queue = currentQueue()
        let generation = currentGeneration()
        let started = DispatchTime.now()
        do {
            // Non-destructive watchdog: adopt a bring-up that lands within the grace window; only the
            // DeadlineExceeded branch below (a genuinely wedged device) tears the half-open capture down.
            let url = try await runWithDeadline(seconds: Self.bringUpTimeout + Self.bringUpGrace) { [self] in
                try await bringUp(sampleRate: sampleRate, levelHandler: levelHandler, queue: queue, generation: generation)
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
        sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void,
        queue: DispatchQueue, generation: Int
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                do {
                    cont.resume(returning: try armSync(
                        sampleRate: sampleRate, levelHandler: levelHandler, generation: generation))
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
        let queue = currentQueue()
        let generation = currentGeneration()
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
            let old = unit; unit = nil; configuredDeviceID = nil; configuredGeneration = nil
            return (false, old)
        }
        outgoing.dispose?.dispose()
        if outgoing.keep { return }
        let candidate = makeUnit()
        do {
            try candidate.configure(deviceID: deviceID)
            let stored = lock.withLock { () -> Bool in
                guard self.generation == generation else { return false }
                unit = candidate; configuredDeviceID = deviceID; configuredGeneration = generation
                return true
            }
            if !stored { candidate.dispose() }
        } catch {
            candidate.dispose()
        }
    }

    // Sets up the capture file + recording state, then brings the unit up — all on the control queue.
    private func armSync(
        sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void, generation: Int
    ) throws -> URL {
        guard let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false) else { throw AudioCaptureError.formatUnavailable }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: recordFormat.settings)

        lock.lock()
        self.file = file
        self.currentURL = url
        self.levelHandler = levelHandler
        self.recordFormat = recordFormat
        self.converter = nil
        self.converterInputFormat = nil
        self.outBuffer = nil
        self.configRestartCount = 0
        lock.unlock()

        do {
            try armUnit(generation: generation)
        } catch {
            // Only unwind shared capture state if this bring-up still owns the current generation. A
            // watchdog-abandoned armSync that finally un-wedges is superseded, and the newer generation may
            // already be recording — clearing its unit/listener/currentURL here would corrupt it.
            if isGeneration(generation) {
                removeActiveDeviceListener()
                disposeUnitInline()
                discardPendingCapture()
            }
            throw error
        }
        return url
    }

    // Bring the unit up on the resolved capture device, escalating on failure. Get the RIGHT microphone
    // live; if a PRESENT preferred device fails, surface that (do not silently record from a different mic).
    // When following the system default, retry once after a beat (a just-connected device can fail the first
    // bring-up while its HAL proxy initializes) before giving up.
    private func armUnit(generation: Int) throws {
        let target = captureTarget()
        guard let deviceID = target.deviceID else { throw AudioCaptureError.formatUnavailable }
        do {
            try bringUpUnit(deviceID: deviceID, generation: generation)
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
            do { try bringUpUnit(deviceID: retryID, generation: generation) }
            catch {
                if isGeneration(generation) { disposeUnitInline() }
                throw AudioCaptureError.formatUnavailable
            }
        }
        guard isGeneration(generation) else { return }
        if let id = lock.withLock({ configuredDeviceID }) { installActiveDeviceListener(deviceID: id) }
    }

    // Reuse a resident/prewarmed unit already bound to `deviceID` (just start it); otherwise configure +
    // start a fresh one, swapping it in under the lock ONLY if this bring-up still owns the current
    // generation. A superseded bring-up disposes its own freshly-built unit and throws without ever starting
    // it or touching shared state — so a watchdog-abandoned call can't strand a hot mic. On the control queue.
    private func bringUpUnit(deviceID: AudioDeviceID, generation: Int) throws {
        guard isGeneration(generation) else { throw AudioCaptureError.bringUpTimedOut }
        if let resident = lock.withLock({
            self.generation == generation && unit != nil && configuredDeviceID == deviceID ? unit : nil
        }) {
            guard isGeneration(generation) else { throw AudioCaptureError.bringUpTimedOut }
            try resident.start()
            return
        }
        let fresh = makeUnit()
        try fresh.configure(deviceID: deviceID)
        guard isGeneration(generation) else { fresh.dispose(); throw AudioCaptureError.bringUpTimedOut }
        do {
            try fresh.start()
        } catch {
            fresh.dispose()
            throw error
        }
        let outgoing = lock.withLock { () -> (stored: Bool, dispose: HALInputUnit?) in
            guard self.generation == generation else { return (false, nil) }
            let old = unit
            unit = fresh; configuredDeviceID = deviceID; configuredGeneration = generation
            return (true, old)
        }
        guard outgoing.stored else { fresh.dispose(); throw AudioCaptureError.bringUpTimedOut }
        outgoing.dispose?.dispose()
    }

    private func makeUnit() -> HALInputUnit {
        HALInputUnit(handler: { [weak self] buffer, hostTime in
            guard let self else { return }
            self.handle(buffer)
            self.feedDrainGate(hostTime: hostTime)
        })
    }

    // MARK: - Commit / cancel teardown

    func finishDraining() async -> URL? {
        await drainTail()
        return await teardownAndFinalize()
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

    private func feedDrainGate(hostTime: UInt64?) {
        lock.lock()
        guard var gate = drainGate else { lock.unlock(); return }
        let outcome = gate.observe(bufferStartHostTime: hostTime)
        drainGate = gate
        lock.unlock()
        if outcome == .stop { resumeDrain() }
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

    // Commit path: tear the unit down on the control queue (stop/dispose can block on a transitioning
    // device), watchdogged so a wedge can't hang the commit. Finalizing (closing) the WAV happens only
    // AFTER the callback is stopped, so no in-flight buffer write races the close. A non-Bluetooth unit is
    // STOPPED but kept resident (fast to restart next dictation); a Bluetooth unit is DISPOSED to free HFP.
    private func teardownAndFinalize() async -> URL? {
        let queue = currentQueue()
        let url = lock.withLock { currentURL }
        do {
            try await runWithDeadline(seconds: Self.bringUpTimeout) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    queue.async { [self] in
                        // Make "capture is over" visible ON the control queue BEFORE the unit teardown, so a
                        // mid-recording restart already queued behind us (its guard reads currentURL) sees the
                        // capture ended and bails instead of starting a fresh ownerless unit. finalizeCapture()
                        // on the caller afterward clears the remaining recording state idempotently.
                        lock.withLock { currentURL = nil }
                        removeActiveDeviceListener()
                        if effectiveInputIsBluetooth() {
                            disposeUnitInline()
                        } else {
                            lock.withLock { unit }?.stop()
                        }
                        cont.resume()
                    }
                }
            }
        } catch {
            markRebuild()
        }
        finalizeCapture()
        return url
    }

    // Immediate, audio-discarding teardown for cancel()/over-limit abort: the caller deletes the WAV, so
    // finalize ordering does not matter. Force-resumes any pending drain first so a direct stop never
    // strands the drain awaiter, and disposes the unit off-main so a bad device can't block.
    func stop() -> URL? {
        resumeDrain()
        let queue = currentQueue()
        let url = lock.withLock { currentURL }
        finalizeCapture()
        queue.async { [self] in
            removeActiveDeviceListener()
            disposeUnitInline()
        }
        return url
    }

    private func finalizeCapture() {
        lock.lock()
        file = nil
        currentURL = nil
        levelHandler = nil
        recordFormat = nil
        converter = nil
        converterInputFormat = nil
        outBuffer = nil
        lock.unlock()
    }

    // Drop a half-open capture (bring-up threw or timed out): clear recording state and delete the
    // partially-written file. Never touches the unit — a wedged one is abandoned via the rebuild flag.
    private func discardPendingCapture() {
        let url = lock.withLock { currentURL }
        finalizeCapture()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Buffer handling

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = self.file
        let handler = self.levelHandler
        guard let recordFormat = self.recordFormat else { lock.unlock(); return }

        let inputFormat = buffer.format
        if inputFormat.sampleRate == recordFormat.sampleRate
            && inputFormat.channelCount == recordFormat.channelCount {
            lock.unlock()
            try? file?.write(from: buffer)
            emitLevel(buffer, to: handler)
            return
        }

        // A mid-stream device transition can deliver a degenerate buffer; drop it. AVAudioConverter's init
        // can RAISE on a bad conversion (uncatchable on the callback thread) — the shim is the backstop.
        guard Self.isUsableInputFormat(
            sampleRate: inputFormat.sampleRate, channelCount: inputFormat.channelCount) else {
            lock.unlock(); return
        }
        if converter == nil
            || converterInputFormat?.sampleRate != inputFormat.sampleRate
            || converterInputFormat?.channelCount != inputFormat.channelCount {
            var built: AVAudioConverter?
            try? ObjCException.catching { built = AVAudioConverter(from: inputFormat, to: recordFormat) }
            converter = built
            converterInputFormat = inputFormat
            outBuffer = nil
        }
        let ratio = recordFormat.sampleRate / inputFormat.sampleRate
        let needed = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        if outBuffer == nil || outBuffer!.frameCapacity < needed {
            outBuffer = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: needed)
        }
        let converter = self.converter
        let outBuffer = self.outBuffer
        lock.unlock()

        guard let converter, let outBuffer else {
            return
        }
        outBuffer.frameLength = 0
        var convError: NSError?
        let feed = self.feed
        feed.buffer = buffer
        feed.consumed = false
        _ = converter.convert(to: outBuffer, error: &convError) { _, status in
            if feed.consumed { status.pointee = .noDataNow; return nil }
            feed.consumed = true
            status.pointee = .haveData
            return feed.buffer
        }
        guard convError == nil, outBuffer.frameLength > 0 else { return }
        try? file?.write(from: outBuffer)
        emitLevel(outBuffer, to: handler)
    }

    private func emitLevel(_ buffer: AVAudioPCMBuffer, to handler: (@Sendable (Float) -> Void)?) {
        guard let handler else { return }
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))
        handler(Self.perceptualLevel(rms))
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
    private func isGeneration(_ g: Int) -> Bool { lock.withLock { generation == g } }
    private func markRebuild() { lock.withLock { mustRebuild = true } }

    // MUST run on the control queue. Dispose the current unit (its realized I/O proc + device hold) and
    // clear the binding, so the next bring-up configures fresh.
    private func disposeUnitInline() {
        let outgoing = lock.withLock { () -> HALInputUnit? in
            let u = unit; unit = nil; configuredDeviceID = nil; configuredGeneration = nil; return u
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
        configuredGeneration = nil
        generation &+= 1
        controlQueue = DispatchQueue(label: "com.keyscribe.audio.\(generation)")
        lock.unlock()
        if let outgoing {
            let box = UnitBox(outgoing)
            outgoingQueue.async { box.unit.dispose() }
        }
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

    // The client stream format we set on the AUHAL after binding the device: Float32, non-interleaved, at
    // the device's OWN native rate and channel count. Matching the client format to the device (never
    // forcing a rate/channel count the hardware lacks) is exactly how the -10868 that plagued the
    // AVAudioEngine path is avoided. nil for a degenerate native format (0 Hz / 0 ch).
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
        let recording = lock.withLock { currentURL != nil }
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
        let recording = lock.withLock { currentURL != nil }
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
        lock.withLock { activeDeviceListenerBlock = block; activeListenedDeviceID = deviceID }
    }

    private func removeActiveDeviceListener() {
        let (block, deviceID, pending) = lock.withLock {
            () -> (AudioObjectPropertyListenerBlock?, AudioDeviceID?, DispatchWorkItem?) in
            let b = activeDeviceListenerBlock; let d = activeListenedDeviceID; let p = activeDeviceDebounce
            activeDeviceListenerBlock = nil; activeListenedDeviceID = nil; activeDeviceDebounce = nil
            return (b, d, p)
        }
        // Cancel a debounced restart already scheduled at +150 ms — otherwise it survives teardown and can
        // start a fresh, ownerless capture unit after the mic was supposed to be released (a stranded hot mic).
        pending?.cancel()
        guard let block, let deviceID else { return }
        for selector in Self.activeDeviceSelectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, deviceListenerQueue, block)
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

    private func requestMidRecordingRestart() {
        let queue = currentQueue()
        queue.async { [self] in
            guard lock.withLock({ currentURL != nil }) else { return }
            let (attempts, generation) = lock.withLock { () -> (Int, Int) in
                configRestartCount += 1; return (configRestartCount, self.generation)
            }
            guard attempts <= Self.maxConfigRestarts else {
                Log.audio.error("mid-recording restart gave up after \(Self.maxConfigRestarts, privacy: .public) attempts — capture may be truncated")
                return
            }
            guard let deviceID = effectiveDeviceID() else { return }
            Log.audio.debug("mid-recording device change → restart attempt \(attempts, privacy: .public)")
            disposeUnitInline()
            do {
                let fresh = makeUnit()
                try fresh.configure(deviceID: deviceID)
                guard Self.shouldStartReplacementUnit(
                    generation: generation,
                    currentGeneration: lock.withLock { self.generation },
                    captureActive: lock.withLock { currentURL != nil }) else {
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
                    guard self.generation == generation, currentURL != nil else { return false }
                    unit = fresh; configuredDeviceID = deviceID; configuredGeneration = generation
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
                queue.asyncAfter(deadline: .now() + 0.25) { [self] in requestMidRecordingRestart() }
            }
        }
    }

    static func shouldStartReplacementUnit(generation: Int, currentGeneration: Int, captureActive: Bool) -> Bool {
        generation == currentGeneration && captureActive
    }
}
