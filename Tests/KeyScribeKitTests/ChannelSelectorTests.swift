import Foundation
import Testing
@testable import KeyScribeKit

struct ChannelSelectorTests {
    private struct Segment {
        let seconds: Double
        let rms: [Float]
    }

    private struct Run {
        var selections: [(seconds: Double, selected: Int)] = []
        var firstSwitchSeconds: Double? {
            guard let first = selections.first?.selected else { return nil }
            return selections.first { $0.selected != first }?.seconds
        }
    }

    // Each sample of a segment carries that segment's RMS, so a buffer straddling a boundary reports the true
    // RMS of the mixed audio it holds — the same thing vDSP_rmsqv over the buffer would report.
    @discardableResult
    private func feed(
        _ selector: inout ChannelSelector, _ segments: [Segment], bufferFrames: Int, sampleRate: Double = 48_000
    ) -> Run {
        let channels = segments[0].rms.count
        var envelope: [[Float]] = Array(repeating: [], count: channels)
        for segment in segments {
            let frames = Int((segment.seconds * sampleRate).rounded())
            for c in 0..<channels { envelope[c].append(contentsOf: repeatElement(segment.rms[c], count: frames)) }
        }
        let total = envelope[0].count
        var run = Run()
        var start = 0
        var rms = [Float](repeating: 0, count: channels)
        while start < total {
            let n = min(bufferFrames, total - start)
            for c in 0..<channels {
                var sumSquares: Float = 0
                for f in start..<(start + n) { sumSquares += envelope[c][f] * envelope[c][f] }
                rms[c] = (sumSquares / Float(n)).squareRoot()
            }
            let selected = rms.withUnsafeBufferPointer { selector.observe(rms: $0, frameCount: n) }
            start += n
            run.selections.append((Double(start) / sampleRate, selected))
        }
        return run
    }

    private func db(_ value: Float) -> Float { pow(10, value / 20) }

    @Test func theFirstBufferPicksTheLoudestChannel() {
        var selector = ChannelSelector(channelCount: 3, sampleRate: 48_000)
        let run = feed(&selector, [Segment(seconds: 0.001, rms: [0.01, 0.2, 0.05])], bufferFrames: 48)
        #expect(run.selections.first?.selected == 1)
        #expect(selector.selected == 1)
    }

    @Test func aChannelLouderByLessThanTheMarginNeverTakesOver() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        feed(&selector, [
            Segment(seconds: 0.05, rms: [0.1, 0.01]),
            Segment(seconds: 2, rms: [0.1, 0.1 * db(5)]),
        ], bufferFrames: 256)
        #expect(selector.selected == 0)
        #expect(selector.switchCount == 0)
    }

    @Test func aLouderBurstShorterThanTheSustainNeverTakesOver() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        feed(&selector, [
            Segment(seconds: 0.1, rms: [0.05, 0.001]),
            Segment(seconds: 0.02, rms: [0.05, 0.5]),
            Segment(seconds: 0.5, rms: [0.05, 0.001]),
        ], bufferFrames: 64)
        #expect(selector.selected == 0)
        #expect(selector.switchCount == 0)
    }

    @Test func aChannelLouderByTheMarginForTheSustainTakesOver() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        feed(&selector, [
            Segment(seconds: 0.1, rms: [0.05, 0.001]),
            Segment(seconds: 0.3, rms: [0.05, 0.5]),
        ], bufferFrames: 64)
        #expect(selector.selected == 1)
        #expect(selector.switchCount == 1)
    }

    @Test func thePreviousChannelsNoiseFloorDuringAPauseDoesNotSwitchBack() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        feed(&selector, [
            Segment(seconds: 0.1, rms: [0.05, 0.001]),
            Segment(seconds: 1, rms: [0.05, 0.3]),
            Segment(seconds: 0.4, rms: [0.01, 0.001]),
        ], bufferFrames: 256)
        #expect(selector.selected == 1)
        #expect(selector.switchCount == 1)
    }

    @Test func hissDuringALongPauseCannotBeatAChannelThatCarriedSpeech() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        let floor1: Float = 0.001
        let hiss0: Float = 0.02
        feed(&selector, [
            Segment(seconds: 0.1, rms: [0.002, floor1]),
            Segment(seconds: 1, rms: [0.002, 0.2]),
            Segment(seconds: 2, rms: [hiss0, floor1]),
            Segment(seconds: 1, rms: [hiss0, 0.2]),
        ], bufferFrames: 256)
        #expect(selector.selected == 1)
        #expect(selector.switchCount == 1)
    }

    @Test func speechTwentyDecibelsOverNoiseIsSelectedWithinTheSustainWindow() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        let noise: Float = 0.01
        let run = feed(&selector, [
            Segment(seconds: 0.1, rms: [noise, 0.0005]),
            Segment(seconds: 0.5, rms: [noise, noise * db(20)]),
        ], bufferFrames: 128)
        #expect(selector.selected == 1)
        let switchedAt = try! #require(run.firstSwitchSeconds)
        #expect(switchedAt > 0.1 + ChannelSelector.defaultSwitchSustainSeconds)
        #expect(switchedAt < 0.1 + ChannelSelector.defaultSwitchSustainSeconds + 0.03)
    }

    @Test func levelsAreSmoothedAndPeaksHoldTheirMaximum() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        feed(&selector, [
            Segment(seconds: 0.5, rms: [0.2, 0.01]),
            Segment(seconds: 0.05, rms: [0.0, 0.01]),
        ], bufferFrames: 256)
        #expect(selector.levels[0] > 0.0 && selector.levels[0] < 0.2)
        #expect(abs(selector.levels[1] - 0.01) < 0.001)
        #expect(abs(selector.peakLevels[0] - 0.2) < 0.005)
        #expect(abs(selector.peakLevels[1] - 0.01) < 0.001)
    }

    @Test func aPinnedChannelIsReturnedFromTheFirstCallAndNeverSwitches() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000, pinned: 1)
        let run = feed(&selector, [
            Segment(seconds: 0.1, rms: [0.5, 0.001]),
            Segment(seconds: 1, rms: [0.5, 0.001]),
        ], bufferFrames: 256)
        #expect(run.selections.allSatisfy { $0.selected == 1 })
        #expect(selector.switchCount == 0)
    }

    @Test func smallAndLargeBuffersConvergeOnTheSameSelectionAndLevels() {
        let segments = [
            Segment(seconds: 0.4, rms: [0.02, 0.002]),
            Segment(seconds: 1.2, rms: [0.02, 0.2]),
        ]
        var small = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        var large = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        let smallRun = feed(&small, segments, bufferFrames: 64)
        let largeRun = feed(&large, segments, bufferFrames: 4096)
        #expect(small.selected == 1 && large.selected == 1)
        let smallAt = try! #require(smallRun.firstSwitchSeconds)
        let largeAt = try! #require(largeRun.firstSwitchSeconds)
        #expect(abs(smallAt - largeAt) <= 4096.0 / 48_000)
        for c in 0..<2 {
            #expect(abs(small.levels[c] - large.levels[c]) / small.levels[c] < 0.05)
        }
    }

    @Test func aSustainInterruptedForOneBufferStartsOver() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000, attackSeconds: 0.0001, releaseSeconds: 0.0001)
        feed(&selector, [
            Segment(seconds: 0.1, rms: [0.05, 0.001]),
            Segment(seconds: 0.03, rms: [0.05, 0.5]),
            Segment(seconds: 240.0 / 48_000, rms: [0.05, 0.001]),
            Segment(seconds: 0.03, rms: [0.05, 0.5]),
            Segment(seconds: 0.2, rms: [0.05, 0.001]),
        ], bufferFrames: 240)
        #expect(selector.switchCount == 0)
        #expect(selector.selected == 0)
    }

    @Test func aSwitchRecordCarriesTheLevelsAtTheSwitch() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        feed(&selector, [
            Segment(seconds: 0.1, rms: [0.05, 0.001]),
            Segment(seconds: 0.5, rms: [0.05, 0.5]),
            Segment(seconds: 1, rms: [0.0, 0.0]),
        ], bufferFrames: 128)
        let record = try! #require(selector.switches.first)
        #expect(record.from == 0 && record.to == 1)
        #expect(record.levels[1] > 0.05 * db(6))
        #expect(record.levels[1] > selector.levels[1] * 10)
        #expect(record.atSeconds > 0.1 && record.atSeconds < 0.3)
    }

    @Test func onlyTheMostRecentSwitchesAreKept() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 8_000)
        var segments: [Segment] = []
        for i in 0..<(ChannelSelector.switchHistoryCapacity + 3) {
            segments.append(Segment(seconds: 15, rms: i.isMultiple(of: 2) ? [0.001, 0.5] : [0.5, 0.001]))
        }
        feed(&selector, [Segment(seconds: 1024.0 / 8_000, rms: [0.5, 0.001])] + segments, bufferFrames: 1024,
             sampleRate: 8_000)
        #expect(selector.switchCount == ChannelSelector.switchHistoryCapacity + 3)
        #expect(selector.switches.count == ChannelSelector.switchHistoryCapacity)
        #expect(selector.switches.last?.to == selector.selected)
    }

    @Test func theLogSummaryNamesTheChoiceAndTheLevelsThatExplainIt() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        feed(&selector, [
            Segment(seconds: 0.1, rms: [0.05, 0.001]),
            Segment(seconds: 0.5, rms: [0.05, 0.5]),
        ], bufferFrames: 240)
        let summary = selector.logSummary
        #expect(summary.hasPrefix("channels=2 selected=1 switches=1 peak=[0.0500,0.5000] switch=[t=0."))
        #expect(summary.contains(" 0→1 levels=["))
    }

    @Test(arguments: [64, 4096])
    func aLoudClickInTheFirstBufferCannotLockOutSpeechOnAnotherChannel(bufferFrames: Int) {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        let run = feed(&selector, [
            Segment(seconds: Double(bufferFrames) / 48_000, rms: [0.8, 0.001]),
            Segment(seconds: 0.2, rms: [0.001, 0.001]),
            Segment(seconds: 1, rms: [0.001, 0.02]),
        ], bufferFrames: bufferFrames)
        #expect(selector.selected == 1)
        let switchedAt = try! #require(run.firstSwitchSeconds)
        let speechStart = Double(bufferFrames) / 48_000 + 0.2
        #expect(switchedAt - speechStart < 0.15 + 2 * Double(bufferFrames) / 48_000)
    }

    @Test func aClickOnTheRecordedChannelDoesNotRaiseTheBarForTheRealMic() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        let run = feed(&selector, [
            Segment(seconds: 0.2, rms: [0.005, 0.001]),
            Segment(seconds: 0.005, rms: [0.8, 0.001]),
            Segment(seconds: 0.1, rms: [0.005, 0.001]),
            Segment(seconds: 1, rms: [0.005, 0.03]),
        ], bufferFrames: 240)
        #expect(selector.selected == 1)
        let switchedAt = try! #require(run.firstSwitchSeconds)
        #expect(switchedAt - 0.305 < 0.15)
    }

    @Test func aBriefBumpOnAnUnusedInputGivesTheTakeBackAsSoonAsItEnds() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        feed(&selector, [
            Segment(seconds: 0.5, rms: [0.001, 0.2]),
            Segment(seconds: 0.08, rms: [0.5, 0.2]),
            Segment(seconds: 1, rms: [0.001, 0.2]),
        ], bufferFrames: 240)
        #expect(selector.selected == 1)
        #expect(selector.switchCount == 2)
        let recovered = try! #require(selector.switches.last)
        #expect(recovered.to == 1)
        #expect(recovered.atSeconds - 0.58 < 0.15)
    }

    // Pins the hold tradeoff: a bump that outlasts the hold-qualify window is indistinguishable from speech, so it
    // earns protection, and the speaking channel wins back only once that held peak decays below the margin.
    @Test func aBumpLongerThanTheQualifyWindowIsHeldUntilItsPeakDecays() {
        var selector = ChannelSelector(channelCount: 2, sampleRate: 48_000)
        feed(&selector, [
            Segment(seconds: 0.5, rms: [0.001, 0.2]),
            Segment(seconds: 0.5, rms: [0.5, 0.2]),
            Segment(seconds: 8, rms: [0.001, 0.2]),
        ], bufferFrames: 240)
        #expect(selector.switchCount == 2)
        #expect(selector.selected == 1)
        let recovered = try! #require(selector.switches.last)
        let expected = ChannelSelector.peakHoldDecaySeconds * log(0.5 * 2 / 0.2)
        #expect(abs(recovered.atSeconds - 1.0 - expected) < 0.7)
    }
}
