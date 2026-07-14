import Testing
@testable import KeyScribeKit

struct HistoryComparisonTests {
    // A cloud-rewritten entry whose local pipeline was a no-op is stored with transformed == nil; the
    // breakdown must still appear, with the rewrite step showing heard -> result.
    @Test func cloudEntryWithNoLocalChangeStillShowsRewriteBreakdown() {
        let stages = HistoryComparison.stages(cloudInvolved: true)
        #expect(stages == [.heardInserted, .onThisMac, .rewrite])

        let onMac = HistoryComparison.texts(
            for: .onThisMac, heard: "send it to pat", transformed: nil, result: "Send it to Matt.")
        #expect(onMac == (from: "send it to pat", to: "send it to pat"))

        let rewrite = HistoryComparison.texts(
            for: .rewrite, heard: "send it to pat", transformed: nil, result: "Send it to Matt.")
        #expect(rewrite == (from: "send it to pat", to: "Send it to Matt."))
    }

    @Test func cloudEntryWithLocalEditsSplitsLocalFromRewrite() {
        let heard = "teh report", transformed = "the report", result = "The report is ready."
        let onMac = HistoryComparison.texts(
            for: .onThisMac, heard: heard, transformed: transformed, result: result)
        #expect(onMac == (from: heard, to: transformed))

        let rewrite = HistoryComparison.texts(
            for: .rewrite, heard: heard, transformed: transformed, result: result)
        #expect(rewrite == (from: transformed, to: result))
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
