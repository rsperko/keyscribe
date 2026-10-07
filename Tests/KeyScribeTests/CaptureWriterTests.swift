import AVFoundation
import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

// Exercises the writer half of the RT-thread ring split end-to-end WITHOUT a microphone: synthetic planar
// samples are pushed into a real `AudioSampleRing`, a real `CaptureWriter` drains them to a real `AVAudioFile`
// on its own thread, and the resulting WAV is read back. This covers the direct-write path, the resampling
// path, and the drain-gate seal — the logic that moved off the CoreAudio realtime thread.
//
// Each session opens admission with a 0 boundary right after start(): a writer arms CLOSED (it must not record
// before the start cue proves the mic live — see CaptureReadinessTests), and these tests predate cue gating,
// so opening immediately is what keeps them testing the write path rather than the gate.
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
        writer.openAdmission(afterHostTime: 0, hostTicksPerSecond: 0, cueWindowSeconds: 0)
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
        writer.openAdmission(afterHostTime: 0, hostTicksPerSecond: 0, cueWindowSeconds: 0)
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
        writer.openAdmission(afterHostTime: 0, hostTicksPerSecond: 0, cueWindowSeconds: 0)
        for i in 1...count {
            ring.write(channelCount: 1, frameCount: frames, sampleRate: 16_000, hostTime: UInt64(i)) { _, dest in
                for k in 0..<dest.count { dest[k] = 0.25 }
            }
        }
        writer.finish(flushConverter: true)
        return writer.drainedSamples()
    }

    private func droppedFramesFromFlakyCapture(to url: URL, frames: Int, count: Int, failWriteIndex: Int) throws -> Int {
        let format = recordFormat(16_000)
        let real = try AVAudioFile(forWriting: url, settings: format.settings)
        let flaky = FlakyFileWriter(real, failWriteIndex: failWriteIndex)
        let ring = AudioSampleRing(slotCount: 64, maxFramesPerSlot: 1024, maxChannels: 2)
        let writer = CaptureWriter(ring: ring, file: flaky, recordFormat: format, observeHostTime: { _ in false })
        writer.start()
        writer.openAdmission(afterHostTime: 0, hostTicksPerSecond: 0, cueWindowSeconds: 0)
        for i in 1...count {
            ring.write(channelCount: 1, frameCount: frames, sampleRate: 16_000, hostTime: UInt64(i)) { _, dest in
                for k in 0..<dest.count { dest[k] = 0.25 }
            }
        }
        writer.finish(flushConverter: true)
        return writer.writerDroppedFrames()
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

    private typealias Slot = (channels: Int, rate: Double, frames: Int, source: UInt32)

    private struct MultichannelCapture {
        let writer: CaptureWriter
        let drained: [Float]
    }

    // `signal(channel, frame)` is evaluated at the frame's position in the whole take, so a tone stays
    // phase-continuous across slots. The ring holds every pushed slot, so nothing overruns while the writer polls.
    private func multichannelCapture(
        to url: URL, slots: [Slot], recordRate: Double = 16_000,
        signal: @escaping (Int, Int, Double) -> Float
    ) throws -> MultichannelCapture {
        let format = recordFormat(recordRate)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let ring = AudioSampleRing(
            slotCount: slots.count + 2, maxFramesPerSlot: slots.map { $0.frames }.max()!, maxChannels: 8)
        let writer = CaptureWriter(ring: ring, file: file, recordFormat: format, observeHostTime: { _ in false })
        writer.start()
        writer.openAdmission(afterHostTime: 0, hostTicksPerSecond: 0, cueWindowSeconds: 0)
        var frameStart = 0
        var rateStart = slots.first?.rate ?? recordRate
        for (i, slot) in slots.enumerated() {
            if slot.rate != rateStart { rateStart = slot.rate; frameStart = 0 }
            let base = frameStart
            ring.write(channelCount: slot.channels, frameCount: slot.frames, sampleRate: slot.rate,
                       hostTime: UInt64(i + 1), sourceID: slot.source) { c, dest in
                for k in 0..<dest.count { dest[k] = signal(c, base + k, slot.rate) }
            }
            frameStart += slot.frames
        }
        writer.finish(flushConverter: true)
        return MultichannelCapture(writer: writer, drained: writer.drainedSamples() ?? [])
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    private func tone(_ frame: Int, _ rate: Double, amplitude: Float = 0.3) -> Float {
        amplitude * Float(sin(2 * Double.pi * 440 * Double(frame) / rate))
    }

    // Deterministic, roughly uniform noise in [-amplitude, amplitude].
    private func noise(_ frame: Int, amplitude: Float) -> Float {
        var x = UInt32(truncatingIfNeeded: frame &* 2_654_435_761 &+ 12_345)
        x ^= x >> 13; x &*= 0x5bd1_e995; x ^= x >> 15
        return amplitude * (Float(x) / Float(UInt32.max) * 2 - 1)
    }

    private func repeated(_ count: Int, channels: Int, rate: Double, frames: Int, source: UInt32 = 0) -> [Slot] {
        Array(repeating: (channels, rate, frames, source), count: count)
    }

    @Test func aSignalOnlyOnTheSecondChannelIsWrittenAtFullLevelWithoutResampling() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try multichannelCapture(
            to: url, slots: repeated(20, channels: 2, rate: 16_000, frames: 160)) { c, _, _ in c == 1 ? 0.25 : 0 }
        let wav = try readMonoFloat(url)
        #expect(wav.count == 3200)
        #expect(abs(rms(wav[...]) - 0.25) < 0.0025)
        #expect(capture.drained == wav)
    }

    @Test func aToneOnlyOnTheSecondChannelSurvivesResamplingAtFullLevel() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try multichannelCapture(
            to: url, slots: repeated(30, channels: 2, rate: 48_000, frames: 480)) { c, f, r in c == 1 ? tone(f, r) : 0 }
        let wav = try readMonoFloat(url)
        let expected = 0.3 / Float(2).squareRoot()
        #expect(abs(rms(wav[800..<(wav.count - 800)]) - expected) / expected < 0.03)
        #expect(capture.drained == wav)
    }

    @Test func aToneOnTheLastOfEightChannelsIsNotAttenuated() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try multichannelCapture(
            to: url, slots: repeated(30, channels: 8, rate: 48_000, frames: 480)) { c, f, r in c == 7 ? tone(f, r) : 0 }
        let wav = try readMonoFloat(url)
        let expected = 0.3 / Float(2).squareRoot()
        #expect(abs(rms(wav[800..<(wav.count - 800)]) - expected) / expected < 0.03)
        #expect(capture.drained == wav)
        #expect(capture.writer.channelSelection()?.selected == 7)
    }

    @Test func theFirstChannelIsNotSpecial() throws {
        let first = tempURL(), second = tempURL()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let slots = repeated(30, channels: 2, rate: 48_000, frames: 480)
        _ = try multichannelCapture(to: first, slots: slots) { c, f, r in c == 0 ? tone(f, r) : 0 }
        _ = try multichannelCapture(to: second, slots: slots) { c, f, r in c == 1 ? tone(f, r) : 0 }
        #expect(try readMonoFloat(first) == readMonoFloat(second))
    }

    @Test func identicalChannelsAreWrittenAtTheMonoLevelNotDoubled() throws {
        let stereo = tempURL(), mono = tempURL()
        defer { try? FileManager.default.removeItem(at: stereo); try? FileManager.default.removeItem(at: mono) }
        _ = try multichannelCapture(to: stereo, slots: repeated(30, channels: 2, rate: 48_000, frames: 480)) { _, f, r in
            tone(f, r)
        }
        _ = try multichannelCapture(to: mono, slots: repeated(30, channels: 1, rate: 48_000, frames: 480)) { _, f, r in
            tone(f, r)
        }
        #expect(try readMonoFloat(stereo) == readMonoFloat(mono))
    }

    @Test func speechArrivingOnAnotherChannelAfterNoiseTakesOverAtFullLevel() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let noiseAmplitude: Float = 0.03
        let capture = try multichannelCapture(
            to: url, slots: repeated(60, channels: 2, rate: 48_000, frames: 480)) { c, f, r in
                if c == 0 { return noise(f, amplitude: noiseAmplitude) }
                return Double(f) / r < 0.1 ? 0 : tone(f, r)
            }
        let wav = try readMonoFloat(url)
        let expected = 0.3 / Float(2).squareRoot()
        let afterSwitch = wav[Int(0.25 * 16_000)..<(wav.count - 800)]
        #expect(abs(rms(afterSwitch) - expected) / expected < 0.03)
        #expect(capture.drained == wav)
        let selection = try #require(capture.writer.channelSelection())
        #expect(selection.selected == 1)
        #expect(selection.switchCount == 1)
    }

    @Test func aShortTakeInterruptedByABumpOnAnUnusedInputStillCarriesTheSpeech() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try multichannelCapture(
            to: url, slots: repeated(150, channels: 2, rate: 48_000, frames: 480)) { c, f, r in
                let t = Double(f) / r
                if c == 1 { return tone(f, r) }
                return t >= 0.3 && t < 0.38 ? noise(f, amplitude: 0.9) : noise(f, amplitude: 0.001)
            }
        let wav = try readMonoFloat(url)
        let expected = 0.3 / Float(2).squareRoot()
        let afterBump = wav[Int(0.5 * 16_000)..<(wav.count - 800)]
        #expect(abs(rms(afterBump) - expected) / expected < 0.03)
        let selection = try #require(capture.writer.channelSelection())
        #expect(selection.selected == 1)
        #expect(selection.switchCount == 2)
    }

    @Test func theSelectorKeepsItsStateAcrossManyShortSlots() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try multichannelCapture(
            to: url, slots: repeated(300, channels: 2, rate: 48_000, frames: 96)) { c, f, r in
                if c == 0 { return noise(f, amplitude: 0.02) }
                return Double(f) / r < 0.2 ? 0 : tone(f, r)
            }
        #expect(capture.writer.channelSelection()?.switchCount == 1)
        #expect(capture.writer.writerDroppedFrames() == 0)
    }

    @Test func aRateChangeAtTheSameChannelCountKeepsWriting() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let slots = repeated(10, channels: 2, rate: 48_000, frames: 480)
            + repeated(10, channels: 2, rate: 16_000, frames: 160)
        let capture = try multichannelCapture(to: url, slots: slots) { c, _, _ in c == 1 ? 0.25 : 0 }
        let wav = try readMonoFloat(url)
        #expect(capture.writer.writerDroppedFrames() == 0)
        #expect(wav.count > 3000 && wav.count < 3400)
        #expect(abs(rms(wav[(wav.count - 1600)...]) - 0.25) < 0.0025)
        #expect(capture.writer.channelSelection()?.selected == 1)
    }

    @Test func aChangeFromStereoToMonoResumesTheMonoPath() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let slots = repeated(10, channels: 2, rate: 16_000, frames: 160)
            + repeated(10, channels: 1, rate: 16_000, frames: 160)
        let capture = try multichannelCapture(to: url, slots: slots) { c, _, _ in c == 1 ? 0.25 : 0.125 }
        let wav = try readMonoFloat(url)
        #expect(capture.writer.writerDroppedFrames() == 0)
        #expect(wav.count == 3200)
        #expect(wav[0..<1600].allSatisfy { $0 == 0.25 })
        #expect(wav[1600...].allSatisfy { $0 == 0.125 })
        #expect(capture.writer.channelSelection() == nil)
    }

    @Test func aDifferentInputWithTheSameFormatStartsAFreshSelection() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let slots = repeated(20, channels: 2, rate: 16_000, frames: 160, source: 1)
            + repeated(20, channels: 2, rate: 16_000, frames: 160, source: 2)
        let capture = try multichannelCapture(to: url, slots: slots) { c, f, _ in
            f < 3200 ? (c == 1 ? 0.25 : 0) : (c == 0 ? 0.125 : 0)
        }
        let wav = try readMonoFloat(url)
        #expect(wav.count == 6400)
        #expect(wav[0..<3200].allSatisfy { $0 == 0.25 })
        #expect(wav[3200...].allSatisfy { $0 == 0.125 })
        #expect(capture.writer.channelSelection()?.selected == 0)
        #expect(capture.writer.channelSelection()?.switchCount == 0)
    }

    @Test func theSameInputKeepsItsSelectionAcrossSlots() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try multichannelCapture(
            to: url, slots: repeated(100, channels: 2, rate: 16_000, frames: 160, source: 1)) { c, f, _ in
                f < 9600 ? (c == 1 ? 0.25 : 0) : (c == 0 ? 0.125 : 0)
            }
        #expect(capture.writer.channelSelection()?.selected == 1)
    }

    @Test func monoInputHasNoChannelSelection() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try multichannelCapture(to: url, slots: repeated(5, channels: 1, rate: 16_000, frames: 160)) { _, _, _ in
            0.25
        }
        #expect(capture.writer.channelSelection() == nil)
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

    @Test func drainedSamplesAreBitIdenticalToTheWAV() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let drained = try drainedFromCapture(to: url, recordRate: 16_000, pushRate: 48_000, frames: 480, count: 10)
        let wav = try readMonoFloat(url)
        #expect(!wav.isEmpty)
        #expect(drained == wav)
    }

    @Test func noSamplesAccumulatedWhenEngineCannotConsumeThem() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let drained = try drainedFromCapture(
            to: url, recordRate: 16_000, pushRate: 16_000, frames: 160, count: 10, wantsSamples: false)
        #expect(drained == nil)
        let wav = try readMonoFloat(url)
        #expect(wav.count == 1600)  // file still fully written
    }

    @Test func sealedCommitRetainsTheAccumulatorForTheCaller() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let drained = try drainedFromCapture(
            to: url, recordRate: 16_000, pushRate: 16_000, frames: 100, count: 20,
            flush: true, seal: { ($0 ?? 0) >= 5 })
        #expect(drained?.count == 500)  // 5 × 100 frames survive the seal, not cleared to []
    }

    @Test func cancelPathClearsTheAccumulator() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let drained = try drainedFromCapture(
            to: url, recordRate: 16_000, pushRate: 16_000, frames: 160, count: 10, flush: false)
        #expect(drained?.isEmpty == true)
    }

    @Test func aFailedWriteKeepsTheAccumulatorInLockstepWithTheWAV() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let drained = try drainedFromFlakyCapture(to: url, frames: 100, count: 5, failWriteIndex: 2)
        let wav = try readMonoFloat(url)
        #expect(wav.count == 400)   // 5 × 100 − the dropped 100-frame write
        #expect(drained == wav)     // in-memory samples never include the un-written chunk
    }

    @Test func aFailedWriteIsCountedInTheWriterDropCounter() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let dropped = try droppedFramesFromFlakyCapture(to: url, frames: 100, count: 5, failWriteIndex: 2)
        #expect(dropped == 100)
    }

    @Test func aHealthyCaptureReportsNoWriterDrops() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let dropped = try droppedFramesFromFlakyCapture(to: url, frames: 100, count: 5, failWriteIndex: -1)
        #expect(dropped == 0)
    }

    @Test func anUnusableFormatSlotIsCountedAsAWriterDrop() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = recordFormat(16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let ring = AudioSampleRing(slotCount: 64, maxFramesPerSlot: 1024, maxChannels: 2)
        let writer = CaptureWriter(ring: ring, file: file, recordFormat: format, observeHostTime: { _ in false })
        writer.start()
        writer.openAdmission(afterHostTime: 0, hostTicksPerSecond: 0, cueWindowSeconds: 0)
        for i in 1...3 {
            ring.write(channelCount: 1, frameCount: 100, sampleRate: 0, hostTime: UInt64(i)) { _, dest in
                for k in 0..<dest.count { dest[k] = 0.25 }
            }
        }
        writer.finish(flushConverter: true)
        #expect(writer.writerDroppedFrames() == 300)
    }

    @Test func postSealRingOverrunsAreExcludedFromTheSealSnapshot() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = recordFormat(16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let ring = AudioSampleRing(slotCount: 4, maxFramesPerSlot: 1024, maxChannels: 2)
        let writer = CaptureWriter(ring: ring, file: file, recordFormat: format, observeHostTime: { ($0 ?? 0) >= 1 })
        writer.start()
        writer.openAdmission(afterHostTime: 0, hostTicksPerSecond: 0, cueWindowSeconds: 0)
        ring.write(channelCount: 1, frameCount: 100, sampleRate: 16_000, hostTime: 1) { _, dest in
            for k in 0..<dest.count { dest[k] = 0.25 }
        }
        writer.finish(flushConverter: true)
        for i in 2...20 {
            ring.write(channelCount: 1, frameCount: 100, sampleRate: 16_000, hostTime: UInt64(i)) { _, dest in
                for k in 0..<dest.count { dest[k] = 0.25 }
            }
        }
        #expect(ring.droppedCount > 0)              // post-seal overruns hit the live counter
        #expect(writer.ringDropCountAtSeal() == 0)  // but the sealed snapshot excludes them
    }

    @Test func anUnsealedCaptureHasNoSealSnapshot() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = recordFormat(16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let ring = AudioSampleRing(slotCount: 64, maxFramesPerSlot: 1024, maxChannels: 2)
        let writer = CaptureWriter(ring: ring, file: file, recordFormat: format, observeHostTime: { _ in false })
        writer.start()
        writer.openAdmission(afterHostTime: 0, hostTicksPerSecond: 0, cueWindowSeconds: 0)
        for i in 1...4 {
            ring.write(channelCount: 1, frameCount: 100, sampleRate: 16_000, hostTime: UInt64(i)) { _, dest in
                for k in 0..<dest.count { dest[k] = 0.25 }
            }
        }
        writer.finish(flushConverter: true)
        #expect(writer.ringDropCountAtSeal() == nil)
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
        writer.openAdmission(afterHostTime: 0, hostTicksPerSecond: 0, cueWindowSeconds: 0)
        writer.finish(flushConverter: false)
    }
}
