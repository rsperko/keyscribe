import Testing
@testable import KeyScribeKit

struct HeadAdmitGateTests {
    // 1 tick == 1 ns keeps the arithmetic legible: a 480-frame slot @16 kHz spans 30 ms == 30_000_000 ticks.
    // `base` is a nonzero reference because 0 is the invalid-timestamp sentinel (the writer maps a
    // hostTime of 0 to nil before the gate ever sees it).
    private let ticksPerSecond: Double = 1_000_000_000
    private let base: UInt64 = 1_000_000_000
    private func ms(_ milliseconds: Double) -> UInt64 { UInt64(milliseconds / 1000 * ticksPerSecond) }
    private func slotTicks(frames: Int, sampleRate: Double) -> UInt64 {
        UInt64((Double(frames) / sampleRate * ticksPerSecond).rounded())
    }

    @Test func admitsAWholeSlotStartingAtOrAfterTheBoundary() {
        var gate = HeadAdmitGate(admitAfterHostTime: base, hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .admit)
        #expect(gate.observe(slotStartHostTime: base + ms(10), frameCount: 480, sampleRate: 16000) == .admit)
    }

    @Test func dropsAWholeSlotEndingBeforeTheBoundary() {
        // Slot [base, base+30ms); boundary at base+40ms → entirely before.
        var gate = HeadAdmitGate(admitAfterHostTime: base + ms(40), hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .drop)
    }

    @Test func trimsAStraddlingSlotToTheSample() {
        // Slot [base, base+30ms) @16kHz (480 frames); boundary at base+10ms → drop first 160, admit 320.
        var gate = HeadAdmitGate(admitAfterHostTime: base + ms(10), hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .admitTrailing(dropFrames: 160))
    }

    @Test func onceAdmittedAllLaterSlotsPassEvenIfEarlierInHostTime() {
        var gate = HeadAdmitGate(admitAfterHostTime: base, hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base + ms(10), frameCount: 480, sampleRate: 16000) == .admit)
        // A jittered/earlier timestamp after admission must not re-gate.
        #expect(gate.observe(slotStartHostTime: base - ms(1), frameCount: 480, sampleRate: 16000) == .admit)
    }

    @Test func dropDoesNotLatchAdmissionSoTheNextSlotStillGates() {
        let boundary = base + ms(40)
        var gate = HeadAdmitGate(admitAfterHostTime: boundary, hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .drop)
        // Next slot [base+30ms, base+60ms) straddles the base+40ms boundary → trims, not blanket-admits.
        let s2 = base + slotTicks(frames: 480, sampleRate: 16000)  // base+30ms
        #expect(gate.observe(slotStartHostTime: s2, frameCount: 480, sampleRate: 16000) == .admitTrailing(dropFrames: 160))
    }

    @Test func invalidTimestampsDropUpToTheFallbackThenAdmitUnconditionally() {
        var gate = HeadAdmitGate(admitAfterHostTime: base, hostTicksPerSecond: ticksPerSecond, maxInvalidSlotsBeforeAdmit: 3)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .drop)
        #expect(gate.observe(slotStartHostTime: 0, frameCount: 480, sampleRate: 16000) == .drop)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .admit)
        // Latched: further slots admit regardless.
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .admit)
    }

    @Test func aFractionalBoundaryRoundsTheDroppedFrameCountUp() {
        // Boundary 160.4 frames into the slot @16kHz: strict "admit at/after" drops 161, not 160.
        let boundary = base + UInt64(160.4 / 16000 * ticksPerSecond)
        var gate = HeadAdmitGate(admitAfterHostTime: boundary, hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .admitTrailing(dropFrames: 161))
    }

    @Test func aSlotEndingExactlyOnTheBoundaryDrops() {
        // Slot [base, base+30ms); boundary at exactly base+30ms → nothing at/after the boundary.
        let boundary = base + slotTicks(frames: 480, sampleRate: 16000)
        var gate = HeadAdmitGate(admitAfterHostTime: boundary, hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .drop)
    }
}
