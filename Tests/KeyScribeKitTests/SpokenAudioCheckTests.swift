import Foundation
import Testing
@testable import KeyScribeKit

struct SpokenAudioCheckTests {
    private func tone(seconds: Double, rate: Int = 24000, level: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { level * sin(Float($0) * 0.05) }
    }

    @Test func ordinarySpeechLevelAudioHasNoProblem() {
        #expect(SpokenAudioCheck.problem(in: tone(seconds: 1)) == nil)
    }

    @Test func emptyAudioIsRejected() {
        #expect(SpokenAudioCheck.problem(in: []) == .empty)
    }

    @Test func aSingleInvalidSampleRejectsTheAudio() {
        var samples = tone(seconds: 1)
        samples[100] = .nan
        #expect(SpokenAudioCheck.problem(in: samples) == .invalidSamples)
        samples[100] = .infinity
        #expect(SpokenAudioCheck.problem(in: samples) == .invalidSamples)
    }

    @Test func audioTooQuietToHearIsRejected() {
        #expect(SpokenAudioCheck.problem(in: tone(seconds: 1, level: 0.005)) == .silent)
        #expect(SpokenAudioCheck.problem(in: [Float](repeating: 0, count: 24000)) == .silent)
    }

    @Test func clippingIsMeasuredButNotRejected() {
        var samples = tone(seconds: 1)
        for i in 0..<240 { samples[i] = 1 }
        #expect(SpokenAudioCheck.problem(in: samples) == nil)
        let measured = SpokenAudioCheck.measure(samples, sampleRate: 24000)
        #expect(measured.clippedSamples == 240)
        #expect(measured.peak == 1)
        #expect(abs(measured.seconds - 1) < 0.001)
    }

    @Test func similarityIsOneForTheSameTakeAndLowForUnrelatedAudio() {
        let take = tone(seconds: 1)
        #expect(abs(SpokenAudioCheck.similarity(take, take) - 1) < 0.0001)
        let other = (0..<24000).map { 0.3 * sin(Float($0) * 0.31) }
        #expect(SpokenAudioCheck.similarity(take, other) < 0.2)
        #expect(SpokenAudioCheck.similarity([], take) == 0)
    }
}
