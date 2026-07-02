import AVFoundation
import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Exercises the writer half of the RT-thread ring split end-to-end WITHOUT a microphone: synthetic planar
// samples are pushed into a real `AudioSampleRing`, a real `CaptureWriter` drains them to a real `AVAudioFile`
// on its own thread, and the resulting WAV is read back. This covers the direct-write path, the resampling
// path, and the drain-gate seal — the logic that moved off the CoreAudio realtime thread.
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

    @Test func finishIsIdempotentAcrossMultipleCallers() throws {
        // Both the teardown path and the next capture's arm can call finish() — every caller must return only
        // after the thread has exited, and repeat calls must not hang or corrupt the file.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeCapture(to: url, recordRate: 16_000, pushRate: 16_000, frames: 80, count: 4, extraFinishes: 2)
        let read = try AVAudioFile(forReading: url)
        #expect(read.length == 320)
    }
}
