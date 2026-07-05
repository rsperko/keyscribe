import AVFoundation
import Foundation
import KeyScribeKit
import Synchronization

final class FeedOnce: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    var consumed = false
}

// Seam over the capture file write so the WAV and the in-memory samples stay in lockstep even on a write
// failure, and so a fake can force a failure in tests. AVAudioFile satisfies it directly.
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
    // The thread's lifetime, joinable by MANY waiters: both the teardown path AND the next capture's arm can
    // call finish() concurrently (across a control-queue swap), and every caller must block until the thread
    // has fully exited before the shared ring is reset. A DispatchGroup (unlike a one-shot semaphore) releases
    // all waiters on the single leave() and returns immediately for any wait() after exit.
    private let done = DispatchGroup()
    private let stopRequested = Atomic<Bool>(false)
    private let flushOnStop = Atomic<Bool>(false)
    private var started = false
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
    // Post-conversion mono PCM (record rate), accumulated alongside the file write so the committed
    // capture can be handed to a sample-capable engine without re-reading the WAV (P2-1). Written on the
    // writer thread; read by drainedSamples() only after finish() has joined the thread. Bounded by the
    // recording cap (~19 MiB @16 kHz / ~29 MiB @24 kHz for the 5-min max), freed with the session.
    // Only populated when `wantsSamples` — a sample-incapable engine (e.g. Apple) never reads it, so the
    // per-chunk memcpy and peak memory are skipped for it (P2-2).
    private var accumulated: [Float] = []
    // The active engine can transcribe from in-memory samples; when false, skip accumulation entirely and
    // report no samples so the commit path re-reads the WAV instead.
    private let wantsSamples: Bool
    // Discards head buffers before the cue-end admission boundary (nil when nothing is gated). Writer-thread-
    // only, operating on device-native slots (pre-resample).
    private var headGate: HeadAdmitGate?
    // Streaming feed (P3-1): when set, each post-conversion mono chunk written to the file is also handed to
    // this sink so a streaming session can transcribe during capture. Called on the writer thread ONLY, and
    // MUST be non-blocking (the real wiring is a bounded AsyncStream yield) — never the realtime IO thread.
    // nil when streaming is off, so the batch path allocates and does nothing extra.
    private let onSamples: (@Sendable ([Float]) -> Void)?

    init(ring: AudioSampleRing, file: (any CaptureFileWriting)?, recordFormat: AVAudioFormat,
         admitAfterHostTime: UInt64 = 0, hostTicksPerSecond: Double = 0,
         wantsSamples: Bool = true,
         onSamples: (@Sendable ([Float]) -> Void)? = nil,
         observeHostTime: @escaping (UInt64?) -> Bool) {
        self.ring = ring
        self.file = file
        self.recordFormat = recordFormat
        self.wantsSamples = wantsSamples
        self.onSamples = onSamples
        self.observeHostTime = observeHostTime
        if admitAfterHostTime != 0, hostTicksPerSecond > 0 {
            headGate = HeadAdmitGate(admitAfterHostTime: admitAfterHostTime, hostTicksPerSecond: hostTicksPerSecond)
        }
        // Pre-size the accumulator to ~30 s of record-rate mono so a multi-minute dictation stops
        // re-copying the whole multi-MiB prefix through repeated doubling.
        if wantsSamples { accumulated.reserveCapacity(Int(recordFormat.sampleRate * 30)) }
    }

    func start() {
        guard !started else { return }
        started = true
        done.enter()
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
        // The cancel/discard path discards the audio, so don't let the writer pin the multi-MiB accumulator
        // until the next arm replaces it (P2-1). Guard on `!sealed` too: a sealed COMMIT exits here on its own
        // (the drain-gate trip) BEFORE finish(flushConverter:true) has set `flushOnStop`, so `flushing` reads
        // false — clearing then would drop the committed samples finishWriterAndCloseFile is about to read.
        // The commit paths (sealed, or backstop with `flushing`) keep it and clear via releaseSamples() after
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
            sampleRate: info.sampleRate, channelCount: AVAudioChannelCount(info.channelCount)) else { return }
        // Head admission: drop/trim cue-window frames before the boundary, before conversion/write.
        var offset = 0
        var count = info.frameCount
        if var gate = headGate {
            let host: UInt64? = info.hostTime == 0 ? nil : info.hostTime
            let outcome = gate.observe(slotStartHostTime: host, frameCount: info.frameCount, sampleRate: info.sampleRate)
            headGate = gate
            switch outcome {
            case .admit: break
            case .drop: return
            case .admitTrailing(let dropFrames): offset = dropFrames; count = info.frameCount - dropFrames
            }
        }
        guard count > 0, let input = inputBuffer(for: info) else { return }
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
            flushConverterTail()
            sealed = true
        }
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
        do { try file.write(from: buffer); return true } catch { return false }
    }

    private func write(_ input: AVAudioPCMBuffer) {
        guard let file else { return }
        let inFmt = input.format
        if inFmt.sampleRate == recordFormat.sampleRate && inFmt.channelCount == recordFormat.channelCount {
            // Only mirror to the accumulator/streaming sink if the WAV write landed, so the in-memory samples
            // mainline STT transcribes never contain a chunk the file/archive/probe lacks (keeps P2-4's
            // samples==WAV invariant true by construction, not just under the probe).
            if writeToFile(file, input) { appendSamples(from: input) }
            return
        }
        if converter == nil {
            var built: AVAudioConverter?
            try? ObjCException.catching { built = AVAudioConverter(from: inFmt, to: recordFormat) }
            converter = built
        }
        guard let converter else { return }
        let ratio = recordFormat.sampleRate / inFmt.sampleRate
        let needed = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        if outBuffer == nil || outBuffer!.frameCapacity < needed {
            outBuffer = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: needed)
        }
        guard let outBuffer else { return }
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
        guard convError == nil, outBuffer.frameLength > 0 else { return }
        if writeToFile(file, outBuffer) { appendSamples(from: outBuffer) }
    }

    // Mirror the mono PCM written to the file into the in-memory accumulator. Same buffer, same samples,
    // so the samples an engine consumes are bit-identical to the WAV's content.
    private func appendSamples(from buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let ptr = buffer.floatChannelData?[0] else { return }
        let slice = UnsafeBufferPointer(start: ptr, count: n)
        // Skip the accumulator when the active engine can't consume in-memory samples (P2-2); the streaming
        // sink below is independent (it feeds Apple's live session) and still fires.
        if wantsSamples { accumulated.append(contentsOf: slice) }
        // The streaming session sees the SAME samples the file/accumulator get, so a streamed transcript is
        // bit-identical in source to the committed WAV. Only allocates the copy when streaming is on.
        if let onSamples { onSamples(Array(slice)) }
    }

    // The committed capture's post-conversion mono PCM, or nil when the engine can't consume samples
    // (accumulation was skipped — the caller re-reads the WAV). Safe to call only after finish() has joined
    // the writer thread (the caller — AudioCapture.finishWriterAndCloseFile — does exactly that first).
    func drainedSamples() -> [Float]? { wantsSamples ? accumulated : nil }

    // Drop the accumulator after the commit path has copied it out (via drainedSamples()), so the writer —
    // retained via `lastWriter` until the next arm — does not pin a redundant multi-MiB copy while idle
    // (P2-1). Safe only after finish() has joined the writer thread; the caller does that first.
    func releaseSamples() { accumulated = [] }

    // Drain the resampler's internal latency (a few samples of SRC delay) into the file at end of capture,
    // so the very tail isn't left stuck inside the converter. No-op when no conversion is happening.
    private func flushConverterTail() {
        guard let converter, let outBuffer, let file else { return }
        outBuffer.frameLength = 0
        var convError: NSError?
        _ = converter.convert(to: outBuffer, error: &convError) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if convError == nil, outBuffer.frameLength > 0, writeToFile(file, outBuffer) {
            appendSamples(from: outBuffer)
        }
    }

    // Request the thread to stop and block until it has fully exited, so the owner may then close the file
    // with no write in flight. `flushConverter` flushes the resampler tail when the gate never tripped
    // (e.g. the 300 ms backstop fired) — the commit path passes true, cancel passes false (the file is
    // discarded). Idempotent.
    func finish(flushConverter: Bool) {
        guard started else { return }
        flushOnStop.store(flushConverter, ordering: .releasing)
        // Only the first caller drives the shutdown handshake (release the store above BEFORE the run loop's
        // acquiring load of stopRequested sees it); every caller then blocks on the group until the thread
        // has left. Safe to call after the thread already sealed-and-left — wait() returns at once.
        if !stopRequested.exchange(true, ordering: .acquiringAndReleasing) { shutdown.signal() }
        done.wait()
    }
}
