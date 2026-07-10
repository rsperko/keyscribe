import Testing
@testable import KeyScribeKit

struct BenchmarkResultsMergeTests {
    private let a: [String: Double] = ["werBiased": 0.05]
    private let b: [String: Double] = ["werBiased": 0.06]
    private let bNew: [String: Double] = ["werBiased": 0.04]

    @Test func filteredRunPreservesUntouchedEngineRows() {
        let existing = ["a": a, "b": b]
        let fresh = ["b": bNew]
        let merged = BenchmarkResultsMerge.merged(existing: existing, fresh: fresh, replace: false)
        #expect(merged["a"] == a)          // untouched engine survived
        #expect(merged["b"] == bNew)       // measured engine overwritten with fresh row
        #expect(merged.count == 2)
    }

    @Test func fullFleetRunReplacesEverything() {
        let existing = ["a": a, "b": b, "stale": a]
        let fresh = ["a": a, "b": bNew]
        let merged = BenchmarkResultsMerge.merged(existing: existing, fresh: fresh, replace: true)
        #expect(merged == fresh)           // old rows discarded, incl. the stale one
    }

    @Test func filteredRunIntoEmptyFileJustWritesFresh() {
        let merged = BenchmarkResultsMerge.merged(existing: [:], fresh: ["b": bNew], replace: false)
        #expect(merged == ["b": bNew])
    }
}
