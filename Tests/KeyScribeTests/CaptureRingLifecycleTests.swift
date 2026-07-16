import AVFoundation
import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// KS-05: the realtime handler must not resolve its ring through mutable shared state.
//
// The gate (`capturing` + `producerGeneration`) cannot protect the ring, because a callback that PASSED the gate
// is already past it: it can be preempted between the gate and the write, and resume arbitrarily later — after
// finalization, after a watchdog abandoned its generation, after a successor armed. So the ring it writes into
// must be decided by what it captured, not by what the owner's property happens to hold when it resumes.
//
// The barrier seam parks a callback exactly there — past the gate, before `handle` — making that window
// deterministic instead of microseconds wide.
struct CaptureRingLifecycleTests {
    // HALInputUnit is not Sendable, and these tests must hand one to another thread to drive the real RT entry.
    // Mirrors the box AudioCapture already uses to pass a unit to its control queue, rather than widening the
    // production type's concurrency claim for a test's benefit.
    private final class UnitBox: @unchecked Sendable {
        let unit: HALInputUnit
        init(_ unit: HALInputUnit) { self.unit = unit }
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-ring-lifecycle-\(UUID().uuidString).wav")
    }

    private func buffer(frames: Int, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = value }
        return buffer
    }

    private func firstFrame(of ring: AudioSampleRing) -> Float? {
        var value: Float?
        ring.read { info, channel in
            guard info.frameCount > 0 else { return }
            value = channel(0)[0]
        }
        return value
    }

    private func geometry(slots: Int) -> AudioSampleRing.RingGeometry {
        AudioSampleRing.RingGeometry(slotCount: slots, maxFramesPerSlot: 1024, maxChannels: 2)
    }

    // The reviewer's case: generation A is abandoned mid-callback and generation B arms behind it. A's already
    // admitted callback must not be able to write A's samples into B's ring.
    @Test func anAdmittedCallbackFromAnAbandonedGenerationCannotWriteIntoTheSuccessorsRing() throws {
        let atGate = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let handled = DispatchSemaphore(value: 0)
        let capture = AudioCapture(realtimeBarrier: {
            atGate.signal()
            resume.wait()
        })
        let urlA = tempURL()
        let urlB = tempURL()
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let unitA = try capture.armForTesting(url: urlA, geometry: geometry(slots: 16))
        let ringA = try #require(capture.armedRingForTesting)

        // A's callback is admitted by the gate, then parked before it writes.
        let boxA = UnitBox(unitA)
        Thread.detachNewThread {
            boxA.unit.invokeHandlerForTesting(self.buffer(frames: 128, value: 0.5), hostTime: 1_000)
            handled.signal()
        }
        atGate.wait()

        // The watchdog abandons A and B arms behind it — A's writer joined first, so nothing drains ringA and the
        // assertion below sees exactly what A's callback wrote.
        capture.finalizeForTesting()
        capture.swapToFreshGenerationForTesting()
        try capture.armForTesting(url: urlB, geometry: geometry(slots: 16))
        let ringB = try #require(capture.armedRingForTesting)
        // Join B's writer too, so it cannot consume a stray frame before the assertion reads ringB.
        capture.finalizeForTesting()

        resume.signal()
        handled.wait()

        #expect(ringB !== ringA)
        // The whole point: B's audio is untouched by the dead generation's late write.
        #expect(firstFrame(of: ringB) == nil)
        // And A's frames went somewhere harmless — its own ring, which nothing will ever read again.
        #expect(firstFrame(of: ringA) == 0.5)
    }

    @Test func finalizationCannotSwapTheRingUnderAnInFlightRealtimeCallback() throws {
        let atGate = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let handled = DispatchSemaphore(value: 0)
        let capture = AudioCapture(realtimeBarrier: {
            atGate.signal()
            resume.wait()
        })
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let unit = try capture.armForTesting(url: url, geometry: geometry(slots: 16))
        let armedRing = try #require(capture.armedRingForTesting)
        #expect(armedRing.slotCount == 16)

        let box = UnitBox(unit)
        Thread.detachNewThread {
            box.unit.invokeHandlerForTesting(self.buffer(frames: 128, value: 0.5), hostTime: 1_000)
            handled.signal()
        }
        atGate.wait()

        capture.finalizeForTesting()

        resume.signal()
        handled.wait()

        // The buffer landed in the ring the capture armed, not in a replacement the callback never agreed to.
        #expect(firstFrame(of: armedRing) == 0.5)
        #expect(armedRing.slotCount == 16)
    }

    // A ring instance belongs to exactly one arm — the property the per-unit binding rests on. If two captures
    // shared (or reset) one ring, binding it per-unit would still let a dead generation's write reach a live
    // capture's audio.
    @Test func eachArmGetsItsOwnRingInstanceEvenWhenTheGeometryIsIdentical() throws {
        let capture = AudioCapture()
        let urlA = tempURL()
        let urlB = tempURL()
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try capture.armForTesting(url: urlA, geometry: geometry(slots: 16))
        let ringA = try #require(capture.armedRingForTesting)
        capture.finalizeForTesting()

        try capture.armForTesting(url: urlB, geometry: geometry(slots: 16))
        let ringB = try #require(capture.armedRingForTesting)
        capture.finalizeForTesting()

        #expect(ringA !== ringB)
    }
}
