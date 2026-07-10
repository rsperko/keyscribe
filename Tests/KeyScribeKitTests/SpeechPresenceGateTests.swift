import Testing
@testable import KeyScribeKit

struct SpeechPresenceGateTests {
    @Test func silenceIsNoSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.0, 0.0, 0.02, 0.0], peak: 0.01)
        #expect(v == .noSpeech)
    }

    @Test func oneHotChunkAnywhereIsSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.0, 0.02, 0.91, 0.05], peak: 0.4)
        #expect(v == .speech)
    }

    @Test func allMarginalBelowThresholdIsNoSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.29, 0.29, 0.29], peak: 0.4)
        #expect(v == .noSpeech)
    }

    @Test func boundaryAtThresholdIsSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.30], peak: 0.4)
        #expect(v == .speech)
    }

    @Test func emptyProbabilitiesFailOpenToSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [], peak: 0.5)
        #expect(v == .speech)
    }

    @Test func digitalSilencePeakIsNoSpeechEvenWithHotChunks() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [0.99], peak: 0.00001)
        #expect(v == .noSpeech)
    }

    @Test func digitalSilencePeakWithEmptyProbabilitiesIsNoSpeech() {
        let v = SpeechPresenceGate.evaluate(chunkProbabilities: [], peak: 0.00001)
        #expect(v == .noSpeech)
    }
}
