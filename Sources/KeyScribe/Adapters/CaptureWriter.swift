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

    init(ring: AudioSampleRing, file: AVAudioFile?, recordFormat: AVAudioFormat,
         observeHostTime: @escaping (UInt64?) -> Bool) {
        self.ring = ring
        self.file = file
        self.recordFormat = recordFormat
        self.observeHostTime = observeHostTime
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
        guard let input = inputBuffer(for: info) else { return }
        input.frameLength = AVAudioFrameCount(info.frameCount)
        if let dst = input.floatChannelData {
            for c in 0..<info.channelCount {
                let src = channel(c)
                dst[c].update(from: src.baseAddress!, count: info.frameCount)
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
    }

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
        if convError == nil, outBuffer.frameLength > 0 { try? file.write(from: outBuffer) }
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
