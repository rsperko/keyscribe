import AVFoundation
import Foundation
import KeyScribeKit
import Synchronization

final class FeedOnce: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    var consumed = false
}

// Seam over the file write so WAV and in-memory samples stay in lockstep on a write failure, and a fake
// can force a failure in tests. AVAudioFile satisfies it directly.
protocol CaptureFileWriting: AnyObject {
    func write(from buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: CaptureFileWriting {}

// Single consumer of an `AudioSampleRing`; keeps resampling and file I/O off the realtime thread.
final class CaptureWriter: @unchecked Sendable {
    // Poll tick for draining the ring while keeping the realtime path syscall-free.
    private static let pollInterval: Double = 0.005

    private let ring: AudioSampleRing
    // Released when the writer thread exits; the session owns final file-close ordering.
    private var file: (any CaptureFileWriting)?
    private let recordFormat: AVAudioFormat
    // Returns true once the release-covering buffer has reached disk and capture may seal.
    private let observeHostTime: (UInt64?) -> Bool

    private let shutdown = DispatchSemaphore(value: 0)
    // Thread lifetime, joinable by MANY waiters: teardown AND the next capture's arm can call finish()
    // concurrently (across a control-queue swap), and every caller must block until the thread exits before
    // the shared ring is reset. A DispatchGroup releases all waiters on the single leave() and returns at
    // once for any wait() after exit (a one-shot semaphore would not).
    private let done = DispatchGroup()
    private let stopRequested = Atomic<Bool>(false)
    private let flushOnStop = Atomic<Bool>(false)
    // Serializes start()/finish() so `done.enter()` happens under the same lock that sets `didStart`: any
    // finish() observing `didStart == true` is guaranteed the group was entered, so its `done.wait()` cannot
    // slip past an empty group before the thread exists. `finishRequested` remembers a finish() that raced
    // ahead of start() so start() honors the stop instead of running the thread full-length.
    private let lifecycleLock = NSLock()
    private var didStart = false
    private var finishRequested = false
    // Retains the running thread for its lifetime; cleared implicitly when this writer is released.
    private var thread: Thread?

    // Writer-thread-only resampling state.
    private var inBuffer: AVAudioPCMBuffer?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var outBuffer: AVAudioPCMBuffer?
    private let feed = FeedOnce()
    // Set once the drain gate trips: the converter tail has been flushed and no further slots are written.
    private var sealed = false
    // Post-conversion mono PCM (record rate), accumulated alongside the file write so a sample-capable engine
    // gets the committed capture without re-reading the WAV. Written on the writer thread; read by
    // drainedSamples() only after finish() has joined. Bounded by the recording cap (~19 MiB @16 kHz /
    // ~29 MiB @24 kHz for the 5-min max). Populated only when `wantsSamples`.
    private var accumulated: [Float] = []
    // False for a sample-incapable engine (e.g. Apple): skip accumulation and report no samples so the commit
    // path re-reads the WAV.
    private let wantsSamples: Bool
    // Writer-thread-only, on device-native slots (pre-resample). Starts CLOSED: capture is armed before the
    // start cue plays, so every buffer up to the cue-end boundary is audio the user was never invited to
    // speak. `.gated` trims the cue window; `.open` is the no-cue case (sounds off).
    private enum Admission {
        case closed
        case gated(HeadAdmitGate)
        case open
    }
    private var admission: Admission = .closed
    // Published by the control side at cue time and installed by the writer thread, so gate state keeps a
    // single owner. nil until the cue-end boundary is known — which cannot happen before readiness.
    private let admissionLock = NSLock()
    private var pendingAdmission: (afterHostTime: UInt64, hostTicksPerSecond: Double, cueWindowSeconds: Double)?
    // One-shot readiness signal. The first VALID buffer off the ring is the only proof the route actually
    // delivers audio — configure/initialize/start all succeed on a route that never will. Fired from the
    // writer thread; the RT callback must never signal the control path.
    private let onFirstBuffer: (@Sendable () -> Void)?
    private var signalledReady = false
    // Each post-conversion mono chunk written to the file is also handed here so a streaming session can
    // transcribe during capture. Writer thread ONLY, and MUST be non-blocking (real wiring is a bounded
    // AsyncStream yield) — never the realtime IO thread. nil when streaming is off.
    private let onSamples: (@Sendable ([Float]) -> Void)?

    // Frames accepted off the ring but not persisted — invisible to the ring canaries, so surfaced at teardown.
    private var droppedFrames = 0
    private var loggedFirstDrop = false
    private var converterBuildError: Error?
    // Ring overruns as of the seal; post-seal RT pushes overrun a ring this sealed writer no longer drains, so
    // they must not reach the ringDropped canary. nil until sealed.
    private var ringDropsAtSeal: Int?

    init(ring: AudioSampleRing, file: (any CaptureFileWriting)?, recordFormat: AVAudioFormat,
         wantsSamples: Bool = true,
         onSamples: (@Sendable ([Float]) -> Void)? = nil,
         onFirstBuffer: (@Sendable () -> Void)? = nil,
         observeHostTime: @escaping (UInt64?) -> Bool) {
        self.ring = ring
        self.file = file
        self.recordFormat = recordFormat
        self.wantsSamples = wantsSamples
        self.onSamples = onSamples
        self.onFirstBuffer = onFirstBuffer
        self.observeHostTime = observeHostTime
        // Pre-size to ~30 s of record-rate mono so a multi-minute dictation avoids re-copying the multi-MiB
        // prefix through repeated doubling.
        if wantsSamples { accumulated.reserveCapacity(Int(recordFormat.sampleRate * 30)) }
    }

    func start() {
        let outcome: (isFirstStart: Bool, finishRequested: Bool) = lifecycleLock.withLock {
            guard !didStart else { return (false, false) }
            didStart = true
            done.enter()
            return (true, finishRequested)
        }
        guard outcome.isFirstStart else { return }
        // A finish() landed before the thread was spawned; carry its stop in so the thread stops promptly
        // rather than running the full capture (flushOnStop was already set by that finish()).
        if outcome.finishRequested { stopRequested.store(true, ordering: .releasing) }
        let t = Thread { [weak self] in self?.run() }
        t.name = "com.keyscribe.audio.writer"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    private func run() {
        while true {
            drainReady()
            if sealed || stopRequested.load(ordering: .acquiring) { break }
            _ = shutdown.wait(timeout: .now() + Self.pollInterval)
        }
        let flushing = flushOnStop.load(ordering: .acquiring)
        if !sealed && flushing { flushConverterTail() }
        // Drop heavy resources before `lastWriter` keeps the writer around for the next arm.
        file = nil
        converter = nil
        inBuffer = nil
        outBuffer = nil
        // Free the accumulator only on the cancel/discard path so the writer doesn't pin the multi-MiB copy
        // while idle. Guard on `!sealed`: a sealed COMMIT exits here BEFORE finish(flushConverter:true)
        // sets `flushOnStop`, so `flushing` reads false — clearing then would drop the committed samples
        // finishWriterAndCloseFile is about to read. Commit paths keep it and clear via releaseSamples() after
        // the copy, once this thread has joined.
        if !sealed && !flushing { accumulated = [] }
        done.leave()
    }

    // Stop as soon as the drain gate trips; later post-release slots are discarded.
    private func drainReady() {
        while !sealed {
            let had = ring.read { [self] info, channel in
                consume(info, channel: channel)
            }
            if !had { break }
        }
    }

    private func consume(_ info: AudioSampleRing.SlotInfo, channel: (Int) -> UnsafeBufferPointer<Float>) {
        guard AudioCapture.isUsableInputFormat(
            sampleRate: info.sampleRate, channelCount: AVAudioChannelCount(info.channelCount)) else {
            recordDrop(frames: info.frameCount, reason: "unusable input format")
            return
        }
        // Readiness FIRST: this buffer is what proves the mic is live, and admission is still closed while the
        // cue has not played — so a readiness check below the gate would never see the buffer it needs.
        signalReadyIfFirst()
        installPendingAdmission()
        // Head admission: drop/trim cue-window frames before the boundary, before conversion/write.
        var offset = 0
        var count = info.frameCount
        switch admission {
        case .closed: return  // pre-cue audio, discarded by design — never a drop canary
        case .open: break
        case .gated(var gate):
            let host: UInt64? = info.hostTime == 0 ? nil : info.hostTime
            let outcome = gate.observe(slotStartHostTime: host, frameCount: info.frameCount, sampleRate: info.sampleRate)
            admission = .gated(gate)
            switch outcome {
            case .admit: break
            case .drop: return
            case .admitTrailing(let dropFrames): offset = dropFrames; count = info.frameCount - dropFrames
            }
        }
        guard count > 0 else { return }
        guard let input = inputBuffer(for: info) else {
            recordDrop(frames: count, reason: "input buffer unavailable")
            return
        }
        input.frameLength = AVAudioFrameCount(count)
        if let dst = input.floatChannelData {
            for c in 0..<info.channelCount {
                let src = channel(c)
                dst[c].update(from: src.baseAddress!.advanced(by: offset), count: count)
            }
        }
        write(input)
        let host: UInt64? = info.hostTime == 0 ? nil : info.hostTime
        if observeHostTime(host) {
            // Snapshot before the tail flush: the RT thread keeps pushing during the flush, and those overruns
            // are post-release too, so they must not reach the seal snapshot.
            ringDropsAtSeal = ring.droppedCount
            flushConverterTail()
            sealed = true
        }
    }

    private func signalReadyIfFirst() {
        guard !signalledReady else { return }
        signalledReady = true
        onFirstBuffer?()
    }

    // Publish the cue-end boundary. Control side (any thread); the writer thread does the install.
    func openAdmission(afterHostTime: UInt64, hostTicksPerSecond: Double, cueWindowSeconds: Double) {
        admissionLock.withLock {
            pendingAdmission = (afterHostTime, hostTicksPerSecond, cueWindowSeconds)
        }
    }

    // Writer thread only. A 0 boundary means no cue played, so there is nothing to keep out of the recording.
    private func installPendingAdmission() {
        guard case .closed = admission else { return }
        guard let pending = admissionLock.withLock({ pendingAdmission }) else { return }
        guard pending.afterHostTime != 0, pending.hostTicksPerSecond > 0 else {
            admission = .open
            return
        }
        admission = .gated(HeadAdmitGate(
            admitAfterHostTime: pending.afterHostTime, hostTicksPerSecond: pending.hostTicksPerSecond,
            fallbackDropSeconds: pending.cueWindowSeconds))
    }

    // Rebuild when the native rate/channels change, which also resets the resampler.
    private func inputBuffer(for info: AudioSampleRing.SlotInfo) -> AVAudioPCMBuffer? {
        if let inputFormat, inputFormat.sampleRate == info.sampleRate,
           Int(inputFormat.channelCount) == info.channelCount, let inBuffer {
            return inBuffer
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: info.sampleRate,
            channels: AVAudioChannelCount(info.channelCount), interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(ring.maxFramesPerSlot)) else { return nil }
        inputFormat = format
        inBuffer = buffer
        converter = nil
        outBuffer = nil
        return buffer
    }

    // Write to the file and report whether it landed, so callers only expose samples the WAV actually holds.
    private func writeToFile(_ file: any CaptureFileWriting, _ buffer: AVAudioPCMBuffer) -> Bool {
        do { try file.write(from: buffer); return true }
        catch { recordDrop(frames: Int(buffer.frameLength), reason: error.localizedDescription); return false }
    }

    private func recordDrop(frames: Int, reason: String) {
        guard frames > 0 else { return }
        droppedFrames += frames
        guard !loggedFirstDrop else { return }
        loggedFirstDrop = true
        Log.audio.error("capture writer dropped a chunk: \(reason, privacy: .public)")
    }

    // Safe only after finish() has joined the thread.
    func writerDroppedFrames() -> Int { droppedFrames }

    // nil when the gate never tripped (backstop/cancel drained to the end → the live count is already accurate).
    // Safe only after finish() has joined the thread.
    func ringDropCountAtSeal() -> Int? { ringDropsAtSeal }

    private func write(_ input: AVAudioPCMBuffer) {
        guard let file else { return }
        let inFmt = input.format
        if inFmt.sampleRate == recordFormat.sampleRate && inFmt.channelCount == recordFormat.channelCount {
            // Mirror to the accumulator/streaming sink only if the WAV write landed, so in-memory samples never
            // contain a chunk the file lacks — samples == WAV, true by construction.
            if writeToFile(file, input) { appendSamples(from: input) }
            return
        }
        if converter == nil {
            var built: AVAudioConverter?
            do { try ObjCException.catching { built = AVAudioConverter(from: inFmt, to: recordFormat) } }
            catch { converterBuildError = error }
            converter = built
        }
        guard let converter else {
            recordDrop(frames: Int(input.frameLength),
                       reason: converterBuildError?.localizedDescription ?? "converter unavailable")
            return
        }
        let ratio = recordFormat.sampleRate / inFmt.sampleRate
        let needed = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        if outBuffer == nil || outBuffer!.frameCapacity < needed {
            outBuffer = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: needed)
        }
        guard let outBuffer else { recordDrop(frames: Int(input.frameLength), reason: "output buffer unavailable"); return }
        outBuffer.frameLength = 0
        feed.buffer = input
        feed.consumed = false
        var convError: NSError?
        _ = converter.convert(to: outBuffer, error: &convError) { _, status in
            if self.feed.consumed { status.pointee = .noDataNow; return nil }
            self.feed.consumed = true
            status.pointee = .haveData
            return self.feed.buffer
        }
        guard convError == nil, outBuffer.frameLength > 0 else {
            if let convError { recordDrop(frames: Int(input.frameLength), reason: convError.localizedDescription) }
            return
        }
        if writeToFile(file, outBuffer) { appendSamples(from: outBuffer) }
    }

    // Mirror the mono PCM written to the file into the accumulator (and streaming sink), so an engine's
    // samples are bit-identical to the WAV.
    private func appendSamples(from buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let ptr = buffer.floatChannelData?[0] else { return }
        let slice = UnsafeBufferPointer(start: ptr, count: n)
        // Skip the accumulator when the engine can't consume in-memory samples; the streaming sink is
        // independent (feeds Apple's live session) and still fires. Only allocates the copy when streaming is on.
        if wantsSamples { accumulated.append(contentsOf: slice) }
        if let onSamples { onSamples(Array(slice)) }
    }

    // Committed post-conversion mono PCM, or nil when the engine can't consume samples (caller re-reads the
    // WAV). Safe only after finish() has joined the writer thread (finishWriterAndCloseFile does that first).
    func drainedSamples() -> [Float]? { wantsSamples ? accumulated : nil }

    // Drop the accumulator after the commit path copied it out, so the writer (retained via `lastWriter`)
    // doesn't pin a redundant multi-MiB copy while idle. Safe only after finish() has joined the thread.
    func releaseSamples() { accumulated = [] }

    // Drain the resampler's internal latency (a few samples of SRC delay) into the file at end of capture so
    // the tail isn't stuck inside the converter. No-op when no conversion is happening.
    private func flushConverterTail() {
        guard let converter, let outBuffer, let file else { return }
        outBuffer.frameLength = 0
        var convError: NSError?
        _ = converter.convert(to: outBuffer, error: &convError) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        // Tail-frame count is unknown at end-of-stream; count a failed flush as one event so it isn't silent.
        if let convError { recordDrop(frames: 1, reason: "tail flush: \(convError.localizedDescription)"); return }
        if outBuffer.frameLength > 0, writeToFile(file, outBuffer) {
            appendSamples(from: outBuffer)
        }
    }

    // Request stop and block until the thread has exited, so the owner may close the file with no write in
    // flight. `flushConverter` flushes the resampler tail when the gate never tripped (e.g. the 300 ms
    // backstop fired): commit passes true, cancel passes false (file discarded). Idempotent.
    func finish(flushConverter: Bool) {
        flushOnStop.store(flushConverter, ordering: .releasing)
        // Read `didStart` under the same lock `start()` uses (see `lifecycleLock`); a finish() that raced
        // ahead of start() just records the request and returns — no thread to join yet.
        let started = lifecycleLock.withLock { () -> Bool in
            finishRequested = true
            return didStart
        }
        guard started else { return }
        // Only the first caller drives the shutdown handshake; every caller then blocks on the group until the
        // thread exits. Safe after the thread already sealed-and-left — wait() returns at once.
        if !stopRequested.exchange(true, ordering: .acquiringAndReleasing) { shutdown.signal() }
        done.wait()
    }
}
