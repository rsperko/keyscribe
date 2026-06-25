import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import KeyScribeKit

protocol AudioCapturing: AnyObject, Sendable {
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL
    func stop() -> URL?
    // Commit-on-release stop: let the tap deliver the buffer that holds the final word before tearing
    // the engine down, so the tail is not clipped. Falls back to an immediate stop for test fakes.
    func finishDraining() async -> URL?
    func prewarm()
    // The user's preferred capture device UID (empty/nil = follow the system default). The adapter holds
    // it standing — the idle device listener consults it independently of any start()/prewarm() call.
    func setPreferredInputUID(_ uid: String?)
}

extension AudioCapturing {
    func prewarm() {}
    func finishDraining() async -> URL? { stop() }
    func setPreferredInputUID(_ uid: String?) {}
}

enum AudioCaptureError: Error {
    case formatUnavailable
    // Engine bring-up did not return within the watchdog window — the device (classically a Bluetooth
    // headset mid A2DP↔HFP switch, or a half-transitioned/dead input) wedged a synchronous CoreAudio
    // call. The main thread was never blocked; the dictation fails gracefully and the next attempt
    // rebuilds on a fresh engine + queue.
    case bringUpTimedOut
}

private final class FeedOnce: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

// Carries a specific engine instance into the control queue's @Sendable teardown closure. The instance
// matters: a rebuild may swap self.engine before the queued teardown runs, and we must stop the one we
// intended to (not whatever is current). AVAudioEngine is confined to the control queue, so this is safe.
private final class EngineBox: @unchecked Sendable {
    let engine: AVAudioEngine
    init(_ engine: AVAudioEngine) { self.engine = engine }
}

final class AudioCapture: AudioCapturing, @unchecked Sendable {
    // Every AVAudioEngine control call (arm/start/prewarm/teardown) runs on this serial queue, NEVER on
    // the main thread: a transitioning audio device can make `engine.start()`/`stop()` block for a long
    // time (or indefinitely), and doing that on `@MainActor` froze the whole app + event tap. Off-main,
    // the worst case is one wedged background thread, bounded by the bring-up watchdog. The queue is
    // swapped (with a fresh engine) when a wedge is detected, so the next dictation never queues behind
    // the stuck call.
    private var engine = AVAudioEngine()
    private var controlQueue = DispatchQueue(label: "com.keyscribe.audio.0")
    private var engineGeneration = 0
    // Set when a bring-up wedged (watchdog) or a device change invalidated the binding. Consumed by
    // rebuildEngineIfNeeded() before the next bring-up: a fresh engine re-resolves the current default
    // input; a fresh queue escapes a possibly-wedged old one.
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
    // Resamples the mic's native format down to the engine's target rate/mono so the WAV is written at
    // the rate STT wants — no oversized capture file, no decode-time resample. Built lazily from the
    // format the tap actually delivers (not a pre-queried one, which can be stale) and rebuilt if the
    // hardware format changes mid-stream. Reused across callbacks (the tap fires serially).
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var outBuffer: AVAudioPCMBuffer?
    // Set while a commit-on-release drain is in flight: each delivered buffer feeds the gate, and the
    // continuation is resumed once a buffer covers the release instant (or a backstop timeout fires).
    private var drainGate: TailDrainGate?
    private var drainContinuation: CheckedContinuation<Void, Never>?

    // Bound for a single engine bring-up. A healthy prewarmed engine starts in a few ms; a legitimately
    // slow Bluetooth profile switch can take several hundred ms; an indefinite wedge is the failure we
    // abandon. Set generously so a slow-but-real device is not falsely failed.
    private static let bringUpTimeout: Double = 2.0

    // Layer 5: two listeners on the system's input topology. While idle the prewarmed engine caches a
    // device binding that no AVAudioEngineConfigurationChange refreshes (none fires while stopped), so a
    // device switch would otherwise leave the hot path bound to a gone/stale device. We watch BOTH the
    // default-input selector (covers "follow the system default" when no preferred device is set or it is
    // absent) AND the device list (covers a preferred device appearing/disappearing). Either change, while
    // idle, flags a rebuild and re-prewarms off-main so the next bring-up resolves the current effective
    // device — preferred if present, else default — without per-dictation cost.
    private let deviceListenerQueue = DispatchQueue(label: "com.keyscribe.audio.device-listener")
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

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
        // rebuild so the prewarmed engine rebinds, and re-prewarm while idle.
        let recording = lock.withLock { currentURL != nil }
        markRebuild()
        if !recording { prewarm() }
    }

    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL {
        rebuildEngineIfNeeded()
        do {
            return try await runWithDeadline(seconds: Self.bringUpTimeout) { [self] in
                try await bringUp(sampleRate: sampleRate, levelHandler: levelHandler)
            }
        } catch is DeadlineExceeded {
            // The bring-up wedged. The main thread was never blocked — the stuck CoreAudio call is
            // abandoned on the (now unusable) control queue. Flag a rebuild so the next dictation gets a
            // fresh engine on a fresh queue, drop the half-open capture file, and surface a clean failure.
            markRebuild()
            discardPendingCapture()
            throw AudioCaptureError.bringUpTimedOut
        }
    }

    private func bringUp(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL {
        let queue = currentQueue()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                do { cont.resume(returning: try armSync(sampleRate: sampleRate, levelHandler: levelHandler)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    // Realize the input HAL unit before the first dictation so capture starts without the one-time
    // ~165 ms unit-realization cost on the hot path. Accessing the input node and its format
    // instantiates the unit and prepare() preallocates its render resources; neither opens a capture
    // stream, so the mic indicator never lights. The caller gates this on a granted mic. Runs off-main
    // and watchdogged: a wedged prewarm flags a rebuild rather than stranding the next dictation behind
    // a stuck queue.
    func prewarm() {
        rebuildEngineIfNeeded()
        // Realizing the input HAL unit binds and HOLDS the default input device for the app's lifetime. On
        // a Bluetooth headset that pins it to HFP (mono call mode) and mutes the user's music even while
        // idle — the reported bug. Skip the idle realization there and pay the one-time unit cost on the
        // next dictation instead. Wired/built-in inputs have no A2DP/HFP penalty, so they keep fast prewarm.
        guard !effectiveInputIsBluetooth() else { return }
        let queue = currentQueue()
        let generation = currentGeneration()
        Task.detached { [self] in
            do {
                try await runWithDeadline(seconds: Self.bringUpTimeout) {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        queue.async { [self] in
                            if isGeneration(generation) {
                                let engine = engineSnapshot()
                                applyPreferredDevice(to: engine)
                                // Don't realize the unit on a degenerate format; arm() guards and recovers.
                                let format = engine.inputNode.outputFormat(forBus: 0)
                                if Self.isUsableInputFormat(
                                    sampleRate: format.sampleRate, channelCount: format.channelCount) {
                                    engine.prepare()
                                }
                            }
                            cont.resume()
                        }
                    }
                }
            } catch {
                markRebuild()
            }
        }
    }

    // Sets up the capture file + recording state, then arms the engine — all on the control queue.
    private func armSync(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL {
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
        lock.unlock()

        do {
            try arm()
        } catch {
            // The engine caches its input-device binding and never re-resolves it, so if that device
            // disconnected while idle (no ConfigurationChange fires while stopped) start() throws. Rebuild
            // the engine once to bind the current default input and retry — the costly input-unit
            // realization is paid only on a device change, not on every dictation. A wedge (vs a throw) is
            // handled upstream by the bring-up watchdog instead.
            lock.lock(); engine = AVAudioEngine(); lock.unlock()
            do {
                try arm()
            } catch {
                markRebuild()
                discardPendingCapture()
                throw error
            }
        }
        return url
    }

    // AUHAL reports 0 ch / 0 Hz for an output-only device; tapping that format aborts the process (arm()).
    static func isUsableInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    private func arm() throws {
        let engine = engineSnapshot()
        let generation = currentGeneration()
        // Pin the preferred device (if present) before the tap is installed, so the tap binds to its live
        // format. No-op when no preferred device is set or it is absent — the engine then follows the
        // system default, which is exactly the fallback policy.
        applyPreferredDevice(to: engine)
        let input = engine.inputNode
        // installTap on a degenerate format (0 ch / 0 Hz, an output-only/mid-churn default) raises an ObjC
        // NSException Swift can't catch (→ SIGABRT). Throw instead so armSync rebuilds and retries.
        let inputFormat = input.outputFormat(forBus: 0)
        guard Self.isUsableInputFormat(
            sampleRate: inputFormat.sampleRate, channelCount: inputFormat.channelCount) else {
            throw AudioCaptureError.formatUnavailable
        }
        // format: nil binds the tap to the input node's live hardware format, so there is no passed
        // format for AVFoundation to validate and mismatch against (a 48k-cached / 16k-actual mismatch
        // previously aborted with an uncaught com.apple.coreaudio.avfaudio exception → SIGABRT).
        // bufferSize 1024 keeps the tap's accumulation window small (~64 ms @16k) so the worst-case
        // undelivered tail at release is short; finishDraining() then flushes it before stopping.
        // The generation guard drops a buffer from an engine that has since been rebuilt out (a wedged
        // engine that finally unblocks must not write into a newer recording). The shim catches an
        // installTap raise (valid-looking but bad format) as a Swift error instead of aborting.
        try ObjCException.catching {
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, when in
                guard let self, self.isGeneration(generation) else { return }
                self.handle(buffer)
                self.feedDrainGate(when)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.stop()
            input.removeTap(onBus: 0)
            throw error
        }
    }

    // Best-in-class commit-on-release stop (cf. Handy's drain-until-EndOfStream, VoiceInk's
    // drain-ring-before-close): keep the engine running until the tap delivers the buffer that holds
    // the release instant, then tear down. A 300 ms backstop bounds the wait if the clock never crosses.
    func finishDraining() async -> URL? {
        await drainTail()
        let url = await teardownAndFinalize()
        releaseEngineIfBluetooth()
        return url
    }

    // After a dictation the engine's input unit stays realized (engine.stop() does not deallocate it),
    // which keeps a Bluetooth headset pinned to HFP and the user's music muted while idle. Drop the engine
    // so the unit deallocates and the headset renegotiates A2DP; the next dictation rebuilds on demand. No
    // effect on wired/built-in inputs (they keep the prewarmed engine resident, no per-dictation rebuild).
    private func releaseEngineIfBluetooth() {
        guard effectiveInputIsBluetooth() else { return }
        markRebuild()
        rebuildEngineIfNeeded()
    }

    private func drainTail() async {
        let releaseHostTime = mach_absolute_time()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            drainGate = TailDrainGate(releaseHostTime: releaseHostTime)
            drainContinuation = cont
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.resumeDrain()
            }
        }
    }

    private func feedDrainGate(_ when: AVAudioTime) {
        lock.lock()
        guard var gate = drainGate else { lock.unlock(); return }
        let start: UInt64? = when.isHostTimeValid ? when.hostTime : nil
        let outcome = gate.observe(bufferStartHostTime: start)
        drainGate = gate
        lock.unlock()
        if outcome == .stop { resumeDrain() }
    }

    private func resumeDrain() {
        lock.lock()
        let cont = drainContinuation
        drainContinuation = nil
        drainGate = nil
        lock.unlock()
        cont?.resume()
    }

    // Commit path: tear the engine down on the control queue (engine.stop()/removeTap can block on a
    // transitioning device), watchdogged so a wedge can't hang the commit. Finalizing (closing) the WAV
    // happens only AFTER the tap is removed, so no in-flight buffer write races the close. Returns the
    // URL of the finalized capture for transcription.
    private func teardownAndFinalize() async -> URL? {
        let queue = currentQueue()
        let box = EngineBox(engineSnapshot())
        let url = lock.withLock { currentURL }
        do {
            try await runWithDeadline(seconds: Self.bringUpTimeout) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    queue.async {
                        Self.teardownEngine(box.engine)
                        cont.resume()
                    }
                }
            }
        } catch {
            // Teardown wedged on a bad device — rebuild before next use. The data captured so far is
            // already on disk; finalize best-effort below so transcription can still read it.
            markRebuild()
        }
        finalizeCapture()
        return url
    }

    // Immediate, audio-discarding teardown for cancel()/over-limit abort: the caller deletes the WAV, so
    // finalize ordering does not matter. Force-resumes any pending drain first so a direct stop never
    // strands the drain awaiter, and tears the engine down off-main so a bad device can't block.
    func stop() -> URL? {
        resumeDrain()
        let queue = currentQueue()
        let box = EngineBox(engineSnapshot())
        let url = lock.withLock { currentURL }
        finalizeCapture()
        queue.async {
            Self.teardownEngine(box.engine)
        }
        releaseEngineIfBluetooth()
        return url
    }

    // stop()/removeTap can RAISE under device churn, not just block; an abort on the control queue kills
    // the process, so catch it — the WAV is already on disk and this engine is being discarded.
    private static func teardownEngine(_ engine: AVAudioEngine) {
        try? ObjCException.catching {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
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
    // partially-written file. Never touches the engine — a wedged one is abandoned via the rebuild flag.
    private func discardPendingCapture() {
        let url = lock.withLock { currentURL }
        finalizeCapture()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

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
        // can RAISE on a bad conversion (uncatchable on the tap thread) — the shim is the backstop.
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
        // AVAudioConverter's input block is @Sendable; box the (non-Sendable) live buffer + one-shot
        // flag so it can be fed exactly once. convert() consumes it synchronously before returning.
        let feed = FeedOnce(buffer)
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

    // RMS is linear, so speech-range energy clusters near zero and a linear meter barely moves.
    // Map to dB and rescale a [floor, ceiling] window to 0...1 so normal speech spans most of the bar.
    private static func perceptualLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floor: Float = -52
        let ceiling: Float = -12
        return min(1, max(0, (db - floor) / (ceiling - floor)))
    }

    // MARK: - Engine lifecycle / rebuild

    private func engineSnapshot() -> AVAudioEngine { lock.withLock { engine } }
    private func currentQueue() -> DispatchQueue { lock.withLock { controlQueue } }
    private func currentGeneration() -> Int { lock.withLock { engineGeneration } }
    private func isGeneration(_ generation: Int) -> Bool { lock.withLock { engineGeneration == generation } }
    private func markRebuild() { lock.withLock { mustRebuild = true } }

    private func rebuildEngineIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard mustRebuild else { return }
        mustRebuild = false
        engineGeneration &+= 1
        engine = AVAudioEngine()
        controlQueue = DispatchQueue(label: "com.keyscribe.audio.\(engineGeneration)")
    }

    // MARK: - Preferred-device resolution

    // The device a bring-up should bind: the preferred device if currently connected, else the system
    // default. nil only if even the default can't be read (no input at all).
    private func effectiveDeviceID() -> AudioDeviceID? {
        let uid = lock.withLock { preferredInputUID }
        if let uid, let id = AudioInputDevices.deviceID(forUID: uid) { return id }
        return AudioInputDevices.systemDefaultInputID()
    }

    enum PinDecision: Equatable { case skip, pin(AudioDeviceID) }

    // Pinning the input AUHAL's CurrentDevice — even to the device in use, or re-pinning an initialized
    // unit across prewarm→arm — breaks engine.start() with -10868 (FormatNotSupported). So pin only when
    // the preferred device differs from both the system default and what is already pinned.
    static func pinDecision(
        preferred: AudioDeviceID?, systemDefault: AudioDeviceID?, currentlyPinned: AudioDeviceID?
    ) -> PinDecision {
        guard let preferred else { return .skip }
        if preferred == systemDefault { return .skip }
        if preferred == currentlyPinned { return .skip }
        return .pin(preferred)
    }

    // Pin the preferred device on the input AUHAL only when pinDecision says to; otherwise follow the
    // system default. Runs on the control queue (arm/prewarm).
    private func applyPreferredDevice(to engine: AVAudioEngine) {
        let uid = lock.withLock { preferredInputUID }
        guard let uid, let deviceID = AudioInputDevices.deviceID(forUID: uid),
              let audioUnit = engine.inputNode.audioUnit else { return }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let pinned: AudioDeviceID? = AudioUnitGetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &current, &size) == noErr ? current : nil
        guard case let .pin(deviceToSet) = Self.pinDecision(
            preferred: deviceID,
            systemDefault: AudioInputDevices.systemDefaultInputID(),
            currentlyPinned: pinned) else { return }
        var device = deviceToSet
        AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // True when the *effective* input (preferred-if-present, else default) is a Bluetooth headset. Holding
    // such a device open forces it from A2DP (stereo music) to HFP (mono call mode), muting the user's
    // audio — so we avoid holding it while idle and drop the engine after each dictation.
    private func effectiveInputIsBluetooth() -> Bool {
        guard let id = effectiveDeviceID() else { return false }
        return AudioInputDevices.isBluetooth(id)
    }

    // MARK: - Input topology listeners (Layer 5)

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
        // Only act while idle: a change mid-recording is the running engine's own ConfigurationChange to
        // handle. While idle (stopped) that notification never fires, so proactively flag a rebuild and
        // re-prewarm against the new effective device (preferred-if-present, else default) — the hot path
        // then finds a fresh, valid engine.
        let recording = lock.withLock { currentURL != nil }
        guard !recording else { return }
        markRebuild()
        prewarm()
    }
}
