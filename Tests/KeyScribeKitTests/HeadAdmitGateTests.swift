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
        var gate = HeadAdmitGate(admitAfterHostTime: base + ms(40), hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .drop)
    }

    @Test func trimsAStraddlingSlotToTheSample() {
        var gate = HeadAdmitGate(admitAfterHostTime: base + ms(10), hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .admitTrailing(dropFrames: 160))
    }

    @Test func onceAdmittedAllLaterSlotsPassEvenIfEarlierInHostTime() {
        var gate = HeadAdmitGate(admitAfterHostTime: base, hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base + ms(10), frameCount: 480, sampleRate: 16000) == .admit)
        #expect(gate.observe(slotStartHostTime: base - ms(1), frameCount: 480, sampleRate: 16000) == .admit)
    }

    @Test func dropDoesNotLatchAdmissionSoTheNextSlotStillGates() {
        let boundary = base + ms(40)
        var gate = HeadAdmitGate(admitAfterHostTime: boundary, hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .drop)
        let s2 = base + slotTicks(frames: 480, sampleRate: 16000)  // base+30ms
        #expect(gate.observe(slotStartHostTime: s2, frameCount: 480, sampleRate: 16000) == .admitTrailing(dropFrames: 160))
    }

    @Test func invalidTimestampsDropUpToTheSlotBackstopThenAdmitUnconditionally() {
        var gate = HeadAdmitGate(admitAfterHostTime: base, hostTicksPerSecond: ticksPerSecond, maxInvalidSlotsBeforeAdmit: 3)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .drop)
        #expect(gate.observe(slotStartHostTime: 0, frameCount: 480, sampleRate: 16000) == .drop)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .admit)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .admit)
    }

    @Test func invalidTimestampsDropAboutTheCueWindowBeforeAdmitting() {
        var gate = HeadAdmitGate(
            admitAfterHostTime: base, hostTicksPerSecond: ticksPerSecond, fallbackDropSeconds: 0.1)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .drop)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .drop)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .drop)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .admit)
    }

    @Test func aShortCueWindowAdmitsInvalidTimestampsAlmostImmediately() {
        var gate = HeadAdmitGate(
            admitAfterHostTime: base, hostTicksPerSecond: ticksPerSecond, fallbackDropSeconds: 0.01)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 480, sampleRate: 16000) == .admit)
    }

    @Test func unmeasurableInvalidSlotsCannotAccumulateDurationSoTheSlotBackstopGuaranteesAdmission() {
        var gate = HeadAdmitGate(
            admitAfterHostTime: base, hostTicksPerSecond: ticksPerSecond,
            fallbackDropSeconds: 10, maxInvalidSlotsBeforeAdmit: 2)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 0, sampleRate: 0) == .drop)
        #expect(gate.observe(slotStartHostTime: nil, frameCount: 0, sampleRate: 0) == .admit)
    }

    @Test func aFractionalBoundaryRoundsTheDroppedFrameCountUp() {
        let boundary = base + UInt64(160.4 / 16000 * ticksPerSecond)
        var gate = HeadAdmitGate(admitAfterHostTime: boundary, hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .admitTrailing(dropFrames: 161))
    }

    @Test func aSlotEndingExactlyOnTheBoundaryDrops() {
        let boundary = base + slotTicks(frames: 480, sampleRate: 16000)
        var gate = HeadAdmitGate(admitAfterHostTime: boundary, hostTicksPerSecond: ticksPerSecond)
        #expect(gate.observe(slotStartHostTime: base, frameCount: 480, sampleRate: 16000) == .drop)
    }
}
