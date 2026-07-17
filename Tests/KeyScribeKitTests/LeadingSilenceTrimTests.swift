import Foundation
import Testing

@testable import KeyScribeKit

struct LeadingSilenceTrimTests {
    @Test func trimsToOneChunkOfPreRollBeforeTheSpeechStart() {
        let samples = [Float](repeating: 0, count: 16000)
        let trimmed = LeadingSilenceTrim.trimming(samples: samples, sampleRate: 16000, speechStart: 0.512)
        // 0.512 − 0.256 = 0.256 s → 4,096 samples removed.
        #expect(trimmed.count == 16000 - 4096)
    }

    @Test func keepsTheTakeWholeWhenThePreRollReachesBackPastTheStart() {
        let samples = [Float](repeating: 0, count: 16000)
        let trimmed = LeadingSilenceTrim.trimming(samples: samples, sampleRate: 16000, speechStart: 0.256)
        #expect(trimmed.count == samples.count)
    }

    @Test func convertsTheBoundaryAtTheEnginesCaptureRate() {
        let samples = [Float](repeating: 0, count: 24000)
        let trimmed = LeadingSilenceTrim.trimming(samples: samples, sampleRate: 24000, speechStart: 0.512)
        // 0.256 s at 24 kHz is 6,144 samples — not the VAD's 4,096.
        #expect(trimmed.count == 24000 - 6144)
    }

    @Test func preservesTheSamplesFromTheBoundaryOnward() {
        var samples = [Float](repeating: 0, count: 16000)
        samples[4096] = 0.5
        samples[15999] = 0.25
        let trimmed = LeadingSilenceTrim.trimming(samples: samples, sampleRate: 16000, speechStart: 0.512)
        #expect(trimmed.first == 0.5)
        #expect(trimmed.last == 0.25)
    }

    @Test func neverSlicesPastTheEndOfAShortTake() {
        let samples = [Float](repeating: 0, count: 800)
        let trimmed = LeadingSilenceTrim.trimming(samples: samples, sampleRate: 16000, speechStart: 5)
        #expect(trimmed.isEmpty)
    }
}

struct SpeechStartTests {
    @Test func reportsTheStartOfTheFirstChunkAtOrAboveTheGate() {
        #expect(SpeechPresenceGate.speechStart(chunkProbabilities: [0.2, 0.1, 1.0]) == 0.512)
        #expect(SpeechPresenceGate.speechStart(chunkProbabilities: [0.1, 0.30]) == 0.256)
    }

    @Test func speechInChunkZeroProvesNoLeadingSilence() {
        #expect(SpeechPresenceGate.speechStart(chunkProbabilities: [0.9, 0.1]) == nil)
    }

    @Test func noQualifyingChunkHasNoSpeechStart() {
        #expect(SpeechPresenceGate.speechStart(chunkProbabilities: [0.1, 0.2]) == nil)
        #expect(SpeechPresenceGate.speechStart(chunkProbabilities: []) == nil)
    }

    @Test func chunkTimingMatchesTheGateChunkGeometry() {
        #expect(SpeechPresenceGate.chunkSeconds == 0.256)
        #expect(SpeechPresenceGate.chunkSamples == 4096)
        #expect(SpeechPresenceGate.chunkSampleRate == 16000)
    }
}
