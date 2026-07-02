import Synchronization

// Lock-free single-producer / single-consumer ring of audio buffer records. The realtime CoreAudio IO
// thread is the sole PRODUCER (copies each delivered buffer's planar Float samples into the next slot); a
// dedicated writer thread is the sole CONSUMER (drains slots to disk). Neither side takes a lock, allocates,
// or makes a syscall on its hot path, so the RT thread can never stall on the writer (the priority
// inversion that overran the device IO cycle in the old per-buffer-lock/file-write callback).
//
// Each slot carries the frames plus the metadata the writer needs: the delivered frame/channel count, the
// device-native sample rate (so the writer builds/rebuilds its resampler), and the buffer's mach host time
// (so the tail-drain gate can decide when the release-covering buffer has reached the writer). Slots are a
// fixed, preallocated geometry; a buffer that exceeds it, or that arrives when the ring is full, is dropped
// and counted (an overrun) rather than blocking the RT thread.
//
// Correctness rests on the classic SPSC discipline: the producer publishes a slot by a RELEASING store to
// `tail` after filling it, and the consumer reads a slot only after an ACQUIRING load of `tail` — the
// acquire/release pair makes every prior producer write (samples + metadata) visible before the consumer
// reads them. `head`/`tail` are monotonic counters (never wrap in any realistic lifetime), so full is
// `tail - head == slotCount` and empty is `tail == head`; the producer never laps the consumer.
public final class AudioSampleRing: @unchecked Sendable {
    public struct SlotInfo: Sendable, Equatable {
        public let frameCount: Int
        public let channelCount: Int
        public let sampleRate: Double
        public let hostTime: UInt64
    }

    public let slotCount: Int
    public let maxFramesPerSlot: Int
    public let maxChannels: Int

    // Interleaved-by-slot planar storage: slot s, channel c, frame f lives at
    // ((s * maxChannels + c) * maxFramesPerSlot + f). Raw (not a Swift Array) so distinct-slot producer and
    // consumer access can never touch the Array's shared COW/refcount header from two threads.
    private let storage: UnsafeMutableBufferPointer<Float>
    private let frameCounts: UnsafeMutableBufferPointer<Int>
    private let channelCounts: UnsafeMutableBufferPointer<Int>
    private let sampleRates: UnsafeMutableBufferPointer<Double>
    private let hostTimes: UnsafeMutableBufferPointer<UInt64>

    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let overruns = Atomic<Int>(0)

    public init(slotCount: Int, maxFramesPerSlot: Int, maxChannels: Int) {
        precondition(slotCount >= 2 && maxFramesPerSlot >= 1 && maxChannels >= 1)
        self.slotCount = slotCount
        self.maxFramesPerSlot = maxFramesPerSlot
        self.maxChannels = maxChannels
        storage = .allocate(capacity: slotCount * maxChannels * maxFramesPerSlot)
        storage.initialize(repeating: 0)
        frameCounts = .allocate(capacity: slotCount); frameCounts.initialize(repeating: 0)
        channelCounts = .allocate(capacity: slotCount); channelCounts.initialize(repeating: 0)
        sampleRates = .allocate(capacity: slotCount); sampleRates.initialize(repeating: 0)
        hostTimes = .allocate(capacity: slotCount); hostTimes.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
        frameCounts.deallocate()
        channelCounts.deallocate()
        sampleRates.deallocate()
        hostTimes.deallocate()
    }

    private func slotBase(_ slot: Int, _ channel: Int) -> Int {
        (slot * maxChannels + channel) * maxFramesPerSlot
    }

    // PRODUCER (realtime thread). Copies one delivered buffer into the next free slot via `fill`, which is
    // handed a per-channel destination of exactly `frameCount` Float samples. Returns false (and increments
    // the overrun count) when the buffer exceeds the fixed geometry or the ring is full — the RT thread
    // drops the buffer instead of ever blocking. Allocation-free and lock-free.
    @discardableResult
    public func write(
        channelCount: Int, frameCount: Int, sampleRate: Double, hostTime: UInt64,
        fill: (_ channel: Int, _ dest: UnsafeMutableBufferPointer<Float>) -> Void
    ) -> Bool {
        guard frameCount > 0, frameCount <= maxFramesPerSlot,
              channelCount > 0, channelCount <= maxChannels else {
            overruns.add(1, ordering: .relaxed); return false
        }
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t - h < slotCount else { overruns.add(1, ordering: .relaxed); return false }
        let slot = t % slotCount
        for c in 0..<channelCount {
            let base = storage.baseAddress! + slotBase(slot, c)
            fill(c, UnsafeMutableBufferPointer(start: base, count: frameCount))
        }
        frameCounts[slot] = frameCount
        channelCounts[slot] = channelCount
        sampleRates[slot] = sampleRate
        hostTimes[slot] = hostTime
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    // CONSUMER (writer thread). If a published slot is available, invokes `body` with its metadata and a
    // per-channel sample accessor (valid only for the duration of the call), then advances past it. Returns
    // false when the ring is empty. The slot's storage is stable during `body` because the producer's
    // full-check guarantees it will not overwrite an unread slot.
    @discardableResult
    public func read(
        _ body: (SlotInfo, _ channel: (Int) -> UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h != t else { return false }
        let slot = h % slotCount
        let info = SlotInfo(
            frameCount: frameCounts[slot], channelCount: channelCounts[slot],
            sampleRate: sampleRates[slot], hostTime: hostTimes[slot])
        let frames = info.frameCount
        body(info) { channel in
            let base = self.storage.baseAddress! + self.slotBase(slot, channel)
            return UnsafeBufferPointer(start: base, count: frames)
        }
        head.store(h + 1, ordering: .releasing)
        return true
    }

    public var isEmpty: Bool { head.load(ordering: .acquiring) == tail.load(ordering: .acquiring) }
    public var droppedCount: Int { overruns.load(ordering: .relaxed) }

    // Return the ring to its empty state. ONLY call when quiescent (no producer or consumer running) —
    // between captures, after the previous writer has joined and before the next unit starts.
    public func reset() {
        head.store(0, ordering: .relaxed)
        tail.store(0, ordering: .relaxed)
        overruns.store(0, ordering: .relaxed)
    }
}
