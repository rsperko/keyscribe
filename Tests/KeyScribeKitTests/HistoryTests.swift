import Foundation
import Testing
@testable import KeyScribeKit

private func sampleEntry(
    heard: String = "send the report", result: String = "Send the report.",
        mode: String = "Polish", outcome: HistoryEntry.Outcome = .inserted,
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

    @Test func sttEngineRoundTrips() throws {
        let entry = HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            modeName: "Plain", engine: "Parakeet TDT v3", heard: "hello", result: "Hello.",
            outcome: .inserted, cloudInvolved: false, redaction: false, contextCategories: [])
        let decoded = try HistoryEntry(jsonLine: try entry.jsonLine())
        #expect(decoded.engine == "Parakeet TDT v3")
        #expect(decoded == entry)
    }

    @Test func olderLinesWithoutEngineDecodeToNil() throws {
        let line = """
        {"cloud_involved":false,"context_categories":[],"heard":"hello","mode":"Plain","outcome":"inserted","redaction":false,"result":"hello","timestamp":"2023-11-14T22:13:20Z"}
        """
        #expect(try HistoryEntry(jsonLine: line).engine == nil)
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
            cloudInvolved: true, redaction: false, contextCategories: ["app", "preceding text"])
        #expect(entry.dataBoundaryLabels == ["Cloud rewrite", "App shared", "Preceding text shared"])
    }

    @Test func contextLabelsExcludeRedactionAndUnknownCategories() {
        let entry = HistoryEntry(
            timestamp: Date(), modeName: "Email", heard: "hello", result: "Hello.", outcome: .inserted,
            cloudInvolved: true, redaction: true, contextCategories: ["app", "mystery"])
        #expect(entry.dataBoundaryLabels == ["Cloud rewrite", "Best-effort redaction", "App shared"])
        #expect(entry.contextLabels == ["App shared"])
    }

    @Test func contextLabelsCoverEveryCategoryProducersEmit() {
        let entry = HistoryEntry(
            timestamp: Date(), modeName: "Email", heard: "hello", result: "Hello.", outcome: .inserted,
            cloudInvolved: true, redaction: false,
            contextCategories: ["app", "preceding text"])
        #expect(entry.contextLabels == ["App shared", "Preceding text shared"])
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

    func filter(_ query: String) -> [HistoryEntry] {
        entries.filter { HistorySearch.matches($0, query: query) }
    }

    @Test func emptyQueryReturnsAll() {
        #expect(filter("  ").count == 2)
    }

    @Test func matchesHeardResultAndModeCaseInsensitively() {
        #expect(filter("REPORT").count == 1)
        #expect(filter("plain").count == 1)
        #expect(filter("Meeting notes").count == 1)
        #expect(filter("absent").isEmpty)
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

    @Test func entriesLimitFillsThePagePastTrailingMalformedLines() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try store.append(sampleEntry(heard: "a", at: 0), today: "2026-06-20")
        try store.append(sampleEntry(heard: "b", at: 10), today: "2026-06-20")
        try store.append(sampleEntry(heard: "c", at: 20), today: "2026-06-20")
        let file = store.dir.appendingPathComponent("2026-06-20.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ broken future-schema line\n".utf8))
        try handle.close()
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

    @Test func deleteRemovesOnlyTheMatchingEntry() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let keep = sampleEntry(heard: "keep", at: 0)
        let drop = sampleEntry(heard: "drop", at: 10)
        try store.append(keep, today: "2026-06-20")
        try store.append(drop, today: "2026-06-20")
        #expect(store.delete(drop) == true)
        #expect(store.entries().map(\.heard) == ["keep"])
    }

    @Test func deleteRemovesTheDayFileWhenItBecomesEmpty() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let only = sampleEntry(heard: "only", at: 0)
        try store.append(only, today: "2026-06-19")
        try store.append(sampleEntry(heard: "newer", at: 0), today: "2026-06-20")
        #expect(store.delete(only) == true)
        #expect(store.dayFiles() == ["2026-06-20.jsonl"])
    }

    // Production appends an entry to the day file named for its own timestamp, so delete resolves that
    // file directly without scanning the others. A decoy in an unrelated day file must be left alone.
    @Test func deleteFindsTheEntryInItsTimestampDayFile() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let entry = sampleEntry(heard: "target", at: 0)
        try store.append(entry, today: HistoryStore.todayString(date: entry.timestamp))
        try store.append(sampleEntry(heard: "other-day", at: 0), today: "2099-01-01")
        #expect(store.delete(entry) == true)
        #expect(store.entries().map(\.heard) == ["other-day"])
        #expect(store.dayFiles() == ["2099-01-01.jsonl"])
    }

    @Test func deleteReturnsFalseWhenNoEntryMatches() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try store.append(sampleEntry(heard: "present", at: 0), today: "2026-06-20")
        #expect(store.delete(sampleEntry(heard: "absent", at: 99)) == false)
        #expect(store.entries().count == 1)
    }

    // Two byte-identical dictations in the same whole second are equal after round-trip (the timestamp
    // encodes at second precision). Deleting one must leave the other, not wipe both.
    @Test func deleteRemovesOnlyOneOfTwoIdenticalSameSecondEntries() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let dup = sampleEntry(heard: "same", result: "Same.", at: 0)
        try store.append(dup, today: "2026-06-20")
        try store.append(dup, today: "2026-06-20")
        #expect(store.delete(dup) == true)
        #expect(store.entries().count == 1)
        #expect(store.entries().first?.heard == "same")
    }

    // A crash can leave the last line without its trailing newline; the next append must not glue onto
    // it (which fuses two entries into one undecodable blob, losing both).
    @Test func appendHealsMissingTrailingNewline() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try store.append(sampleEntry(heard: "first", at: 0), today: "2026-06-20")
        let file = store.dir.appendingPathComponent("2026-06-20.jsonl")
        var content = try String(contentsOf: file, encoding: .utf8)
        while content.hasSuffix("\n") { content.removeLast() }   // simulate a crash-truncated line
        try Data(content.utf8).write(to: file)
        try store.append(sampleEntry(heard: "second", at: 10), today: "2026-06-20")
        #expect(Set(store.entries().map(\.heard)) == ["first", "second"])
    }

    @Test func appendDoesNotFallbackOverwriteExistingUnreadableFile() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try store.append(sampleEntry(heard: "first", at: 0), today: "2026-06-20")
        let file = store.dir.appendingPathComponent("2026-06-20.jsonl")
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        #expect(throws: (any Error).self) {
            try store.append(sampleEntry(heard: "second", at: 10), today: "2026-06-20")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect((try Data(contentsOf: file)) == before)
    }
}
