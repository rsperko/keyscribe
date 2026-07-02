import Foundation
import Testing
@testable import KeyScribeKit

// The capture self-test's scorer must turn an inaudible capture glitch (a dropped/duplicated ring slot) into
// a measurable number. These drive it with a synthetic clean tone, a deliberately glitched tone, noise, and
// silence — proving the sine-recurrence residual separates "clean" from "corrupted" without a reference.
struct CaptureProbeScoringTests {
    private func sine(hz: Double, rate: Double, count: Int, amp: Float = 0.5) -> [Float] {
        (0..<count).map { amp * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    @Test func cleanToneHasHighSinadAndNoGlitches() {
        let m = CaptureProbeScoring.score(samples: sine(hz: 440, rate: 16_000, count: 16_000),
                                          toneHz: 440, sampleRate: 16_000)
        #expect(m.sinadDB > 80)          // a clean sine drives the residual to the numeric floor
        #expect(m.glitchCount == 0)
        #expect(m.maxGlitchRatio < 0.01)
        #expect(m.rms > 0.3 && m.rms < 0.4)  // 0.5 amplitude ⇒ ~0.354 RMS
    }

    @Test func aDroppedSampleShowsAsAGlitchSpikeAndLowersSinad() {
        var s = sine(hz: 440, rate: 16_000, count: 16_000)
        s.remove(at: 8_000)  // splice out one sample mid-stream — the phase jump a dropped ring slot causes
        let m = CaptureProbeScoring.score(samples: s, toneHz: 440, sampleRate: 16_000)
        #expect(m.glitchCount >= 1)
        #expect(m.maxGlitchRatio > 0.1)
        #expect(m.sinadDB < 80)          // markedly worse than the clean case
    }

    @Test func azeroedBufferGapIsCaught() {
        var s = sine(hz: 440, rate: 16_000, count: 16_000)
        for i in 8_000..<8_256 { s[i] = 0 }  // a dropped-buffer gap (256 zeroed samples)
        let m = CaptureProbeScoring.score(samples: s, toneHz: 440, sampleRate: 16_000)
        #expect(m.glitchCount >= 1)
        #expect(m.sinadDB < 60)
    }

    @Test func silenceReportsZeroLevelAndNoGlitches() {
        let m = CaptureProbeScoring.score(samples: [Float](repeating: 0, count: 8_000),
                                          toneHz: 440, sampleRate: 16_000)
        #expect(m.rms == 0)
        #expect(m.peak == 0)
        #expect(m.glitchCount == 0)      // no peak ⇒ nothing crosses the relative threshold
    }

    @Test func emptyInputIsHandled() {
        let m = CaptureProbeScoring.score(samples: [], toneHz: 440, sampleRate: 16_000)
        #expect(m.sampleCount == 0)
        #expect(m.rms == 0)
    }
}
