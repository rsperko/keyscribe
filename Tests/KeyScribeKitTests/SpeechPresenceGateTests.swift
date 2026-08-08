import Testing
@testable import KeyScribeKit

struct SpeechPresenceGateTests {
    @Test func silenceIsNoSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.0, 0.0, 0.02, 0.0], peak: 0.01)
        #expect(v == .noSpeech)
    }

    @Test func oneConfidentChunkIsNotEnough() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.0, 0.02, 0.91, 0.05], peak: 0.4)
        #expect(v == .noSpeech)
    }

    @Test func twoClearingChunksAreSpeechEvenWhenMarginal() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.30, 0.31, 0.02], peak: 0.4)
        #expect(v == .speech)
    }

    @Test func clearingChunksNeedNotBeConsecutive() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.9, 0.02, 0.9], peak: 0.4)
        #expect(v == .speech)
    }

    @Test func allMarginalBelowThresholdIsNoSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.29, 0.29, 0.29], peak: 0.4)
        #expect(v == .noSpeech)
    }

    @Test func boundaryAtThresholdCountsTowardTheMinimum() {
        #expect(SpeechPresenceGate.evaluate(chunkProbabilities: [0.30], peak: 0.4) == .noSpeech)
        #expect(SpeechPresenceGate.evaluate(chunkProbabilities: [0.30, 0.30], peak: 0.4) == .speech)
    }

    @Test func emptyProbabilitiesFromARealModelRunAreNoSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [], peak: 0.5)
        #expect(v == .noSpeech)
    }

    @Test func digitalSilencePeakIsNoSpeechEvenWithHotChunks() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.99], peak: 0.00001)
        #expect(v == .noSpeech)
    }

    @Test func digitalSilencePeakWithEmptyProbabilitiesIsNoSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [], peak: 0.00001)
        #expect(v == .noSpeech)
    }

    @Test func countsEveryChunkClearingTheThreshold() {
        #expect(SpeechPresenceGate.chunksClearingGate([0.29, 0.30, 0.05, 1.0]) == 2)
        #expect(SpeechPresenceGate.chunksClearingGate([0.29, 0.29]) == 0)
        #expect(SpeechPresenceGate.chunksClearingGate([]) == 0)
    }

    @Test(arguments: [
        [0.56] as [Float],
        [0.50, 0.08],
        [0.42, 0.05],
        [0.51, 0.15],
        [0.92, 0.29],
        [0.62, 0.20],
        [0.77],
    ])
    func measuredEmptyPressesAreSuppressed(chunkProbabilities: [Float]) {
        #expect(SpeechPresenceGate.evaluate(chunkProbabilities: chunkProbabilities, peak: 0.4) == .noSpeech)
    }

    @Test(arguments: [
        [1.0, 1.0] as [Float],
        [0.83, 1.0, 1.0, 0.88],
        [0.85, 0.99, 1.0, 0.51],
        [0.64, 1.0, 1.0],
        [0.86, 0.54, 1.0, 1.0, 0.43],
    ])
    func measuredShortUtterancesAreAdmitted(chunkProbabilities: [Float]) {
        #expect(SpeechPresenceGate.evaluate(chunkProbabilities: chunkProbabilities, peak: 0.4) == .speech)
    }

    @Test func longestRunMeasuresConsecutiveClearingChunksOnly() {
        #expect(SpeechPresenceGate.longestRunClearingGate([1.0, 1.0, 0.02, 1.0]) == 2)
        #expect(SpeechPresenceGate.longestRunClearingGate([0.02, 1.0, 1.0, 1.0]) == 3)
        #expect(SpeechPresenceGate.longestRunClearingGate([0.29, 0.29]) == 0)
        #expect(SpeechPresenceGate.longestRunClearingGate([]) == 0)
    }
}
