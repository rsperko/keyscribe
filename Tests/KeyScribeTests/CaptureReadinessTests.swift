import AVFoundation
import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

// Capture is READY only once a valid input buffer has crossed off the realtime thread — a successful
// AudioUnit start return proves nothing. Readiness is observed on the writer
// thread (never signalled from the RT callback), and it must be observed ABOVE head admission: the very
// buffer that proves the mic is live arrives while admission is still closed, so a readiness check placed
// below the gate would never see it.
//
// Drives a real CaptureWriter over a real AudioSampleRing with no microphone, the same way CaptureWriterTests
// exercises the write path.
struct CaptureReadinessTests {
    private func recordFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-readiness-test-\(UUID().uuidString).wav")
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

    private final class ReadySpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _fires = 0
        private var _threadNames: [String] = []
        var fires: Int { lock.withLock { _fires } }
        var threadNames: [String] { lock.withLock { _threadNames } }
        func record() {
            let name = Thread.current.name ?? ""
            lock.withLock { _fires += 1; _threadNames.append(name) }
        }
    }

    // Runs one capture and returns only after the writer thread has joined AND the write-file is released, so
    // the WAV the caller reopens is finalized. The `file` local is confined here (its scope end is the last
    // release — the writer drops its own reference on thread exit), mirroring CaptureWriterTests.
    // `admission` nil ⇒ never opened, the pre-cue state.
    @discardableResult
    private func runCapture(
        to url: URL,
        admission: (afterHostTime: UInt64, hostTicksPerSecond: Double, cueWindowSeconds: Double)? = nil,
        slots: Int, hostTimeStride: UInt64 = 1, frames: Int = 100, sampleRate: Double = 16_000,
        onFirstBuffer: (@Sendable () -> Void)? = nil
    ) throws -> CaptureWriter {
        let format = recordFormat()
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let ring = AudioSampleRing(slotCount: 64, maxFramesPerSlot: 1024, maxChannels: 2)
        let writer = CaptureWriter(
            ring: ring, file: file, recordFormat: format,
            onFirstBuffer: onFirstBuffer, observeHostTime: { _ in false })
        writer.start()
        if let admission {
            writer.openAdmission(
                afterHostTime: admission.afterHostTime, hostTicksPerSecond: admission.hostTicksPerSecond,
                cueWindowSeconds: admission.cueWindowSeconds)
        }
        for i in 1...slots {
            ring.write(
                channelCount: 1, frameCount: frames, sampleRate: sampleRate, hostTime: UInt64(i) * hostTimeStride
            ) { _, dest in
                for k in 0..<dest.count { dest[k] = 0.25 }
            }
        }
        writer.finish(flushConverter: true)
        return writer
    }

    @Test func readinessSignalsOnceFromTheWriterThread() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let spy = ReadySpy()
        try runCapture(to: url, slots: 20, onFirstBuffer: { spy.record() })
        #expect(spy.fires == 1)
        #expect(spy.threadNames == ["com.keyscribe.audio.writer"])
    }

    @Test func anUnusableFormatBufferDoesNotSignalReadiness() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let spy = ReadySpy()
        try runCapture(to: url, slots: 3, sampleRate: 0, onFirstBuffer: { spy.record() })
        #expect(spy.fires == 0)
    }

    @Test func audioBeforeAdmissionOpensIsDiscardedWithoutAWriterDrop() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try runCapture(to: url, slots: 20)
        #expect(try readMonoFloat(url).isEmpty)
        #expect(writer.writerDroppedFrames() == 0)
    }

    @Test func openingAdmissionExcludesTheCueWindowAndKeepsEverythingAfterIt() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let slotTicks: UInt64 = 6_250_000
        try runCapture(
            to: url,
            admission: (afterHostTime: 5 * slotTicks, hostTicksPerSecond: 1e9, cueWindowSeconds: 0.03125),
            slots: 10, hostTimeStride: slotTicks)
        #expect(try readMonoFloat(url).count == 600)  // slots 5…10 admitted; 1…4 are the cue window
    }

    @Test func openingAdmissionWithNoCueBoundaryAdmitsFromReadiness() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try runCapture(
            to: url, admission: (afterHostTime: 0, hostTicksPerSecond: 1e9, cueWindowSeconds: 0),
            slots: 10, hostTimeStride: 6_250_000)
        #expect(try readMonoFloat(url).count == 1000)
    }

    @Test func aBluetoothTargetGetsAdditionalTimeToBecomeReady() {
        let bluetooth = AudioCapture.startDeadlineSeconds(targetIsBluetooth: true)
        let wired = AudioCapture.startDeadlineSeconds(targetIsBluetooth: false)
        #expect(wired == 4.0)
        #expect(bluetooth >= 8.0 && bluetooth <= 10.0)
        #expect(bluetooth > wired)
    }

    @Test func aCancelledReadinessWaitThrowsInsteadOfReportingReady() async {
        let ready = SignalLatch()  // no buffer ever arrives
        let task = Task { () -> String in
            try await AudioCapture.awaitReadiness(ready)
            return "capture.wav"
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func aFirstBufferReportsReady() async throws {
        let ready = SignalLatch()
        let task = Task { () -> String in
            try await AudioCapture.awaitReadiness(ready)
            return "capture.wav"
        }
        ready.signal()
        #expect(try await task.value == "capture.wav")
    }

    @Test func aBudgetWithNoFirstBufferNeverReportsReady() async {
        let ready = SignalLatch()
        var returned: String?
        do {
            returned = try await runWithBudget(allowedSeconds: { 0.02 }) {
                try await AudioCapture.awaitReadiness(ready)
                return "capture.wav"
            }
        } catch {
        }
        #expect(returned == nil)
    }

    private func record(targetIsBluetooth: Bool, target: String) -> CaptureStartRecord {
        CaptureStartRecord(targetIsBluetooth: targetIsBluetooth, explicitDevice: false, target: target)
    }

    @Test func firstBufferRecordsTimingAndPreventsLaterRebinds() {
        let record = record(targetIsBluetooth: false, target: "MacBook Pro Microphone")
        record.noteBound("Pan", isBluetooth: true)     // rebound to Bluetooth during arming
        record.noteFirstBuffer()                       // ...which then delivered the first buffer
        record.noteBound("Some Dock", isBluetooth: false)  // a later restart must not overwrite that
        let summary = record.summary(outcome: "ready")
        #expect(summary.contains("bound=Pan"))
        #expect(summary.contains("bound-transport=bluetooth"))
        #expect(summary.contains("first-buffer="))
        #expect(!summary.contains("Some Dock"))
    }

    @Test func aFailedStartReportsTheLastDeviceItBound() {
        let record = record(targetIsBluetooth: false, target: "MacBook Pro Microphone")
        record.noteBound("Pan", isBluetooth: true)
        #expect(record.summary(outcome: "never-ready").contains("bound=Pan"))
    }

    @Test func aStartThatNeverRebindsReportsOneTransport() {
        let record = record(targetIsBluetooth: true, target: "Pan")
        record.noteBound("Pan", isBluetooth: true)
        let summary = record.summary(outcome: "ready")
        #expect(summary.contains("transport=bluetooth"))
        #expect(!summary.contains("bound-transport="))
    }

    @Test func aPresentPreferenceNeverReadsTheSystemDefault() {
        var defaultReads = 0
        func readDefault() -> AudioDeviceID? { defaultReads += 1; return 42 }
        let target = AudioCapture.captureTarget(
            preferredUID: "airpods-uid", resolvePreferred: { _ in 7 }, systemDefault: readDefault())
        #expect(target == .preferred(7))
        #expect(defaultReads == 0)
    }

    @Test func aDisconnectedPreferenceResolvesToTheSystemDefault() {
        let target = AudioCapture.captureTarget(
            preferredUID: "absent-airpods-uid",
            resolvePreferred: { _ in nil },       // saved preference is not connected
            systemDefault: 42)
        #expect(target == .systemDefault(42))
        #expect(target.isPreferredPresent == false)
    }

    @Test func aPresentPreferenceIsHonoredOverTheSystemDefault() {
        let target = AudioCapture.captureTarget(
            preferredUID: "airpods-uid", resolvePreferred: { _ in 7 }, systemDefault: 42)
        #expect(target == .preferred(7))
        #expect(target.isPreferredPresent)
    }

    @Test func noPreferenceFollowsTheSystemDefault() {
        let target = AudioCapture.captureTarget(
            preferredUID: nil, resolvePreferred: { _ in 7 }, systemDefault: 42)
        #expect(target == .systemDefault(42))
        #expect(target.isPreferredPresent == false)
    }
}
