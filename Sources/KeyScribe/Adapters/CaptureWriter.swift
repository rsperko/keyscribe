import AVFoundation
import Foundation
import KeyScribeKit
import Synchronization

final class FeedOnce: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    var consumed = false
}

// Single consumer of an `AudioSampleRing`; keeps resampling and file I/O off the realtime thread.
final class CaptureWriter: @unchecked Sendable {
    // Poll tick for draining the ring while keeping the realtime path syscall-free.
    private static let pollInterval: Double = 0.005

    private let ring: AudioSampleRing
    // Released when the writer thread exits; the session owns final file-close ordering.
    private var file: AVAudioFile?
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
    private var accumulated: [Float] = []
    // Discards head buffers before the cue-end admission boundary (nil when nothing is gated). Writer-thread-
    // only, operating on device-native slots (pre-resample).
    private var headGate: HeadAdmitGate?

    init(ring: AudioSampleRing, file: AVAudioFile?, recordFormat: AVAudioFormat,
         admitAfterHostTime: UInt64 = 0, hostTicksPerSecond: Double = 0,
         observeHostTime: @escaping (UInt64?) -> Bool) {
        self.ring = ring
        self.file = file
        self.recordFormat = recordFormat
        self.observeHostTime = observeHostTime
        if admitAfterHostTime != 0, hostTicksPerSecond > 0 {
            headGate = HeadAdmitGate(admitAfterHostTime: admitAfterHostTime, hostTicksPerSecond: hostTicksPerSecond)
        }
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
        if !sealed && flushOnStop.load(ordering: .acquiring) { flushConverterTail() }
        // Drop heavy resources before `lastWriter` keeps the writer around for the next arm.
        file = nil
        converter = nil
        inBuffer = nil
        outBuffer = nil
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
        if headGate != nil {
            let host: UInt64? = info.hostTime == 0 ? nil : info.hostTime
            switch headGate!.observe(slotStartHostTime: host, frameCount: info.frameCount, sampleRate: info.sampleRate) {
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

    private func write(_ input: AVAudioPCMBuffer) {
        guard let file else { return }
        let inFmt = input.format
        if inFmt.sampleRate == recordFormat.sampleRate && inFmt.channelCount == recordFormat.channelCount {
            try? file.write(from: input)
            appendSamples(from: input)
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
        try? file.write(from: outBuffer)
        appendSamples(from: outBuffer)
    }

    // Mirror the mono PCM written to the file into the in-memory accumulator. Same buffer, same samples,
    // so the samples an engine consumes are bit-identical to the WAV's content.
    private func appendSamples(from buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let ptr = buffer.floatChannelData?[0] else { return }
        accumulated.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
    }

    // The committed capture's post-conversion mono PCM. Safe to call only after finish() has joined the
    // writer thread (the caller — AudioCapture.finishWriterAndCloseFile — does exactly that first).
    func drainedSamples() -> [Float] { accumulated }

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
        if convError == nil, outBuffer.frameLength > 0 {
            try? file.write(from: outBuffer)
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
