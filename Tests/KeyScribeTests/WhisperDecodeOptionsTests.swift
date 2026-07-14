import Testing
import WhisperKit
@testable import KeyScribe

// WhisperKit's default DecodingOptions carry firstTokenLogProbThreshold = -1.5: a first predicted
// token below it EARLY-STOPS the window with zero word tokens, and the temperature fallbacks that
// follow sample randomly — so a short real-speech clip (fast speech, cue-trimmed onset) can come back
// "" and surface as a false "No speech detected". These pin that the engine builds its options with
// that gate off, on both the biased and unbiased paths.
struct WhisperDecodeOptionsTests {
    @Test func unbiasedOptionsDisableFirstTokenEarlyStop() {
        let options = WhisperEngine.batchDecodingOptions(promptTokens: nil)
        #expect(options.firstTokenLogProbThreshold == nil)
        #expect(options.promptTokens == nil)
    }

    @Test func biasedOptionsCarryPromptTokensAndDisableFirstTokenEarlyStop() {
        let options = WhisperEngine.batchDecodingOptions(promptTokens: [11, 22, 33])
        #expect(options.promptTokens == [11, 22, 33])
        #expect(options.firstTokenLogProbThreshold == nil)
    }
}

// WhisperKit's seek loop runs only while `seek < clipEnd - windowClipTime×16000`, so a clip shorter
// than windowClipTime (default 1 s) gets ZERO decode windows — "" for real speech, deterministically
// (a 0.92 s clip reproduced it every run). The engine pads short audio past that guard with trailing
// zeros, indistinguishable from the zero-fill WhisperKit itself applies to reach the 30 s window.
struct WhisperShortAudioPaddingTests {
    @Test func subSecondClipIsPaddedPastTheSeekGuard() {
        let short = [Float](repeating: 0.1, count: 8000)
        let padded = WhisperEngine.paddedForDecode(short, windowClipTime: 1.0)
        #expect(padded.count == 16001)
        #expect(Array(padded[0..<8000]) == short)
        #expect(padded[8000...].allSatisfy { $0 == 0 })
    }

    @Test func exactBoundaryClipGainsOneFrame() {
        let boundary = [Float](repeating: 0.1, count: 16000)
        #expect(WhisperEngine.paddedForDecode(boundary, windowClipTime: 1.0).count == 16001)
    }

    @Test func longerClipIsUntouched() {
        let long = [Float](repeating: 0.1, count: 32000)
        #expect(WhisperEngine.paddedForDecode(long, windowClipTime: 1.0) == long)
    }
}
