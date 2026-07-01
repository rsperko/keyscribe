import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import KeyScribeKit
import os

protocol AudioCapturing: AnyObject, Sendable {
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL
    func stop() -> URL?
    // Commit-on-release stop: let the tap deliver the buffer that holds the final word before tearing
    // the engine down, so the tail is not clipped. Falls back to an immediate stop for test fakes.
    func finishDraining() async -> URL?
    func prewarm()
    // Rebuild + re-prewarm the idle engine's device binding without any topology change having fired.
    // A resident engine's cached CoreAudio binding can rot in place while the app sits idle (or the
    // system sleeps), so the caller drives this on wake / after long idle to refresh the hot path.
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
    // Engine bring-up did not return within the watchdog window — the device (classically a Bluetooth
    // headset mid A2DP↔HFP switch, or a half-transitioned/dead input) wedged a synchronous CoreAudio
    // call. The main thread was never blocked; the dictation fails gracefully and the next attempt
    // rebuilds on a fresh engine + queue.
    case bringUpTimedOut
}

// Boxes the (non-Sendable) live buffer + a one-shot flag for AVAudioConverter's @Sendable input block.
// Reused across buffers (the tap delivers serially, like the shared outBuffer it sits beside) so the
// resampling path does not heap-allocate on every delivered buffer.
private final class FeedOnce: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    var consumed = false
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
    private let feed = FeedOnce()
    // Set while a commit-on-release drain is in flight: each delivered buffer feeds the gate, and the
    // continuation is resumed once a buffer covers the release instant (or a backstop timeout fires).
    private var drainGate: TailDrainGate?
    private var drainContinuation: CheckedContinuation<Void, Never>?

    // Bound for a single engine bring-up. A healthy prewarmed engine starts in a few ms; a legitimately
    // slow Bluetooth profile switch can take several hundred ms; an indefinite wedge is the failure we
    // abandon. Set generously so a slow-but-real device is not falsely failed.
    private static let bringUpTimeout: Double = 2.0

    // Extra window the INTERACTIVE start() path waits past `bringUpTimeout` before hard-failing, so a
    // bring-up that lands just late is ADOPTED rather than discarded. Motivating incident: a resident
    // engine whose cached CoreAudio binding had gone stale during idle needed ~1.9 s to re-realize the
    // input unit on the hot path — a hair past a tight 2 s watchdog, whose late success was thrown on the
    // floor and surfaced as "Could not start the microphone". Waiting longer here CANNOT reintroduce the
    // original main-thread freeze: bring-up runs on the off-main control queue, so the main actor only
    // `await`s (never blocks); the deadline exists solely to surface a TRULY wedged device as a clean
    // failure instead of hanging forever. prewarm keeps the tight `bringUpTimeout` — it is background work.
    private static let bringUpGrace: Double = 2.0

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
    // Coalesces a storm of topology callbacks (one physical plug/unplug fires the listener several times)
    // into a single rebuild, and skips the rebuild entirely when the effective device did not actually
    // change. Both fields are touched ONLY on `deviceListenerQueue`, so they need no lock.
    private var topologyDebounce: DispatchWorkItem?
    private var lastEffectiveDeviceID: AudioDeviceID?

    // Layer 6: while RECORDING, a device change (swap, sample-rate change, or a Bluetooth A2DP↔HFP profile
    // flip) is observed by the running engine's I/O unit, which stops + uninitializes the engine and posts
    // AVAudioEngineConfigurationChange — the HAL listeners above deliberately no-op while recording because
    // this notification is the in-flight path. We observe it per-engine and restart capture on the control
    // queue, keeping the same capture file so the dictation continues instead of silently truncating.
    private var configChangeObserver: NSObjectProtocol?
    // Bounds a flapping device: each restart attempt increments this; past the cap we stop retrying and let
    // the release→finishDraining path finalize the partial capture. Reset when a new capture is armed.
    private var configRestartCount = 0
    private static let maxConfigRestarts = 5

    // Holds the user's ORIGINAL system default input while we have temporarily overridden it to honor a
    // preferred device the AUHAL refuses to pin (the -10868 case — classically while a Bluetooth headset
    // holds the default). Every teardown path restores it; leaving it changed would hijack every other
    // app's microphone (the bug we saw other apps ship). nil when we have not swapped.
    private var swappedDefaultInput: AudioDeviceID?

    // Records the temporary default-input override to a durable marker before we apply it and clears it
    // after we restore, so a crash while swapped does not strand the user's system default mic pointed at
    // our temporary choice (reconciled on next launch / on graceful terminate). nil in tests/fakes.
    private let restorer: SystemAudioStateRestorer?

    init(restorer: SystemAudioStateRestorer? = nil) {
        self.restorer = restorer
        registerInputListeners()
        observeConfigChanges(of: engineSnapshot(), generation: currentGeneration())
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
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        // Last-ditch: if we are torn down mid-swap (app quit during a dictation), put the user's default
        // input back so we never leave the system pointed at our temporary choice.
        restoreDefaultInputIfSwapped()
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
        let started = DispatchTime.now()
        do {
            // Non-destructive watchdog: adopt a bring-up that lands within the grace window; only the
            // DeadlineExceeded branch below (a genuinely wedged device) tears the half-open capture down.
            let url = try await runWithDeadline(seconds: Self.bringUpTimeout + Self.bringUpGrace) { [self] in
                try await bringUp(sampleRate: sampleRate, levelHandler: levelHandler)
            }
            // Confirms/refutes the stale-binding hypothesis on the next incident: a healthy prewarmed start
            // is a few ms; anything past bringUpTimeout means the input unit was re-realized on the hot path
            // and only the grace window saved the dictation (a spurious failure before Fix 2's grace window).
            let ms = Self.elapsedMs(since: started)
            let band = ms > Self.bringUpTimeout * 1000 ? " grace-adopted" : ""
            Log.audio.debug("bringUp=\(ms, privacy: .public)ms\(band, privacy: .public)")
            return url
        } catch is DeadlineExceeded {
            // The bring-up wedged. The main thread was never blocked — the stuck CoreAudio call is
            // abandoned on the (now unusable) control queue. Flag a rebuild so the next dictation gets a
            // fresh engine on a fresh queue, drop the half-open capture file, and surface a clean failure.
            Log.audio.error("bringUp timed out after \(Self.elapsedMs(since: started), privacy: .public)ms")
            markRebuild()
            discardPendingCapture()
            throw AudioCaptureError.bringUpTimedOut
        }
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
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
        self.configRestartCount = 0
        lock.unlock()

        do {
            try armBestEffort()
        } catch {
            restoreDefaultInputIfSwapped()
            markRebuild()
            discardPendingCapture()
            throw error
        }
        return url
    }

    // Bring the engine up with the best strategy available for the user's chosen mic, escalating on
    // failure. This is the whole point of the device handling: get the right microphone live, and if we
    // cannot, get *a* microphone live rather than failing.
    //   1. PIN the preferred device on the input AUHAL — zero global side effects. Skipped when a Bluetooth
    //      device holds the system default, because pinning a non-default input then reliably fails -10868.
    //      When no preferred device is set (or it already is the default), this simply follows the default.
    //   2. TEMPORARILY make the preferred device the system default so the engine can follow it — the route
    //      a non-default input can't be pinned into. Restored on every teardown path. This is what lets you
    //      dictate on the built-in mic while AirPods (busy on a call) hold the default.
    //   3. FOLLOW the system default as-is only when no preferred device is configured, or the configured
    //      device is disconnected. If a connected preferred device fails, surface that failure instead of
    //      silently recording from a different microphone.
    private func armBestEffort() throws {
        let preferredUID = lock.withLock { preferredInputUID }
        let preferredDevice = preferredUID.flatMap(AudioInputDevices.deviceID(forUID:))
        let systemDefault = AudioInputDevices.systemDefaultInputID()
        let override = preferredDeviceNeedingOverride(preferred: preferredDevice, systemDefault: systemDefault)
        let fallbackAllowed = Self.allowsSystemDefaultFallback(
            preferredUID: preferredUID, preferredDevice: preferredDevice, systemDefault: systemDefault)
        let defaultIsBluetooth = systemDefault.map(AudioInputDevices.isBluetooth) ?? false

        if override == nil || !defaultIsBluetooth {
            do { try arm(); return } catch { }
        }
        if let override {
            do { try armWithTemporaryDefault(override); return }
            // The swap succeeded but arming the new default failed, leaving a realized (failed) engine whose
            // I/O-unit property listener is still registered. DISPOSE it before restoring the default below:
            // restoring fires that listener, and the fallback rebuild would otherwise deallocate the engine
            // concurrently — the same AVAudioIOUnit use-after-free as the happy path. Dispose-then-restore.
            catch {
                disposeCurrentEngine()
                restoreDefaultInputIfSwapped()
            }
        }
        guard fallbackAllowed else { throw AudioCaptureError.preferredInputFailed }
        try fallBackToDefaultWithRetry()
    }

    // The preferred device to honor, only when it is set, currently connected, AND not already the system
    // default — i.e. the case that needs the AUHAL pin or the temporary-default swap. nil otherwise.
    private func preferredDeviceNeedingOverride(
        preferred: AudioDeviceID?, systemDefault: AudioDeviceID?
    ) -> AudioDeviceID? {
        guard let preferred, let current = systemDefault, preferred != current else { return nil }
        return preferred
    }

    static func allowsSystemDefaultFallback(
        preferredUID: String?, preferredDevice: AudioDeviceID?, systemDefault: AudioDeviceID?
    ) -> Bool {
        guard let preferredUID, !preferredUID.isEmpty else { return true }
        guard let preferredDevice else { return true }
        return preferredDevice == systemDefault
    }

    // Honor a preferred device the AUHAL can't pin by TEMPORARILY making it the system default and letting
    // the engine follow the default (which always starts), then restoring the user's original default on
    // teardown. Strict save → set → settle → capture; the original is stashed for restoreDefaultInputIfSwapped().
    private func armWithTemporaryDefault(_ preferred: AudioDeviceID) throws {
        guard let original = AudioInputDevices.systemDefaultInputID() else {
            throw AudioCaptureError.formatUnavailable
        }
        // Dispose the current (idle, old-default-bound) engine BEFORE changing the system default. Changing
        // the default fires CoreAudio's property listener on the engine's I/O unit (on AVFoundation's own
        // AVAudioIOUnit queue); deallocating that unit at the same instant is the AVAudioIOUnit property-
        // listener use-after-free that crashed 0.1.7. Disposing first removes the listener, so the swap
        // below enqueues nothing for the dead unit. The fresh placeholder it leaves has no realized unit.
        disposeCurrentEngine()
        // Write the crash-recovery marker BEFORE the global change, so a crash anytime after this point can
        // be undone on next launch. (Resolving the UID effectively always succeeds; if it doesn't we skip
        // the marker and rely on the in-process restore.)
        let originalUID = AudioInputDevices.uid(of: original)
        if let originalUID { restorer?.recordDefaultInputOverride(originalUID: originalUID) }
        guard AudioInputDevices.setSystemDefaultInput(preferred) else {
            restorer?.clearDefaultInputOverride()
            throw AudioCaptureError.formatUnavailable
        }
        lock.withLock { swappedDefaultInput = original }
        settleDefaultInput(expected: preferred, timeout: 0.4)
        // The placeholder from disposeCurrentEngine() realizes against the now-current default; arm it.
        try arm(followSystemDefault: true)
    }

    // Block (on the control queue) until the system default input reports the expected device, so a freshly
    // built engine binds to the new default rather than the one we just replaced. Bounded — proceed anyway
    // on timeout (a stale bind degrades to the original default, which still starts).
    private func settleDefaultInput(expected: AudioDeviceID, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while AudioInputDevices.systemDefaultInputID() != expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // Restore the user's system default input if we temporarily overrode it. Idempotent: clears the stash,
    // so every teardown path can call it unconditionally.
    private func restoreDefaultInputIfSwapped() {
        let original = lock.withLock { () -> AudioDeviceID? in
            let o = swappedDefaultInput; swappedDefaultInput = nil; return o
        }
        guard let original else { return }
        AudioInputDevices.setSystemDefaultInput(original)
        // Marker cleared only AFTER the in-process restore; a crash in between just re-applies the same
        // (already-correct) default on next launch — idempotent.
        restorer?.clearDefaultInputOverride()
    }

    private func fallBackToDefaultWithRetry() throws {
        do {
            try rebuildAndArmFollowingDefault()
        } catch {
            // A just-connected Bluetooth/USB input can fail the FIRST bring-up while its HAL proxy is still
            // initializing (cf. wispr's 250 ms Bluetooth retry, Chromium's tolerance of transient startup
            // errors). Wait briefly and retry once more. A wedge is handled upstream by the bring-up watchdog.
            Thread.sleep(forTimeInterval: 0.25)
            try rebuildAndArmFollowingDefault()
        }
    }

    // Fresh engine bound to the system default (no preferred-device pin), with the config-change observer
    // re-pointed at it. Used by the fallbacks and the mid-recording restart. Bumps the generation so a late
    // buffer from the engine we just dropped is rejected by the tap guard; keeps the current control queue
    // (we are already executing on it).
    private func rebuildAndArmFollowingDefault() throws {
        // Stop the outgoing engine before it is dropped + deallocated below, so its stop()/removeTap is
        // ordered ahead of the dealloc on this (control) queue rather than racing it. (Callers here do not
        // mutate the system default, so there is no concurrent default-changed callback to fence against —
        // armWithTemporaryDefault handles that case via disposeCurrentEngine.)
        Self.teardownEngine(engineSnapshot())
        lock.lock()
        engineGeneration &+= 1
        engine = AVAudioEngine()
        let newEngine = engine
        let generation = engineGeneration
        lock.unlock()
        observeConfigChanges(of: newEngine, generation: generation)
        try arm(followSystemDefault: true)
    }

    // AUHAL reports 0 ch / 0 Hz for an output-only device; tapping that format aborts the process (arm()).
    static func isUsableInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    private func arm(followSystemDefault: Bool = false) throws {
        let engine = engineSnapshot()
        let generation = currentGeneration()
        // Pin the preferred device (if present) before the tap is installed, so the tap binds to its live
        // format. No-op when no preferred device is set or it is absent — the engine then follows the
        // system default, which is exactly the fallback policy. `followSystemDefault` forces that no-op
        // path even when a preferred device is set: pinning a non-default input AUHAL CurrentDevice raises
        // -10868 (FormatNotSupported in AUGraph input-chain init) whenever a Bluetooth headset holds the
        // system default, so armSync's retry drops the pin and follows the (startable) default instead.
        if !followSystemDefault {
            applyPreferredDevice(to: engine)
        }
        let input = engine.inputNode
        // Defensively drop any tap already on this bus so arm() is restart-safe: the mid-recording
        // config-change path re-arms the SAME engine, and installTap on a bus that already has one raises.
        // removeTap on a tap-less bus is a no-op, so this is harmless on the normal first arm.
        try? ObjCException.catching { input.removeTap(onBus: 0) }
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
        await disposeIfNeededThenRestoreDefault()
        return url
    }

    // After capture stops: if we temporarily overrode the system default and/or the engine is holding a
    // Bluetooth device, DISPOSE the engine and THEN restore the default — strictly in that order. Restoring
    // the default fires the I/O unit's property listener; doing it while that unit is deallocating is the
    // teardown-side form of the 0.1.7 AVAudioIOUnit use-after-free, so the unit must be gone first.
    // Disposing also frees a Bluetooth headset from HFP (the unit stays realized through engine.stop(), so
    // a plain stop would keep music muted while idle). Built-in/wired inputs with no override skip this and
    // keep the prewarmed engine resident — no per-dictation rebuild.
    private func disposeIfNeededThenRestoreDefault() async {
        let mustDispose = lock.withLock { swappedDefaultInput != nil } || effectiveInputIsBluetooth()
        guard mustDispose else { return }
        let queue = currentQueue()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                disposeCurrentEngine()
                restoreDefaultInputIfSwapped()
                cont.resume()
            }
        }
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
        // Same ordering rule as the commit path: when we must restore an overridden default and/or drop a
        // Bluetooth engine, DISPOSE the engine before restoring the default so the restore's property
        // callback can't hit a deallocating I/O unit. Otherwise just stop and keep the engine resident.
        let mustDispose = lock.withLock { swappedDefaultInput != nil } || effectiveInputIsBluetooth()
        queue.async { [self] in
            if mustDispose {
                disposeCurrentEngine()
                restoreDefaultInputIfSwapped()
            } else {
                Self.teardownEngine(box.engine)
            }
        }
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
    // Deliberately does NOT restore the system default: this runs OFF the control queue on the bring-up
    // TIMEOUT path, where the abandoned armSync may still be running on the control queue (a timeout is
    // "too slow", not necessarily "wedged forever"). An off-queue setSystemDefaultInput would both race
    // that in-flight armSync mutating the same global default AND enqueue an AVAudioIOUnit property callback
    // that the abandoned armSync's fallback could then deallocate into — the exact UAF shape we are
    // eliminating. So restore happens on the control queue only: the on-queue caller (armSync's catch)
    // restores before calling this, and a timeout leaves the swap in place to be undone safely on the next
    // on-queue teardown (disposeIfNeededThenRestoreDefault still sees swappedDefaultInput set), or by the
    // durable marker at next launch if no further dictation runs.
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
        // Reuse the shared one-shot feed box (reset per call); convert() consumes it synchronously
        // before returning, and tap delivery is serial, so the same box is safe across buffers.
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

    // MUST run on the control queue. Stop + DISPOSE the current engine — its realized I/O unit and the
    // CoreAudio property listeners AVFoundation rides on it — and swap in a fresh, UNREALIZED placeholder.
    // Callers that mutate the system default input MUST call this BEFORE the mutation: the old engine is
    // deallocated by the time this returns (its `let` reference cannot outlive this scope), so its property
    // listener is gone before any default-changed callback could be enqueued for it. This is the fix for the
    // AVAudioIOUnit::IOUnitPropertyListener use-after-free (0.1.7). The placeholder is bare (AVAudioEngine
    // realizes its input unit lazily, on first inputNode/prepare), so it carries no listener until armed.
    private func disposeCurrentEngine() {
        Self.teardownEngine(engineSnapshot())
        lock.lock()
        engineGeneration &+= 1
        engine = AVAudioEngine()
        let placeholder = engine
        let generation = engineGeneration
        lock.unlock()
        observeConfigChanges(of: placeholder, generation: generation)
    }

    private func rebuildEngineIfNeeded() {
        lock.lock()
        guard mustRebuild else { lock.unlock(); return }
        mustRebuild = false
        let outgoing = engine
        let outgoingQueue = controlQueue
        engineGeneration &+= 1
        engine = AVAudioEngine()
        controlQueue = DispatchQueue(label: "com.keyscribe.audio.\(engineGeneration)")
        let newEngine = engine
        let generation = engineGeneration
        lock.unlock()
        // Tear down + release the outgoing engine on its OWN (outgoing) queue, async and fire-and-forget,
        // rather than letting it deallocate inline on whatever thread called us (start / prewarm /
        // applyTopologyChange — often the device-listener queue). Two wins: (1) a HEALTHY outgoing engine
        // (a device/preference change, not a wedge) gets an orderly stop()/removeTap + dealloc serialized
        // off the caller's thread, instead of a raw cross-thread drop that could race a device-change
        // property callback during dealloc (the IOUnitPropertyListener UAF class); (2) a WEDGED outgoing
        // engine (the reason we are escaping to a fresh queue) can no longer block the caller — its teardown
        // simply never runs on the abandoned queue and the dead engine is left behind, exactly the intended
        // abandonment, but now the caller does not pay the dealloc on its own thread.
        let box = EngineBox(outgoing)
        outgoingQueue.async { Self.teardownEngine(box.engine) }
        // Re-point the config-change observer at the fresh engine (NotificationCenter add/remove is
        // internally synchronized, so this is safe outside the lock).
        observeConfigChanges(of: newEngine, generation: generation)
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
        // One physical plug/unplug fires this listener several times; coalesce a burst into a single
        // rebuild by debouncing on the (serial) listener queue. The trailing edge runs applyTopologyChange.
        topologyDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyTopologyChange() }
        topologyDebounce = work
        deviceListenerQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func applyTopologyChange() {
        // Only act while idle: a change mid-recording is the running engine's own ConfigurationChange to
        // handle. While idle (stopped) that notification never fires, so proactively flag a rebuild and
        // re-prewarm against the new effective device (preferred-if-present, else default) — the hot path
        // then finds a fresh, valid engine.
        let recording = lock.withLock { currentURL != nil }
        guard !recording else { return }
        // Skip the rebuild when the effective device is unchanged: the device list churns for reasons that
        // don't affect us (an output-only device appearing, a property tweak), and a needless engine
        // rebuild + prewarm would re-realize the input unit for nothing. lastEffectiveDeviceID is touched
        // only here (on deviceListenerQueue), so it needs no lock.
        let current = effectiveDeviceID()
        guard current != lastEffectiveDeviceID else { return }
        lastEffectiveDeviceID = current
        markRebuild()
        prewarm()
    }

    // Idle-staleness refresh (mirrors applyTopologyChange's tail, minus the device-changed short-circuit).
    // No topology change fires here: the resident engine's cached binding just rots in place over a long
    // idle or a system sleep (a dead HAL proxy), so the FIRST dictation afterward would otherwise pay a
    // stale unit-realization on the hot path — or, at the watchdog edge, fail. Rebuild + re-prewarm while
    // idle so the hot path finds a fresh binding. No-op while recording: a live engine owns its own
    // ConfigurationChange, and stomping its binding mid-capture would truncate the dictation.
    func refreshBinding() {
        let recording = lock.withLock { currentURL != nil }
        guard !recording else { return }
        markRebuild()
        prewarm()
    }

    // MARK: - Mid-recording config-change recovery (Layer 6)

    private func observeConfigChanges(of engine: AVAudioEngine, generation: Int) {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.handleConfigurationChange(generation: generation)
        }
        let previous = lock.withLock { () -> NSObjectProtocol? in
            let old = configChangeObserver
            configChangeObserver = token
            return old
        }
        if let previous { NotificationCenter.default.removeObserver(previous) }
    }

    private func handleConfigurationChange(generation: Int) {
        // The running engine observed a hardware change (device swap, sample-rate change, or a Bluetooth
        // A2DP↔HFP flip) and has already STOPPED + uninitialized itself. Restart on the control queue,
        // keeping the same capture file so the dictation continues. The generation guard drops a stale
        // notification from an engine we have since rebuilt out.
        let queue = currentQueue()
        queue.async { [self] in
            guard isGeneration(generation) else { return }
            let recording = lock.withLock { currentURL != nil }
            guard recording else { return }
            restartCaptureAfterConfigChange()
        }
    }

    // Runs on the control queue. Re-arms capture into the still-open file. Coalesces a notification storm
    // (an already-running engine needs nothing) and bounds a flapping device via configRestartCount; once
    // the cap is hit we stop retrying and let the release→finishDraining path finalize the partial capture.
    private func restartCaptureAfterConfigChange() {
        if engineSnapshot().isRunning { return }
        let attempts = lock.withLock { () -> Int in configRestartCount += 1; return configRestartCount }
        guard attempts <= Self.maxConfigRestarts else { return }
        do {
            // Re-arm the same engine the notification stopped, honoring the preferred device if it pins
            // cleanly; arm() defensively removes the prior tap first so the reinstall doesn't raise.
            try arm()
        } catch {
            // Preferred pin failed (e.g. it became non-default) — fall back to a fresh default-following
            // engine, same file. If that also throws, give up; the partial capture is finalized on release.
            try? rebuildAndArmFollowingDefault()
        }
    }
}
