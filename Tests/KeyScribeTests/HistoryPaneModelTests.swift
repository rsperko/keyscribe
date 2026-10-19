import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct HistoryPaneModelTests {
    @Test func storedHistoryAvailabilityFollowsTheFirstSaveAndLastDeletion() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(store)

        await model.refreshHistoryAvailability()
        #expect(!model.hasStoredHistory)

        let saved = entry("retained dictation")
        try store.append(saved)
        await model.refreshHistoryAvailability()
        #expect(model.hasStoredHistory)

        store.delete(saved)
        await model.refreshHistoryAvailability()
        #expect(!model.hasStoredHistory)
    }

    @Test func availabilityFindsOlderHistoryPastEmptyAndUnreadableDayFiles() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: store.dir, withIntermediateDirectories: true)
        try Data().write(to: store.dir.appendingPathComponent("2026-10-21.jsonl"))
        try Data("{not json}\n".utf8).write(to: store.dir.appendingPathComponent("2026-10-20.jsonl"))
        let model = model(store)

        await model.refreshHistoryAvailability()
        #expect(!model.hasStoredHistory)

        try store.append(entry("older dictation"), today: "2026-09-01")
        await model.refreshHistoryAvailability()
        #expect(model.hasStoredHistory)
    }

    @Test func availabilityDoesNotDependOnSearchOrRetainParsedHistory() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(entry("retained dictation"))
        let model = model(store)
        model.query = "a phrase that is not stored"

        await model.refreshHistoryAvailability()
        #expect(model.hasStoredHistory)
        #expect(!model.hasEntries)

        model.releaseForClose()
        await model.refreshHistoryAvailability()
        #expect(model.hasStoredHistory)
    }

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

    private final class Corrections {
        var words: [(String, CorrectionDestination.Scope)] = []
        var analyzed: [CorrectionDestination.Scope] = []
        var replacements: [(String, String, CorrectionDestination.Scope)] = []
    }

    private func model(_ store: HistoryStore, corrections: Corrections = Corrections()) -> HistoryPaneModel {
        HistoryPaneModel(
            store: store,
            addDictionaryWord: { corrections.words.append(($0, $1)); return true },
            analyzeDictionaryWord: { corrections.analyzed.append($1); return VocabularyAnalysis(action: .addWord) },
            addReplacement: { corrections.replacements.append(($0, $1, $2)); return true }, openSettings: { _ in })
    }

    private func selectingOnly(_ value: HistoryEntry, corrections: Corrections) async throws -> HistoryPaneModel {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(value, today: "2026-07-10")
        let model = model(store, corrections: corrections)
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.selection = model.groups.first?.rows.first?.id
        return model
    }

    @Test func correctionsFromACommandGoToTheVoiceCommandsVocabulary() async throws {
        var command = entry("~/bin/deploy prod")
        command.outcome = .command
        let corrections = Corrections()
        let model = try await selectingOnly(command, corrections: corrections)
        #expect(model.selected?.outcome == .command)
        _ = model.analyzeDictionaryWord("Hydra")
        #expect(model.addDictionaryWord("Hydra"))
        #expect(model.addReplacement("hydro", "Hydra"))
        #expect(corrections.analyzed == [.mode(Mode.voiceCommandsId)])
        #expect(corrections.words.map(\.1) == [.mode(Mode.voiceCommandsId)])
        #expect(corrections.replacements.map(\.2) == [.mode(Mode.voiceCommandsId)])
    }

    @Test func correctionsFromADictationGoToTheGlobalVocabulary() async throws {
        let corrections = Corrections()
        let model = try await selectingOnly(entry("hello"), corrections: corrections)
        #expect(model.addDictionaryWord("Hydra"))
        #expect(model.addReplacement("hydro", "Hydra"))
        #expect(corrections.words.map(\.1) == [.global])
        #expect(corrections.replacements.map(\.2) == [.global])
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

    @Test func retentionChoicesOfferReadableLongPeriods() {
        let choices = HistoryRetentionChoice.options(including: 7)

        #expect(choices.contains(.init(days: 7, label: "1 week")))
        #expect(choices.contains(.init(days: 60, label: "2 months")))
        #expect(choices.contains(.init(days: 365, label: "1 year")))
    }

    @Test func retentionChoicesPreserveAnExistingCustomDuration() {
        let choices = HistoryRetentionChoice.options(including: 45)

        #expect(choices.contains(.init(days: 45, label: "45 days")))
        #expect(choices.map(\.days) == choices.map(\.days).sorted())
        #expect(HistoryRetentionChoice.displayLabel(for: 60) == "2 months")
        #expect(HistoryRetentionChoice.displayLabel(for: 45) == "45 days")
    }

    @Test func reducingRetentionConfirmsOnlyWhenItWouldDeleteHistory() {
        #expect(HistoryRetentionChoice.needsConfirmation(
            from: 60, to: 30, wouldRemoveHistory: true))
        #expect(!HistoryRetentionChoice.needsConfirmation(
            from: 60, to: 30, wouldRemoveHistory: false))
        #expect(!HistoryRetentionChoice.needsConfirmation(
            from: 30, to: 60, wouldRemoveHistory: true))
    }
}
