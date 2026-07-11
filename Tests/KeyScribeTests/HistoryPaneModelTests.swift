import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct HistoryPaneModelTests {
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

        // The signature is stable while nothing changes — the consumer (SettingsController) uses it to skip
        // a redundant reload; the same signature twice means the gate short-circuits.
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
        // The load is detached and the auto-select is deferred a tick after the rows commit; poll rather
        // than race a fixed sleep under suite load.
        for _ in 0..<40 where model.selected == nil { try await Task.sleep(for: .milliseconds(50)) }

        #expect(model.selected?.result == "only entry")
    }
}
