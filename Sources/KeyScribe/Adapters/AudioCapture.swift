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
}

extension AudioCapturing {
    func prewarm() {}
    func finishDraining() async -> URL? { stop() }
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

    // Layer 5: a listener on the default *input* device. While idle the prewarmed engine caches a device
    // binding that no AVAudioEngineConfigurationChange refreshes (none fires while stopped), so a device
    // switch would otherwise leave the hot path bound to a gone/stale device. On a change we flag a
    // rebuild and re-prewarm off-main, keeping the prewarmed engine valid without per-dictation cost.
    private let deviceListenerQueue = DispatchQueue(label: "com.keyscribe.audio.device-listener")
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        registerDefaultInputListener()
    }

    deinit {
        guard let deviceListenerBlock else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, deviceListenerQueue, deviceListenerBlock)
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
        let queue = currentQueue()
        let generation = currentGeneration()
        Task.detached { [self] in
            do {
                try await runWithDeadline(seconds: Self.bringUpTimeout) {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        queue.async { [self] in
                            if isGeneration(generation) {
                                let input = engineSnapshot().inputNode
                                _ = input.outputFormat(forBus: 0)
                                engineSnapshot().prepare()
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

    private func arm() throws {
        let engine = engineSnapshot()
        let generation = currentGeneration()
        let input = engine.inputNode
        // format: nil binds the tap to the input node's live hardware format, so there is no passed
        // format for AVFoundation to validate and mismatch against (a 48k-cached / 16k-actual mismatch
        // previously aborted with an uncaught com.apple.coreaudio.avfaudio exception → SIGABRT).
        // bufferSize 1024 keeps the tap's accumulation window small (~64 ms @16k) so the worst-case
        // undelivered tail at release is short; finishDraining() then flushes it before stopping.
        // The generation guard drops a buffer from an engine that has since been rebuilt out (a wedged
        // engine that finally unblocks must not write into a newer recording).
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, when in
            guard let self, self.isGeneration(generation) else { return }
            self.handle(buffer)
            self.feedDrainGate(when)
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
        return await teardownAndFinalize()
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
                        box.engine.stop()
                        box.engine.inputNode.removeTap(onBus: 0)
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
            box.engine.stop()
            box.engine.inputNode.removeTap(onBus: 0)
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

        if converter == nil
            || converterInputFormat?.sampleRate != inputFormat.sampleRate
            || converterInputFormat?.channelCount != inputFormat.channelCount {
            converter = AVAudioConverter(from: inputFormat, to: recordFormat)
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

    // MARK: - Default input device listener (Layer 5)

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func registerDefaultInputListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleDefaultInputChanged() }
        deviceListenerBlock = block
        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, deviceListenerQueue, block)
    }

    private func handleDefaultInputChanged() {
        // Only act while idle: a change mid-recording is the running engine's own ConfigurationChange to
        // handle. While idle (stopped) that notification never fires, so proactively flag a rebuild and
        // re-prewarm against the new default input — the hot path then finds a fresh, valid engine.
        let recording = lock.withLock { currentURL != nil }
        guard !recording else { return }
        markRebuild()
        prewarm()
    }
}
