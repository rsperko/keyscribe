import AVFoundation
import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Exercises the writer half of the RT-thread ring split end-to-end WITHOUT a microphone: synthetic planar
// samples are pushed into a real `AudioSampleRing`, a real `CaptureWriter` drains them to a real `AVAudioFile`
// on its own thread, and the resulting WAV is read back. This covers the direct-write path, the resampling
// path, and the drain-gate seal — the logic that moved off the CoreAudio realtime thread.
// Wraps a real AVAudioFile but throws on the Nth write, so a test can prove a failed WAV write also keeps
// that chunk out of the in-memory accumulator/streaming sink.
private final class FlakyFileWriter: CaptureFileWriting, @unchecked Sendable {
    private let real: AVAudioFile
    private let failWriteIndex: Int
    private var index = 0
    private let lock = NSLock()
    init(_ real: AVAudioFile, failWriteIndex: Int) {
        self.real = real
        self.failWriteIndex = failWriteIndex
    }
    func write(from buffer: AVAudioPCMBuffer) throws {
        let i = lock.withLock { let v = index; index += 1; return v }
        if i == failWriteIndex { throw NSError(domain: "FlakyFileWriter", code: 1) }
        try real.write(from: buffer)
    }
}

struct CaptureWriterTests {
    private func recordFormat(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-writer-test-\(UUID().uuidString).wav")
    }

    // Runs one write session to `url` and returns only after the writer thread has joined AND the write-file
    // is released — so the reopened WAV is fully finalized. The `file` local is confined to this function
    // (its scope end is the last release, mirroring the production session dropping its reference), and the
    // writer drops its own reference on thread exit. `extraFinishes` re-calls finish() to prove idempotency.
    private func writeCapture(
        to url: URL, recordRate: Double, pushRate: Double, frames: Int, count: Int,
        seal: @escaping (UInt64?) -> Bool = { _ in false }, flush: Bool = true, extraFinishes: Int = 0
    ) throws {
        let format = recordFormat(recordRate)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let ring = AudioSampleRing(slotCount: 64, maxFramesPerSlot: 1024, maxChannels: 2)
        let writer = CaptureWriter(ring: ring, file: file, recordFormat: format, observeHostTime: seal)
        writer.start()
        for i in 1...count {
            ring.write(channelCount: 1, frameCount: frames, sampleRate: pushRate, hostTime: UInt64(i)) { _, dest in
                for k in 0..<dest.count { dest[k] = 0.25 }
            }
        }
        writer.finish(flushConverter: flush)
        for _ in 0..<extraFinishes { writer.finish(flushConverter: flush) }
    }

    // Runs a full session and returns the writer's in-memory samples (drainedSamples()) AFTER the thread has
    // joined and the writer dropped its file reference. Does NOT read the WAV — the caller does that after
    // this returns, when the local `file` releases, so the reopened file is finalized (see writeCapture).
    private func drainedFromCapture(
        to url: URL, recordRate: Double, pushRate: Double, frames: Int, count: Int,
        wantsSamples: Bool = true, flush: Bool = true, seal: @escaping (UInt64?) -> Bool = { _ in false }
    ) throws -> [Float]? {
        let format = recordFormat(recordRate)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let ring = AudioSampleRing(slotCount: 64, maxFramesPerSlot: 1024, maxChannels: 2)
        let writer = CaptureWriter(
            ring: ring, file: file, recordFormat: format, wantsSamples: wantsSamples,
            observeHostTime: seal)
        writer.start()
        for i in 1...count {
            ring.write(channelCount: 1, frameCount: frames, sampleRate: pushRate, hostTime: UInt64(i)) { _, dest in
                for k in 0..<dest.count { dest[k] = 0.25 }
            }
        }
        writer.finish(flushConverter: flush)
        return writer.drainedSamples()
    }

    // Runs a direct-write (native == record) session where the writer's Nth file write throws, returning the
    // writer's in-memory samples after the thread joined and the wrapping file references released.
    private func drainedFromFlakyCapture(to url: URL, frames: Int, count: Int, failWriteIndex: Int) throws -> [Float]? {
        let format = recordFormat(16_000)
        let real = try AVAudioFile(forWriting: url, settings: format.settings)
        let flaky = FlakyFileWriter(real, failWriteIndex: failWriteIndex)
        let ring = AudioSampleRing(slotCount: 64, maxFramesPerSlot: 1024, maxChannels: 2)
        let writer = CaptureWriter(ring: ring, file: flaky, recordFormat: format, observeHostTime: { _ in false })
        writer.start()
        for i in 1...count {
            ring.write(channelCount: 1, frameCount: frames, sampleRate: 16_000, hostTime: UInt64(i)) { _, dest in
                for k in 0..<dest.count { dest[k] = 0.25 }
            }
        }
        writer.finish(flushConverter: true)
        return writer.drainedSamples()
    }

    private func readMonoFloat(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    @Test func directWritePathRoundTripsEveryFrame() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeCapture(to: url, recordRate: 16_000, pushRate: 16_000, frames: 160, count: 10)
        let read = try AVAudioFile(forReading: url)
        #expect(read.length == 1600)  // 10 × 160, native == record ⇒ no conversion, nothing lost
    }

    @Test func resamplingPathProducesDownsampledFrames() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeCapture(to: url, recordRate: 16_000, pushRate: 48_000, frames: 480, count: 10)
        let read = try AVAudioFile(forReading: url)
        // 4800 input frames at 3:1 ⇒ ~1600 output frames; allow resampler edge/latency slack.
        #expect(read.length > 1400 && read.length < 1800)
    }

    @Test func gateTripSealsAndStopsWriting() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Trip the gate once a slot with host time ≥ 5 is observed: slots 1–5 are written (the tripping slot
        // is written before the gate is fed, mirroring production), later slots are discarded.
        try writeCapture(to: url, recordRate: 16_000, pushRate: 16_000, frames: 100, count: 20,
                         seal: { host in (host ?? 0) >= 5 })
        let read = try AVAudioFile(forReading: url)
        #expect(read.length == 500)  // slots 1…5 × 100 frames; slots 6…20 dropped after the seal
    }

    // P2-4: mainline STT now transcribes drainedSamples(), not the WAV — they must be sample-for-sample
    // identical, even through the resampler (48 kHz push → 16 kHz record) and its tail flush.
    @Test func drainedSamplesAreBitIdenticalToTheWAV() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let drained = try drainedFromCapture(to: url, recordRate: 16_000, pushRate: 48_000, frames: 480, count: 10)
        let wav = try readMonoFloat(url)
        #expect(!wav.isEmpty)
        #expect(drained == wav)
    }

    // P2-2: an engine that can't consume samples (Apple) gets none — the accumulator is skipped and reported
    // nil — while the WAV is still written in full.
    @Test func noSamplesAccumulatedWhenEngineCannotConsumeThem() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let drained = try drainedFromCapture(
            to: url, recordRate: 16_000, pushRate: 16_000, frames: 160, count: 10, wantsSamples: false)
        #expect(drained == nil)
        let wav = try readMonoFloat(url)
        #expect(wav.count == 1600)  // file still fully written
    }

    // P2-1 regression: a sealed COMMIT exits run() on the drain-gate trip BEFORE finish(flushConverter:true)
    // sets flushOnStop, so the "clear when not flushing" logic must not fire — the committed samples the
    // caller is about to read via drainedSamples() must survive.
    @Test func sealedCommitRetainsTheAccumulatorForTheCaller() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Seal once a slot with host time ≥ 5 is observed (slots 1…5 written, then sealed).
        let drained = try drainedFromCapture(
            to: url, recordRate: 16_000, pushRate: 16_000, frames: 100, count: 20,
            flush: true, seal: { ($0 ?? 0) >= 5 })
        #expect(drained?.count == 500)  // 5 × 100 frames survive the seal, not cleared to []
    }

    // P2-1: the cancel/discard path (flushConverter == false) must not leave the writer pinning the multi-MiB
    // accumulator until the next arm — it is cleared on thread exit.
    @Test func cancelPathClearsTheAccumulator() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let drained = try drainedFromCapture(
            to: url, recordRate: 16_000, pushRate: 16_000, frames: 160, count: 10, flush: false)
        #expect(drained?.isEmpty == true)
    }

    // Review follow-up: a failed WAV write must also keep that chunk out of the in-memory samples mainline STT
    // transcribes — otherwise STT hears audio the file/archive/probe never got. Both drop it, staying equal.
    @Test func aFailedWriteKeepsTheAccumulatorInLockstepWithTheWAV() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Direct path ⇒ one write per slot; the 3rd write (index 2) throws.
        let drained = try drainedFromFlakyCapture(to: url, frames: 100, count: 5, failWriteIndex: 2)
        let wav = try readMonoFloat(url)
        #expect(wav.count == 400)   // 5 × 100 − the dropped 100-frame write
        #expect(drained == wav)     // in-memory samples never include the un-written chunk
    }

    @Test func finishIsIdempotentAcrossMultipleCallers() throws {
        // Both the teardown path and the next capture's arm can call finish() — every caller must return only
        // after the thread has exited, and repeat calls must not hang or corrupt the file.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeCapture(to: url, recordRate: 16_000, pushRate: 16_000, frames: 80, count: 4, extraFinishes: 2)
        let read = try AVAudioFile(forReading: url)
        #expect(read.length == 320)
    }

    @Test func finishBeforeStartDoesNotHangAndAStartAfterwardStillStops() throws {
        // A finish() that races ahead of start() must return promptly (nothing to join yet) rather than wait on
        // an empty group; start() then honors that stop so the thread self-terminates and a following finish()
        // joins without hanging or double-leaving the group. If the lifecycle accounting were wrong this would
        // hang (empty-group wait) or crash (unbalanced leave).
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = recordFormat(16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let ring = AudioSampleRing(slotCount: 8, maxFramesPerSlot: 1024, maxChannels: 2)
        let writer = CaptureWriter(ring: ring, file: file, recordFormat: format, observeHostTime: { _ in false })
        writer.finish(flushConverter: false)
        writer.start()
        writer.finish(flushConverter: false)
    }
}
