import Testing
@testable import KeyScribeKit

struct LevelWaveTests {
    @Test func emptyHistoryIsAllZeros() {
        #expect(LevelWave.bars(history: [], count: 5) == [0, 0, 0, 0, 0])
    }

    @Test func constantHistoryIsFlatBars() {
        let bars = LevelWave.bars(history: Array(repeating: 0.5, count: 10), count: 5)
        #expect(bars.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test func newestSampleIsTheCenterBar() {
        // history is most-recent-last; a lone spike at the end lands in the center bar.
        let bars = LevelWave.bars(history: [0, 0, 0, 0, 1], count: 5)
        #expect(bars[2] > bars[1])
        #expect(bars[2] > bars[3])
        #expect(bars[1] == bars[3])   // symmetric
        #expect(bars[0] == bars[4])
    }

    @Test func barsAreSymmetricAroundTheCenter() {
        let bars = LevelWave.bars(history: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7], count: 5)
        #expect(bars[0] == bars[4])
        #expect(bars[1] == bars[3])
    }

    @Test func inputsAreClampedToUnitRange() {
        let bars = LevelWave.bars(history: [-2, 5], count: 5)
        #expect(bars.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func countSevenProducesSevenSymmetricBars() {
        let bars = LevelWave.bars(history: [0, 0, 0, 0, 0, 0, 1], count: 7)
        #expect(bars.count == 7)
        #expect(bars[3] > bars[2])       // center is newest
        #expect(bars[2] == bars[4])
        #expect(bars[1] == bars[5])
        #expect(bars[0] == bars[6])
    }
}
