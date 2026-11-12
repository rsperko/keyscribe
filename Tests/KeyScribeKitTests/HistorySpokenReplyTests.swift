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

    @Test func theVoiceThatReadAReplySurvivesTheStoreAsAStableIdentifier() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-voice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(supportDir: dir)
        var saved = entry(reply: .init(
            at: at, conversation: "docs", text: "docs: Done.", voice: SpokenAttempt.Reader.macOS.rawValue,
            reason: "the natural voice took too long"))
        saved.id = "r1"
        try store.append(saved)
        let line = try saved.jsonLine()
        #expect(line.contains("\"voice\":\"macos\""))
        #expect(store.entries(limit: 1, where: { _ in true }).first?.spokenReply?.voice == "macos")
        #expect(store.entries(limit: 1, where: { _ in true }).first?.spokenReply?.reason == "the natural voice took too long")
        #expect(SpokenAttempt.Reader(rawValue: "natural") == .natural)
    }

    @Test func aSupportReportSaysWhichVoiceReadTheReply() {
        let spoken = entry(reply: .init(at: at, conversation: "docs", text: "docs: Done.", voice: "natural"))
        #expect(SupportReport.render(entry: spoken, appName: "KeyScribe", setup: "").contains("\"voice\" : \"natural\""))
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
        #expect(summarized.dataBoundaryLabels == ["Reply summary", "Best-effort redaction"])
        let readAsIs = entry(reply: .init(at: at, conversation: "docs", text: "docs: Done."))
        #expect(readAsIs.dataBoundaryLabels == ["On this Mac"])
        var rewritten = summarized
        rewritten.cloudInvolved = true
        rewritten.redaction = true
        #expect(rewritten.dataBoundaryLabels == ["Cloud rewrite", "Best-effort redaction", "Reply summary"])
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
            #expect(out.contains("Reply: docs: Two tests failed. (summary by Local oMLX)"), "\(format)")
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
            #expect(out.contains("Reply: docs: Done."), "\(format)")
        }
    }

    @Test func theSupportReportWarningMentionsTheReplyUpdate() {
        #expect(SupportReport.warning.contains("for a coding agent its reply update"))
    }
}
