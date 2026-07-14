import Testing
@testable import KeyScribeKit

struct StreamingStartPolicyTests {
    @Test func thresholdSecondsConvertToFramesAtEngineRate() {
        #expect(StreamingStartPolicy(thresholdSeconds: 5, sampleRate: 16000).thresholdFrames == 80000)
        #expect(StreamingStartPolicy(thresholdSeconds: 3, sampleRate: 24000).thresholdFrames == 72000)
    }

    @Test func sessionStartsExactlyAtTheThresholdNotBefore() {
        let policy = StreamingStartPolicy(thresholdSeconds: 5, sampleRate: 16000)
        #expect(!policy.shouldStartSession(accumulatedFrames: 79999))
        #expect(policy.shouldStartSession(accumulatedFrames: 80000))
        #expect(policy.shouldStartSession(accumulatedFrames: 80001))
    }

    // Below the floor is clamped up to it: the deferred start must stay above press-time prepare/prewarm
    // so a session never opens while those hold the engine lock — a 0 (or negative) threshold can't defeat it.
    @Test func belowFloorThresholdClampsToFloor() {
        let floor = StreamingStartPolicy.minimumThresholdSeconds
        for requested in [-2.0, 0, 0.5, floor - 0.1] {
            let policy = StreamingStartPolicy(thresholdSeconds: requested, sampleRate: 16000)
            #expect(policy.thresholdSeconds == floor)
            #expect(!policy.shouldStartSession(accumulatedFrames: 0))
            #expect(policy.shouldStartSession(accumulatedFrames: Int(floor * 16000)))
        }
    }

    @Test func atOrAboveFloorIsHonored() {
        #expect(StreamingStartPolicy(thresholdSeconds: 4, sampleRate: 16000).thresholdSeconds == 4)
        #expect(StreamingStartPolicy(thresholdSeconds: StreamingStartPolicy.minimumThresholdSeconds,
                                     sampleRate: 16000).thresholdSeconds == StreamingStartPolicy.minimumThresholdSeconds)
    }

    // A non-positive sample rate can never cross, so a session never opens (defensive: batch always runs).
    @Test func nonPositiveSampleRateNeverStarts() {
        let policy = StreamingStartPolicy(thresholdSeconds: 5, sampleRate: 0)
        #expect(policy.thresholdFrames == Int.max)
        #expect(!policy.shouldStartSession(accumulatedFrames: 1_000_000))
    }
}
