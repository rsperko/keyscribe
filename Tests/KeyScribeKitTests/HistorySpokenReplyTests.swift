import Foundation
import Testing
@testable import KeyScribeKit

struct HistorySpokenReplyTests {
    private let at = Date(timeIntervalSince1970: 1_700_000_100)

    private func entry(heard: String = "", result: String = "", reply: HistoryEntry.SpokenReply?) -> HistoryEntry {
        var entry = HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), modeName: "Coding agent", heard: heard, result: result,
            outcome: .command, cloudInvolved: false, redaction: false, contextCategories: [])
        entry.spokenReply = reply
        return entry
    }

    @Test func aSpokenReplyRoundTripsUnderItsOnDiskKeys() throws {
        let original = entry(reply: .init(at: at, conversation: "docs", text: "docs: The tests pass.", connection: "Local oMLX"))
        let line = try original.jsonLine()
        for key in ["spoken_reply", "conversation", "connection"] {
            #expect(line.contains("\"\(key)\""), "\(key) missing from \(line)")
        }
        #expect(try HistoryEntry(jsonLine: line) == original)
    }

    @Test func anEntryWithoutASpokenReplyDecodesToNil() throws {
        let line = try entry(heard: "run the tests", result: "run the tests", reply: nil).jsonLine()
        #expect(!line.contains("spoken_reply"))
        #expect(try HistoryEntry(jsonLine: line).spokenReply == nil)
    }

    @Test func anEntryThatIsOnlyASpokenReplyListsWhatWasSaid() {
        #expect(entry(reply: .init(at: at, conversation: "docs", text: "docs is waiting for approval.")).listText
            == "docs is waiting for approval.")
        #expect(entry(heard: "run the tests", result: "run the tests", reply: .init(at: at, conversation: "docs", text: "docs: Done.")).listText
            == "run the tests")
    }

    @Test func aSummarizedReplyNamesWhereItsTextWent() {
        let summarized = entry(reply: .init(at: at, conversation: "docs", text: "docs: Done.", connection: "Local oMLX"))
        #expect(summarized.dataBoundaryLabels == ["Spoken summary", "Best-effort redaction"])
        let readAsIs = entry(reply: .init(at: at, conversation: "docs", text: "docs: Done."))
        #expect(readAsIs.dataBoundaryLabels == ["On this Mac"])
        var rewritten = summarized
        rewritten.cloudInvolved = true
        rewritten.redaction = true
        #expect(rewritten.dataBoundaryLabels == ["Cloud rewrite", "Best-effort redaction", "Spoken summary"])
    }

    @Test func searchFindsWhatWasSpoken() {
        let spoken = entry(heard: "run the tests", result: "run the tests", reply: .init(at: at, conversation: "docs", text: "docs: Two tests failed."))
        #expect(HistorySearch.matches(spoken, query: "two tests failed"))
    }

    @Test func exportsSayWhatWasSpokenAndWhoSummarizedIt() {
        let spoken = entry(heard: "run the tests", result: "run the tests", reply: .init(at: at, conversation: "docs", text: "docs: Two tests failed.", connection: "Local oMLX"))
        let formatting = HistoryExport.Formatting(day: { _ in "day" }, time: { _ in "12:00" })
        for format in [HistoryExport.Format.markdown, .text] {
            let out = HistoryExport.export([spoken], format: format, formatting: formatting, appName: "KeyScribe")
            #expect(out.contains("Read aloud: docs: Two tests failed. (summary by Local oMLX)"), "\(format)")
        }
    }

    @Test func aReplyOnItsOwnIsNotADictationInTheStats() {
        let dictation = entry(heard: "run the tests", result: "run the tests", reply: nil)
        let alone = entry(reply: .init(at: at, conversation: "docs", text: "docs: Done."))
        #expect(alone.isSpokenReplyOnly)
        #expect(!dictation.isSpokenReplyOnly)
        let stats = HistoryStats.compute(from: [dictation, alone])
        #expect(stats.total == 1)
        #expect(stats.byOutcome.values.reduce(0, +) == 1)
        #expect(stats.localCount == 1)
    }

    @Test func aReplyOnItsOwnExportsNoEmptyResult() {
        let alone = entry(reply: .init(at: at, conversation: "docs", text: "docs: Done."))
        let formatting = HistoryExport.Formatting(day: { _ in "day" }, time: { _ in "12:00" })
        for format in [HistoryExport.Format.markdown, .text] {
            let out = HistoryExport.export([alone], format: format, formatting: formatting, appName: "KeyScribe")
            #expect(!out.contains("Result:"), "\(format)")
            #expect(out.contains("Read aloud: docs: Done."), "\(format)")
        }
    }

    @Test func theSupportReportWarningMentionsWhatWasReadAloud() {
        #expect(SupportReport.warning.contains("read aloud"))
    }
}
