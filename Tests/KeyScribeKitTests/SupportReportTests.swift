import Foundation
import Testing
@testable import KeyScribeKit

struct SupportReportTests {
    private func entry() -> HistoryEntry {
        var e = HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), modeName: "IDE",
            heard: "rename the build target", result: "Rename the build target.", outcome: .inserted,
            cloudInvolved: true, redaction: false, contextCategories: [],
            prompt: "PROMPT TEXT", received: "RECEIVED TEXT")
        e.targetApp = "com.microsoft.VSCode"
        return e
    }

    @Test func theReportWarnsFirstThatItHoldsWhatWasSaid() {
        let report = SupportReport.render(entry: entry(), appName: "KeyScribe", setup: "SETUP")
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "KeyScribe support report")
        #expect(lines.dropFirst().prefix(3).joined(separator: " ").contains("what you said"))
    }

    @Test func theReportCarriesEveryRecordedFieldAndTheSetup() {
        let report = SupportReport.render(entry: entry(), appName: "KeyScribe", setup: "SETUP SUMMARY")
        for text in ["rename the build target", "Rename the build target.", "PROMPT TEXT", "RECEIVED TEXT",
                     "\"target_app\" : \"com.microsoft.VSCode\"", "SETUP SUMMARY"] {
            #expect(report.contains(text), "\(text) missing")
        }
        let dictation = report.range(of: "rename the build target")!.lowerBound
        #expect(dictation < report.range(of: "SETUP SUMMARY")!.lowerBound)
    }

    @Test func theWarningNamesTheAIRequestAndReplyToo() {
        #expect(SupportReport.warning.contains("AI request and reply"))
    }

    @Test func aSpokenPhraseThatSwitchedModesIsExplainedAfterTheShortcutTrace() {
        var e = entry()
        e.modeName = "Slack"
        e.modeChoice = .spokenPhrase
        e.routedPhrase = "for slack"
        e.shortcutCandidates = [ModeCandidate(id: "ide", name: "IDE", verdict: .chosen)]
        let report = SupportReport.render(entry: e, appName: "KeyScribe", setup: "SETUP")
        #expect(report.contains("shortcut_candidates shows the mode the shortcut picked before anything was said"))
        #expect(report.contains("The spoken phrase \u{201C}for slack\u{201D} then switched to Slack."))
    }
}
