import Foundation
import Testing
@testable import KeyScribeKit

private func entry(
    _ result: String, heard: String? = nil, mode: String = "Plain Dictation",
    outcome: HistoryEntry.Outcome = .inserted, secondsAgo: TimeInterval = 0,
    cloud: Bool = false, redaction: Bool = false, contextCategories: [String] = []
) -> HistoryEntry {
    HistoryEntry(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000 - secondsAgo),
        modeName: mode, heard: heard ?? result, result: result, outcome: outcome,
        cloudInvolved: cloud, redaction: redaction, contextCategories: contextCategories)
}

// Fixed UTC/POSIX formatting keeps assertions stable regardless of the machine's locale/timezone.
private func utc() -> HistoryExport.Formatting {
    let day = DateFormatter()
    day.calendar = Calendar(identifier: .gregorian); day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = TimeZone(identifier: "UTC"); day.dateFormat = "yyyy-MM-dd"
    let time = DateFormatter()
    time.calendar = Calendar(identifier: .gregorian); time.locale = Locale(identifier: "en_US_POSIX")
    time.timeZone = TimeZone(identifier: "UTC"); time.dateFormat = "HH:mm"
    return HistoryExport.Formatting(day: { day.string(from: $0) }, time: { time.string(from: $0) })
}

struct HistoryExportTests {
    @Test func jsonExportRoundTripsLineByLineThroughHistoryEntry() throws {
        let entries = [entry("first"), entry("second", secondsAgo: 90_000)]
        let out = HistoryExport.export(entries, format: .json, formatting: utc(), appName: "KeyScribe")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 2)
        let decoded = try lines.map { try HistoryEntry(jsonLine: $0) }
        #expect(decoded == entries)
    }

    @Test func markdownGroupsByDayWithHeadingsAndBoundaryLabels() {
        let entries = [
            entry("hello", mode: "Email", outcome: .inserted),
            entry("secret", mode: "Secure", outcome: .copied, secondsAgo: 90_000, cloud: true, redaction: true),
        ]
        let md = HistoryExport.export(entries, format: .markdown, formatting: utc(), appName: "KeyScribe")
        #expect(md.contains("## 2023-11-14"))
        #expect(md.contains("## 2023-11-13"))
        #expect(md.contains("Email"))
        #expect(md.contains("On this Mac"))
        #expect(md.contains("Cloud rewrite"))
        #expect(md.contains("Best-effort redaction"))
        #expect(md.contains("hello"))
    }

    @Test func textExportContainsResultsAndOutcomes() {
        let md = HistoryExport.export([entry("ship it", outcome: .inserted)], format: .text, formatting: utc(), appName: "KeyScribe")
        #expect(md.contains("ship it"))
        #expect(md.contains("Inserted"))
    }

    @Test func headerUsesTheSuppliedAppName() {
        let entries = [entry("hello", outcome: .inserted)]
        let md = HistoryExport.export(entries, format: .markdown, formatting: utc(), appName: "Acme Voice")
        let txt = HistoryExport.export(entries, format: .text, formatting: utc(), appName: "Acme Voice")
        #expect(md.hasPrefix("# Acme Voice history\n"))
        #expect(txt.hasPrefix("Acme Voice history\n"))
        #expect(!md.contains("KeyScribe"))
    }

    @Test func emptyExportIsNotCrashing() {
        #expect(HistoryExport.export([], format: .json, formatting: utc(), appName: "KeyScribe").isEmpty)
        #expect(!HistoryExport.export([], format: .markdown, formatting: utc(), appName: "KeyScribe").isEmpty)
    }
}

struct HistoryStatsTests {
    @Test func computesTotalsByModeOutcomeAndCloud() {
        let entries = [
            entry("one two three", mode: "Email", outcome: .inserted, cloud: true, redaction: true),
            entry("four", mode: "Email", outcome: .copied),
            entry("five six", mode: "Notes", outcome: .inserted, cloud: true),
        ]
        let s = HistoryStats.compute(from: entries)
        #expect(s.total == 3)
        #expect(s.byMode["Email"] == 2)
        #expect(s.byMode["Notes"] == 1)
        #expect(s.byOutcome[.inserted] == 2)
        #expect(s.byOutcome[.copied] == 1)
        #expect(s.cloudCount == 2)
        #expect(s.localCount == 1)
        #expect(s.redactionCount == 1)
        #expect(s.wordsDictated == 6)        // 3 + 1 + 2
    }

    @Test func redactionRateIsFractionOfTotal() {
        let s = HistoryStats.compute(from: [
            entry("a", redaction: true), entry("b"), entry("c", redaction: true), entry("d"),
        ])
        #expect(s.redactionRate == 0.5)
    }

    @Test func firstAndLastTimestampSpanTheEntries() {
        let s = HistoryStats.compute(from: [entry("new", secondsAgo: 0), entry("old", secondsAgo: 1000)])
        #expect(s.firstTimestamp == Date(timeIntervalSince1970: 1_700_000_000 - 1000))
        #expect(s.lastTimestamp == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func emptyStatsAreZeroed() {
        let s = HistoryStats.compute(from: [])
        #expect(s.total == 0)
        #expect(s.redactionRate == 0)
        #expect(s.firstTimestamp == nil)
        #expect(s.wordsDictated == 0)
    }
}
