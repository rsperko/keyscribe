import Foundation
import Testing
@testable import KeyScribeKit

// The lock-free SPSC ring is the RT-safe transport that replaced the per-buffer lock + file write on
// the CoreAudio IO thread.
struct AudioSampleRingTests {
    private func push(_ ring: AudioSampleRing, base: Float, channels: Int, frames: Int, host: UInt64) -> Bool {
        ring.write(channelCount: channels, frameCount: frames, sampleRate: 48_000, hostTime: host) { c, dest in
            for i in 0..<dest.count { dest[i] = base + Float(c) }
        }
    }

    @Test func singleWriteReadRoundTripsSamplesAndMetadata() {
        let ring = AudioSampleRing(slotCount: 4, maxFramesPerSlot: 8, maxChannels: 2)
        #expect(push(ring, base: 3, channels: 2, frames: 5, host: 111))
        var seen: AudioSampleRing.SlotInfo?
        var ch0 = [Float](); var ch1 = [Float]()
        let got = ring.read { info, channel in
            seen = info
            ch0 = Array(channel(0)); ch1 = Array(channel(1))
        }
        #expect(got)
        #expect(seen == .init(frameCount: 5, channelCount: 2, sampleRate: 48_000, hostTime: 111))
        #expect(ch0 == [3, 3, 3, 3, 3])
        #expect(ch1 == [4, 4, 4, 4, 4])
    }

    @Test func readOnEmptyReturnsFalse() {
        let ring = AudioSampleRing(slotCount: 4, maxFramesPerSlot: 8, maxChannels: 1)
        #expect(!ring.read { _, _ in Issue.record("body must not run on empty ring") })
    }

    @Test func fifoOrderIsPreserved() {
        let ring = AudioSampleRing(slotCount: 8, maxFramesPerSlot: 4, maxChannels: 1)
        for i in 1...5 { #expect(push(ring, base: Float(i), channels: 1, frames: 2, host: UInt64(i))) }
        var order = [UInt64]()
        while ring.read({ info, _ in order.append(info.hostTime) }) {}
        #expect(order == [1, 2, 3, 4, 5])
    }

    @Test func fullRingDropsAndCountsOverrun() {
        let ring = AudioSampleRing(slotCount: 2, maxFramesPerSlot: 4, maxChannels: 1)
        #expect(push(ring, base: 1, channels: 1, frames: 1, host: 1))
        #expect(push(ring, base: 2, channels: 1, frames: 1, host: 2))
        #expect(!push(ring, base: 3, channels: 1, frames: 1, host: 3))
        #expect(ring.droppedCount == 1)
        #expect(ring.read { _, _ in })
        #expect(push(ring, base: 4, channels: 1, frames: 1, host: 4))
        #expect(ring.droppedCount == 1)
    }

    @Test func geometryExceedingBuffersAreDroppedNotStored() {
        let ring = AudioSampleRing(slotCount: 4, maxFramesPerSlot: 4, maxChannels: 2)
        #expect(!push(ring, base: 1, channels: 1, frames: 5, host: 1))   // too many frames
        #expect(!push(ring, base: 1, channels: 1, frames: 0, host: 1))   // empty buffer
        #expect(ring.droppedCount == 2)
        #expect(!ring.read { _, _ in Issue.record("nothing should have been stored") })
    }

    @Test func channelsAboveStorageCapacityAreTruncatedNotDropped() {
        let ring = AudioSampleRing(slotCount: 4, maxFramesPerSlot: 4, maxChannels: 2)
        #expect(push(ring, base: 10, channels: 4, frames: 2, host: 1))
        var seen: AudioSampleRing.SlotInfo?
        var ch0 = [Float](); var ch1 = [Float]()
        #expect(ring.read { info, channel in
            seen = info
            ch0 = Array(channel(0))
            ch1 = Array(channel(1))
        })
        #expect(seen == .init(frameCount: 2, channelCount: 2, sampleRate: 48_000, hostTime: 1))
        #expect(ch0 == [10, 10])
        #expect(ch1 == [11, 11])
        #expect(ring.droppedCount == 0)
    }

    @Test func wraparoundReusesSlotsCorrectly() {
        let ring = AudioSampleRing(slotCount: 3, maxFramesPerSlot: 2, maxChannels: 1)
        for i in 0..<50 {
            #expect(push(ring, base: Float(i), channels: 1, frames: 1, host: UInt64(i)))
            var value: Float = -1
            #expect(ring.read { _, channel in value = channel(0)[0] })
            #expect(value == Float(i))
        }
    }

    @Test func resetReturnsToEmpty() {
        let ring = AudioSampleRing(slotCount: 4, maxFramesPerSlot: 4, maxChannels: 1)
        _ = push(ring, base: 1, channels: 1, frames: 1, host: 1)
        _ = push(ring, base: 9, channels: 1, frames: 9, host: 1)  // dropped (over capacity)
        ring.reset()
        #expect(!ring.read { _, _ in Issue.record("ring must be empty after reset") })
        #expect(ring.droppedCount == 0)
    }

    // Adaptive geometry: slot count grows for small-buffer devices to keep headroom above the writer poll
    // tick; per-slot/channel capacity never shrinks below the fixed baseline.
    private let poll = 0.005
    private func geo(frames: Int, rate: Double) -> AudioSampleRing.RingGeometry {
        AudioSampleRing.geometry(
            deviceBufferFrames: frames, deviceSampleRate: rate,
            minHeadroom: 0.03, minSlots: 8, maxSlots: 64, maxFramesPerSlot: 8192, maxChannels: 8)
    }
    private func headroom(_ g: AudioSampleRing.RingGeometry, frames: Int, rate: Double) -> Double {
        Double(g.slotCount * frames) / rate
    }

    @Test func commonPeriodKeepsTheBaselineGeometryUnchanged() {
        // A ~10 ms IO buffer must yield EXACTLY today's fixed geometry — common case byte-for-byte unchanged.
        #expect(geo(frames: 512, rate: 48_000) == .init(slotCount: 8, maxFramesPerSlot: 8192, maxChannels: 8))
        #expect(geo(frames: 1024, rate: 44_100) == .init(slotCount: 8, maxFramesPerSlot: 8192, maxChannels: 8))
    }

    @Test func smallIOBufferGrowsSlotsToKeepHeadroomAboveAPollTick() {
        // 32 frames/48 kHz is 0.67 ms/period — 8 slots (~5.3 ms) is at/below the 5 ms poll tick, so widen.
        let g = geo(frames: 32, rate: 48_000)
        #expect(g.slotCount > 8)
        #expect(headroom(g, frames: 32, rate: 48_000) >= 0.03)
    }

    @Test func headroomAlwaysClearsThePollTickAcrossPeriodSizes() {
        // The M4 correctness property: every plausible period holds more than one writer poll interval.
        for frames in [16, 24, 32, 48, 64, 96, 128, 256, 480, 512, 1024, 2048, 4096] {
            for rate in [16_000.0, 44_100.0, 48_000.0, 96_000.0] {
                let g = geo(frames: frames, rate: rate)
                #expect(headroom(g, frames: frames, rate: rate) > poll)
            }
        }
    }

    @Test func slotCountIsBoundedByMaxSlots() {
        // An extreme 16-frame buffer wants ~90 slots; the cap bounds memory yet still clears the poll tick.
        let g = geo(frames: 16, rate: 96_000)
        #expect(g.slotCount == 64)
        #expect(headroom(g, frames: 16, rate: 96_000) > poll)
    }

    @Test func largePeriodFloorsAtMinSlots() {
        #expect(geo(frames: 4096, rate: 48_000).slotCount == 8)
    }

    @Test func perSlotAndChannelCapacityAreNeverShrunkBelowBaseline() {
        // Shrinking either would newly drop a large or multichannel buffer the fixed ring accepts today.
        for frames in [16, 32, 512, 4096] {
            let g = geo(frames: frames, rate: 48_000)
            #expect(g.maxFramesPerSlot == 8192)
            #expect(g.maxChannels == 8)
        }
    }

    @Test func degenerateDeviceReadsFallBackToTheBaseline() {
        // 0 frames / 0 rate must not divide-by-zero or under-provision.
        #expect(geo(frames: 0, rate: 48_000).slotCount >= 8)
        #expect(geo(frames: 512, rate: 0) == .init(slotCount: 8, maxFramesPerSlot: 8192, maxChannels: 8))
    }

    @Test func aGeometrySizedRingWritesAndReadsLikeAnyOther() {
        let ring = AudioSampleRing(geo(frames: 32, rate: 48_000))
        #expect(ring.slotCount == geo(frames: 32, rate: 48_000).slotCount)
        #expect(push(ring, base: 7, channels: 1, frames: 4, host: 42))
        var host: UInt64 = 0
        #expect(ring.read { info, _ in host = info.hostTime })
        #expect(host == 42)
    }

    @Test func concurrentProducerConsumerLosesNothing() async {
        // The producer retries on a transient full ring (which legitimately bumps droppedCount), so
        // loss is proven by the consumer observing the exact host-time sequence, not by the drop count —
        // in production the RT producer never retries and a full ring is a real drop.
        let ring = AudioSampleRing(slotCount: 256, maxFramesPerSlot: 16, maxChannels: 1)
        let total = 200_000
        let producer = Task.detached(priority: .high) {
            var i = 0
            while i < total {
                let ok = ring.write(channelCount: 1, frameCount: 4, sampleRate: 16_000, hostTime: UInt64(i)) { _, dest in
                    for k in 0..<dest.count { dest[k] = Float(i &+ k) }
                }
                if ok { i += 1 }  // retry the same index on a (transient) full ring
            }
        }
        let consumer = Task.detached(priority: .medium) { () -> (Bool, Int) in
            var expected: UInt64 = 0
            var ordered = true
            while expected < UInt64(total) {
                let read = ring.read { info, channel in
                    if info.hostTime != expected { ordered = false }
                    if channel(0)[0] != Float(info.hostTime) { ordered = false }
                    expected &+= 1
                }
                if !read { await Task.yield() }
            }
            return (ordered, Int(expected))
        }
        await producer.value
        let (ordered, count) = await consumer.value
        #expect(ordered)
        #expect(count == total)
    }
}
