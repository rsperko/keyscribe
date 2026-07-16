import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct HistoryPaneModelTests {
    @Test func searchResultOutsideInitialLoadIsSelectable() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for number in 0...1_000 {
            var value = entry("recent-\(number)")
            value.timestamp = Date(timeIntervalSince1970: Double(number))
            try store.append(value, today: "2026-07-10")
        }
        var older = entry("older-search-result")
        older.timestamp = Date(timeIntervalSince1970: -1)
        try store.append(older, today: "2026-07-01")
        let model = model(store)
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.query = "older-search-result"
        for _ in 0..<80 where !model.groups.flatMap(\.rows).contains(where: { $0.entry.result == "older-search-result" }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        model.selection = model.groups.first?.rows.first?.id
        #expect(model.selected?.result == "older-search-result")
    }
    private func tempStore() -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-history-pane-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (HistoryStore(supportDir: dir), dir)
    }

    private func entry(_ result: String) -> HistoryEntry {
        HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_000_000), modeName: "Plain Dictation",
            heard: result, result: result, outcome: .inserted,
            cloudInvolved: false, redaction: false, contextCategories: [])
    }

    private func model(_ store: HistoryStore) -> HistoryPaneModel {
        HistoryPaneModel(
            store: store, addDictionaryWord: { _ in true },
            analyzeDictionaryWord: { _ in VocabularyAnalysis(action: .addWord) },
            addReplacement: { _, _ in true }, openSettings: { _ in })
    }

    @Test func releaseForCloseClearsAllInMemoryState() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(entry("hello world"), today: "2026-07-10")
        let model = model(store)

        model.reload()
        for _ in 0..<40 where !model.hasEntries { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.hasEntries)

        model.releaseForClose()

        #expect(!model.hasEntries)
        #expect(model.groups.isEmpty)
        #expect(model.selection == nil)
    }

    @Test func storeSignatureGatesRedundantReloads() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(entry("first"), today: "2026-07-10")
        let model = model(store)

        // SettingsController uses this to skip a redundant reload, so it must be stable when nothing changed.
        let a = model.storeSignature()
        let b = model.storeSignature()
        #expect(a == b)

        try store.append(entry("second"), today: "2026-07-10")
        #expect(model.storeSignature() != a)
    }

    @Test func selectingAnEntryExposesItAsSelected() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(entry("only entry"), today: "2026-07-10")
        let model = model(store)

        model.reload()
        // Auto-select is deferred a tick after rows commit; poll rather than race a fixed sleep.
        for _ in 0..<40 where model.selected == nil { try await Task.sleep(for: .milliseconds(50)) }

        #expect(model.selected?.result == "only entry")
    }

    @Test func retentionConfirmationIsNeededOnlyWhenFilesWouldBeRemoved() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(store)

        #expect(!model.wouldRemoveHistory(retainingDays: 7))

        try store.append(entry("old"), today: "2000-01-01")
        #expect(model.wouldRemoveHistory(retainingDays: 7))
    }
}
