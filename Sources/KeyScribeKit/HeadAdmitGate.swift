// Discards capture buffers delivered before an admission boundary — the mirror of TailDrainGate. Keeps a
// start cue out of the recording while the mic is brought up under it. Pure/OS-free: the caller supplies
// the host-clock rate so the gate needs no mach timebase (0 host time is the invalid-timestamp sentinel).
public struct HeadAdmitGate: Sendable {
    public enum Outcome: Equatable, Sendable {
        case drop                            // entirely before the boundary
        case admit                           // entirely at/after the boundary
        case admitTrailing(dropFrames: Int)  // straddles: drop the first `dropFrames`, admit the rest
    }

    private let admitAfterHostTime: UInt64
    private let hostTicksPerSecond: Double
    // Approximate cue-window duration for the invalid-timestamp fallback. When finite, the fallback drops
    // until the dropped audio reaches it (measured from each slot's own frames/rate). `.infinity` (the
    // default) means no cue window was supplied, so the fallback uses only the bounded slot count.
    private let fallbackDropSeconds: Double
    private let maxInvalidSlotsBeforeAdmit: Int
    private var invalidSlotsSeen = 0
    private var invalidSecondsSeen = 0.0
    private var admitted = false  // latched on first admit; monotonic host time makes this a fast path too

    public init(admitAfterHostTime: UInt64, hostTicksPerSecond: Double,
                fallbackDropSeconds: Double = .infinity, maxInvalidSlotsBeforeAdmit: Int = 8) {
        self.admitAfterHostTime = admitAfterHostTime
        self.hostTicksPerSecond = hostTicksPerSecond
        self.fallbackDropSeconds = fallbackDropSeconds
        self.maxInvalidSlotsBeforeAdmit = max(1, maxInvalidSlotsBeforeAdmit)
    }

    public mutating func observe(slotStartHostTime: UInt64?, frameCount: Int, sampleRate: Double) -> Outcome {
        if admitted { return .admit }
        // Unplaceable timestamp. With a finite cue window supplied, keep dropping until the dropped audio
        // approximates it — measured from each slot's own frame count, since a device that never stamps
        // hostTime still reports its rate — so a measurable slot never counts toward the slot backstop and
        // thus can't preempt the duration budget. With no window supplied (the public default), fall back to
        // the historical bounded slot count. Either way an absolute slot backstop guarantees admission for
        // slots whose frames/rate are also unreadable, so the gate can never eat audio forever.
        guard let start = slotStartHostTime, start != 0, sampleRate > 0, frameCount > 0,
              hostTicksPerSecond > 0 else {
            if sampleRate > 0, frameCount > 0, fallbackDropSeconds.isFinite {
                invalidSecondsSeen += Double(frameCount) / sampleRate
                if invalidSecondsSeen >= fallbackDropSeconds { admitted = true; return .admit }
                return .drop
            }
            invalidSlotsSeen += 1
            if invalidSlotsSeen >= maxInvalidSlotsBeforeAdmit { admitted = true; return .admit }
            return .drop
        }
        if start >= admitAfterHostTime { admitted = true; return .admit }
        let slotTicks = UInt64((Double(frameCount) / sampleRate * hostTicksPerSecond).rounded())
        if start &+ slotTicks <= admitAfterHostTime { return .drop }
        // Straddles: trim leading frames, rounding the dropped count UP so a between-sample boundary never
        // admits a partial pre-boundary sample.
        let leadSeconds = Double(admitAfterHostTime - start) / hostTicksPerSecond
        let dropFrames = Int((leadSeconds * sampleRate).rounded(.up))
        if dropFrames <= 0 { admitted = true; return .admit }
        if dropFrames >= frameCount { return .drop }
        admitted = true
        return .admitTrailing(dropFrames: dropFrames)
    }
}
