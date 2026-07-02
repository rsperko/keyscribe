import Foundation
import Testing
@testable import KeyScribeKit

// The lock-free SPSC ring is the RT-safe transport that replaced the per-buffer lock + file write on the
// CoreAudio IO thread. These exercise it as pure logic: FIFO order, metadata fidelity, wraparound, the
// overrun/geometry drops, and a concurrent producer/consumer stress that must lose nothing while the ring
// never overruns.
struct AudioSampleRingTests {
    // Fills channel c with the value `base + c` across all frames, so the consumer can verify both the
    // per-channel routing and that the exact frame count round-tripped.
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
        #expect(ring.isEmpty)
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
        #expect(!push(ring, base: 3, channels: 1, frames: 1, host: 3))  // full
        #expect(ring.droppedCount == 1)
        // Draining one frees a slot for the next write.
        #expect(ring.read { _, _ in })
        #expect(push(ring, base: 4, channels: 1, frames: 1, host: 4))
        #expect(ring.droppedCount == 1)
    }

    @Test func geometryExceedingBuffersAreDroppedNotStored() {
        let ring = AudioSampleRing(slotCount: 4, maxFramesPerSlot: 4, maxChannels: 2)
        #expect(!push(ring, base: 1, channels: 1, frames: 5, host: 1))   // too many frames
        #expect(!push(ring, base: 1, channels: 3, frames: 2, host: 1))   // too many channels
        #expect(!push(ring, base: 1, channels: 1, frames: 0, host: 1))   // empty buffer
        #expect(ring.droppedCount == 3)
        #expect(ring.isEmpty)
    }

    @Test func wraparoundReusesSlotsCorrectly() {
        let ring = AudioSampleRing(slotCount: 3, maxFramesPerSlot: 2, maxChannels: 1)
        // Cycle well past slotCount so the monotonic indices wrap the physical slots many times.
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
        #expect(ring.isEmpty)
        #expect(ring.droppedCount == 0)
    }

    @Test func concurrentProducerConsumerLosesNothing() async {
        // The producer emits a strictly increasing host time per buffer and RETRIES the same index whenever
        // the ring is momentarily full (the consumer runs at a lower priority and lags), so nothing is lost:
        // the consumer must observe exactly that sequence with no gaps, duplicates, or reorderings — the SPSC
        // invariant under real thread races. (A transient-full retry legitimately bumps droppedCount, which
        // is why loss is proven by the observed sequence, not by the drop count — in production the RT
        // producer does not retry and a full ring IS a real drop.)
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
