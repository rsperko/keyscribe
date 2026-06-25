import Testing
@testable import KeyScribeKit

struct TailDrainGateTests {
    @Test func stopsWhenABufferStartsAtOrAfterRelease() {
        var gate = TailDrainGate(releaseHostTime: 1000)
        #expect(gate.observe(bufferStartHostTime: 1000) == .stop)
    }

    @Test func stopsWhenABufferStartsPastRelease() {
        var gate = TailDrainGate(releaseHostTime: 1000)
        #expect(gate.observe(bufferStartHostTime: 1500) == .stop)
    }

    @Test func keepsDrainingWhileBuffersPredateRelease() {
        var gate = TailDrainGate(releaseHostTime: 1000)
        #expect(gate.observe(bufferStartHostTime: 200) == .keepDraining)
        #expect(gate.observe(bufferStartHostTime: 800) == .keepDraining)
        #expect(gate.observe(bufferStartHostTime: 1001) == .stop)
    }

    @Test func fallsBackToBufferCountWhenTimestampsAreInvalid() {
        var gate = TailDrainGate(releaseHostTime: 1000, maxBuffersBeforeStop: 3)
        #expect(gate.observe(bufferStartHostTime: nil) == .keepDraining)
        #expect(gate.observe(bufferStartHostTime: nil) == .keepDraining)
        #expect(gate.observe(bufferStartHostTime: nil) == .stop)
    }

    @Test func aValidCrossingStopsBeforeTheCountCapIsReached() {
        var gate = TailDrainGate(releaseHostTime: 1000, maxBuffersBeforeStop: 10)
        #expect(gate.observe(bufferStartHostTime: nil) == .keepDraining)
        #expect(gate.observe(bufferStartHostTime: 2000) == .stop)
    }

    @Test func countCapBoundsAStuckClockThatNeverCrossesRelease() {
        var gate = TailDrainGate(releaseHostTime: .max, maxBuffersBeforeStop: 2)
        #expect(gate.observe(bufferStartHostTime: 5) == .keepDraining)
        #expect(gate.observe(bufferStartHostTime: 6) == .stop)
    }
}
