import Testing
@testable import KeyScribeKit

struct HistoryComparisonTests {
    // The real-world regression: a cloud-rewritten entry whose local pipeline was a no-op is stored with
    // transformed == nil. The breakdown must still appear, and the rewrite step must show heard -> result.
    @Test func cloudEntryWithNoLocalChangeStillShowsRewriteBreakdown() {
        let stages = HistoryComparison.stages(cloudInvolved: true)
        #expect(stages == [.heardInserted, .onThisMac, .rewrite])

        let onMac = HistoryComparison.texts(
            for: .onThisMac, heard: "send it to pat", transformed: nil, result: "Send it to Matt.")
        #expect(onMac == (from: "send it to pat", to: "send it to pat"))  // local did nothing

        let rewrite = HistoryComparison.texts(
            for: .rewrite, heard: "send it to pat", transformed: nil, result: "Send it to Matt.")
        #expect(rewrite == (from: "send it to pat", to: "Send it to Matt."))  // the AI's change is visible
    }

    @Test func cloudEntryWithLocalEditsSplitsLocalFromRewrite() {
        let heard = "teh report", transformed = "the report", result = "The report is ready."
        let onMac = HistoryComparison.texts(
            for: .onThisMac, heard: heard, transformed: transformed, result: result)
        #expect(onMac == (from: heard, to: transformed))  // local fixed the typo

        let rewrite = HistoryComparison.texts(
            for: .rewrite, heard: heard, transformed: transformed, result: result)
        #expect(rewrite == (from: transformed, to: result))  // the AI rewrote the local text
    }

    @Test func nonCloudEntryShowsOnlyHeardInserted() {
        #expect(HistoryComparison.stages(cloudInvolved: false) == [.heardInserted])
        let texts = HistoryComparison.texts(
            for: .heardInserted, heard: "teh report", transformed: "the report", result: "the report")
        #expect(texts == (from: "teh report", to: "the report"))
    }

    @Test func heardInsertedAlwaysSpansHeardToResult() {
        let texts = HistoryComparison.texts(
            for: .heardInserted, heard: "a", transformed: "b", result: "c")
        #expect(texts == (from: "a", to: "c"))
    }
}
