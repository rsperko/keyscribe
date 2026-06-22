import Foundation
import Testing
@testable import KeyScribeKit

private func sampleEntry(
    heard: String = "send the report", result: String = "Send the report.",
    mode: String = "Polished Dictation", outcome: HistoryEntry.Outcome = .inserted,
    at seconds: TimeInterval = 0
) -> HistoryEntry {
    HistoryEntry(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
        modeName: mode, heard: heard, result: result, outcome: outcome,
        cloudInvolved: outcome != .inserted, redaction: false, contextCategories: [])
}

struct HistoryEntryCodecTests {
    @Test func roundTripsThroughJsonLine() throws {
        let entry = HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            modeName: "Email", heard: "polish that", result: "Polished.", outcome: .localFallback,
            cloudInvolved: true, redaction: true, contextCategories: ["app"],
            connection: "oMLX", model: "Qwen3-Coder-30B", prompt: "system\n⟦SN:REDACT:1⟧")
        let decoded = try HistoryEntry(jsonLine: try entry.jsonLine())
        #expect(decoded == entry)
    }

    @Test func transformedStageRoundTrips() throws {
        let entry = HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            modeName: "Email", heard: "teh github repo", transformed: "the GitHub repo",
            result: "The GitHub repo.", outcome: .inserted,
            cloudInvolved: true, redaction: false, contextCategories: [])
        let decoded = try HistoryEntry(jsonLine: try entry.jsonLine())
        #expect(decoded.transformed == "the GitHub repo")
        #expect(decoded == entry)
    }

    @Test func olderLinesWithoutTransformedDecodeToNil() throws {
        let line = """
        {"cloud_involved":false,"context_categories":[],"heard":"hello","mode":"Plain","outcome":"inserted","redaction":false,"result":"hello","timestamp":"2023-11-14T22:13:20Z"}
        """
        let decoded = try HistoryEntry(jsonLine: line)
        #expect(decoded.transformed == nil)
    }

    @Test func multilineContentStaysOnOneLine() throws {
        let entry = sampleEntry(heard: "first line\nsecond line", result: "A\n\nB")
        let line = try entry.jsonLine()
        #expect(!line.contains("\n"))                       // newlines escaped, JSONL integrity holds
        #expect(try HistoryEntry(jsonLine: line) == entry)
    }

    @Test func outcomeUsesSnakeCaseRawValue() throws {
        let line = try sampleEntry(outcome: .localFallback).jsonLine()
        #expect(line.contains("\"local_fallback\""))
    }

    @Test func dataBoundaryLabelsUseSharedVocabulary() {
        let entry = HistoryEntry(
            timestamp: Date(), modeName: "Email", heard: "hello", result: "Hello.", outcome: .inserted,
            cloudInvolved: true, redaction: false, contextCategories: ["app", "visible text"])
        #expect(entry.dataBoundaryLabels == ["Cloud rewrite", "App shared", "Visible text shared"])
    }

    @Test func contextLabelsExcludeRedactionAndUnknownCategories() {
        let entry = HistoryEntry(
            timestamp: Date(), modeName: "Email", heard: "hello", result: "Hello.", outcome: .inserted,
            cloudInvolved: true, redaction: true, contextCategories: ["app", "mystery"])
        #expect(entry.dataBoundaryLabels == ["Cloud rewrite", "Best-effort redaction", "App shared"])
        #expect(entry.contextLabels == ["App shared"])
    }
}

struct HistoryRetentionTests {
    @Test func dropsFilesOlderThanRetentionDays() {
        let files = ["2026-06-10.jsonl", "2026-06-13.jsonl", "2026-06-19.jsonl", "2026-06-20.jsonl"]
        let expired = HistoryRetention.expired(dayFiles: files, today: "2026-06-20", retentionDays: 7)
        #expect(expired == ["2026-06-10.jsonl"])            // 10 days old > 7; 13 (7 days) kept
    }

    @Test func zeroRetentionKeepsOnlyToday() {
        let files = ["2026-06-19.jsonl", "2026-06-20.jsonl"]
        #expect(HistoryRetention.expired(dayFiles: files, today: "2026-06-20", retentionDays: 0)
            == ["2026-06-19.jsonl"])
    }

    @Test func ignoresUnparseableNames() {
        let expired = HistoryRetention.expired(
            dayFiles: ["notes.jsonl", "2026-06-01.jsonl"], today: "2026-06-20", retentionDays: 7)
        #expect(expired == ["2026-06-01.jsonl"])
    }
}

struct HistorySearchTests {
    let entries = [
        sampleEntry(heard: "send the report", result: "Send the report.", mode: "Email"),
        sampleEntry(heard: "meeting notes", result: "Meeting notes", mode: "Plain Dictation"),
    ]

    @Test func emptyQueryReturnsAll() {
        #expect(HistorySearch.filter(entries, query: "  ").count == 2)
    }

    @Test func matchesHeardResultAndModeCaseInsensitively() {
        #expect(HistorySearch.filter(entries, query: "REPORT").count == 1)
        #expect(HistorySearch.filter(entries, query: "plain").count == 1)
        #expect(HistorySearch.filter(entries, query: "Meeting notes").count == 1)
        #expect(HistorySearch.filter(entries, query: "absent").isEmpty)
    }
}

struct CorrectionSurfaceTests {
    @Test func addingWordIgnoresBlanksAndCaseInsensitiveDups() {
        var set = DictionarySet().adding(word: "KeyScribe")
        set = set.adding(word: "  ")
        set = set.adding(word: "keyscribe")            // dup (case-insensitive)
        set = set.adding(word: "Parakeet")
        #expect(set.words == ["KeyScribe", "Parakeet"])
    }

    @Test func addingLiteralRuleIgnoresBlankAndDupHeard() {
        var set = ReplacementsSet().addingLiteral(heard: "github", replace: "GitHub")
        set = set.addingLiteral(heard: "  ", replace: "x")
        set = set.addingLiteral(heard: "GITHUB", replace: "GitHub")   // dup heard
        #expect(set.rules.count == 1)
        #expect(set.rules.first?.heard == "github")
        #expect(set.rules.first?.regex == false)
    }

    @Test func storesWriteAndReloadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vocab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try DictionaryStore.write(DictionarySet().adding(word: "Parakeet"), to: dir)
        #expect(DictionaryStore.loadOrDefault(supportDir: dir).words == ["Parakeet"])

        try ReplacementsStore.write(ReplacementsSet().addingLiteral(heard: "teh", replace: "the"), to: dir)
        let reloaded = ReplacementsStore.loadOrDefault(supportDir: dir)
        #expect(reloaded.rules.count == 1)
        #expect(reloaded.rules.first?.replace == "the")
    }
}

struct HistoryStoreTests {
    private func tempStore() -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-history-test-\(UUID().uuidString)", isDirectory: true)
        return HistoryStore(supportDir: dir)
    }

    @Test func appendThenReadRoundTrips() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try store.append(sampleEntry(heard: "one", at: 0), today: "2026-06-20")
        try store.append(sampleEntry(heard: "two", at: 10), today: "2026-06-20")
        let entries = store.entries()
        #expect(entries.count == 2)
        #expect(entries.first?.heard == "two")              // newest first
        #expect(store.dayFiles() == ["2026-06-20.jsonl"])   // same day → one file
    }

    @Test func entriesSpanMultipleDayFilesNewestFirst() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try store.append(sampleEntry(heard: "older", at: 0), today: "2026-06-19")
        try store.append(sampleEntry(heard: "newer", at: 100), today: "2026-06-20")
        #expect(store.dayFiles().count == 2)
        #expect(store.entries().map(\.heard) == ["newer", "older"])
    }

    @Test func entriesLimitReturnsNewestPage() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try store.append(sampleEntry(heard: "a", at: 0), today: "2026-06-20")
        try store.append(sampleEntry(heard: "b", at: 10), today: "2026-06-20")
        try store.append(sampleEntry(heard: "c", at: 20), today: "2026-06-20")
        #expect(store.entries(limit: 2).map(\.heard) == ["c", "b"])
    }

    @Test func entriesLimitStopsBeforeOlderDayFiles() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try store.append(sampleEntry(heard: "old", at: 0), today: "2026-06-18")
        try store.append(sampleEntry(heard: "mid", at: 0), today: "2026-06-19")
        try store.append(sampleEntry(heard: "new", at: 0), today: "2026-06-20")
        #expect(store.entries(limit: 1).map(\.heard) == ["new"])
    }

    @Test func applyRetentionDeletesExpiredDayFiles() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try store.append(sampleEntry(at: 0), today: "2026-06-01")
        try store.append(sampleEntry(at: 0), today: "2026-06-20")
        let deleted = store.applyRetention(today: "2026-06-20", retentionDays: 7)
        #expect(deleted == ["2026-06-01.jsonl"])
        #expect(store.dayFiles() == ["2026-06-20.jsonl"])
    }
}
