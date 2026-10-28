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
    @Test func theSelectedCommandStaysSelectedWhenItFinishesLate() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var started = entry("~/bin/deploy staging")
        started.outcome = .commandStarted
        try store.append(started, today: "2026-07-10")
        let model = model(store)
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.selection = model.groups.first?.rows.first?.id
        var finished = started
        finished.outcome = .command
        #expect(store.replace(started, with: finished))
        model.reload()
        for _ in 0..<80 where model.groups.first?.rows.first?.entry.outcome != .command {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.selected?.outcome == .command)
    }

    private func tempStore() -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-history-pane-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (HistoryStore(supportDir: dir), dir)
    }

    private func finder(word: String, heard: [String]) -> HistoryReplacementsModel {
        let items = heard.enumerated().map { i, text in
            HistorySnapshot.Item(reference: .init(dayFile: "d.jsonl", line: i), entry: entry(text))
        }
        let snapshot = HistorySnapshot(
            items: items, unreadableLines: 0, fingerprint: HistorySnapshot.Fingerprint(files: ["d.jsonl": items.count]))
        return HistoryReplacementsModel(
            word: word, destination: .global, destinationName: "Global", historyEnabled: true,
            dependencies: .init(
                loadSnapshot: { snapshot }, fingerprint: { snapshot.fingerprint },
                vocabulary: { .init(global: ReplacementsSet(), globalWords: [word], modes: []) },
                save: { _, _, _, _ in .saved }),
            onSaved: { _ in })
    }

    @Test func addingAWordFromHistoryOffersItsMishearings() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(store)
        model.mishearingsFinder = { word, _, _ in self.finder(word: word, heard: ["Croydon, create a pane", "Cryden, pair"]) }
        #expect(model.saveDictionaryWord("Kryten", .addWord) == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.mishearings == nil)
        model.dictionarySheetDidClose()
        for _ in 0..<200 where model.mishearings == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.mishearings?.offeredAfterAdding == true)
        #expect(Set(model.mishearings?.findings.map(\.phrase) ?? []) == ["Croydon", "Cryden"])
    }

    @Test func aSingleSuggestionIsConfirmedInOneStep() async throws {
        let items = [HistorySnapshot.Item(reference: .init(dayFile: "d.jsonl", line: 0), entry: entry("Ask Cryden for help"))]
        let snapshot = HistorySnapshot(
            items: items, unreadableLines: 0, fingerprint: HistorySnapshot.Fingerprint(files: ["d.jsonl": 1]))
        var saved: [ReplacementsSet.Rule] = []
        let finder = HistoryReplacementsModel(
            word: "Kryten", destination: .global, destinationName: "Global", historyEnabled: true,
            dependencies: .init(
                loadSnapshot: { snapshot }, fingerprint: { snapshot.fingerprint },
                vocabulary: { .init(global: ReplacementsSet(), globalWords: ["Kryten"], modes: []) },
                save: { _, _, proposed, _ in saved = proposed; return .saved }),
            onSaved: { _ in })
        finder.offeredAfterAdding = true
        await finder.refresh()
        #expect(finder.singleSuggestion?.heard == "Cryden")
        await finder.confirmSingleSuggestion()
        #expect(saved == [ReplacementsSet.Rule(heard: "Cryden", replace: "Kryten", regex: false)])
    }

    @Test func theFinderOpensEvenWhenTheAddSheetClosedBeforeTheSearchFinished() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(store)
        model.mishearingsFinder = { word, _, _ in self.finder(word: word, heard: ["Ask Cryden for help"]) }
        #expect(model.saveDictionaryWord("Kryten", .addWord) == nil)
        model.dictionarySheetDidClose()
        for _ in 0..<200 where model.mishearings == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.mishearings != nil)
    }

    @Test func addingAWordWithNoLikelyMishearingsOpensNothing() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(store)
        var built: HistoryReplacementsModel?
        model.mishearingsFinder = { word, _, _ in
            let made = self.finder(word: word, heard: ["nothing like it"])
            built = made
            return made
        }
        #expect(model.saveDictionaryWord("Kryten", .addWord) == nil)
        for _ in 0..<50 where built?.isWorking != false { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.mishearings == nil)
    }

    @Test func aSkippedRewriteIsLabelledAsSkippedNotAsAFallback() {
        var skipped = entry("hello")
        skipped.outcome = .localFallback
        #expect(outcomeLabel(skipped) == "Local fallback")
        skipped.rewriteSkippedMs = 17_460
        #expect(outcomeLabel(skipped) == "Rewrite skipped")
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
            addDictionaryWord: { corrections.words.append(($0, $1)); return .saved },
            analyzeDictionaryWord: { corrections.analyzed.append($1); return VocabularyAnalysis(action: .addWord) },
            addReplacement: { corrections.replacements.append(($0, $1, $2)); return .saved }, openSettings: { _ in })
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

    @Test func copyReportCopiesTheSelectedDictationWithTheSetupAndWarns() async throws {
        let model = try await selectingOnly(entry("hello there"), corrections: Corrections())
        var copied: String?
        model.copyText = { copied = $0 }
        model.supportSetup = { "SETUP SUMMARY" }
        model.copyReport()
        #expect(copied?.contains("hello there") == true)
        #expect(copied?.contains("SETUP SUMMARY") == true)
        #expect(model.statusMessage?.contains("what you said") == true)
    }

    @Test func correctionsFromACommandGoToTheVoiceCommandsVocabulary() async throws {
        var command = entry("~/bin/deploy prod")
        command.outcome = .command
        let corrections = Corrections()
        let model = try await selectingOnly(command, corrections: corrections)
        #expect(model.selected?.outcome == .command)
        _ = model.analyzeDictionaryWord("Hydra")
        #expect(model.addDictionaryWord("Hydra") == .saved)
        #expect(model.addReplacement("hydro", "Hydra") == .saved)
        #expect(corrections.analyzed == [.mode(Mode.voiceCommandsId)])
        #expect(corrections.words.map(\.1) == [.mode(Mode.voiceCommandsId)])
        #expect(corrections.replacements.map(\.2) == [.mode(Mode.voiceCommandsId)])
    }

    @Test func aCommandCannotBeCorrectedWhileVoiceCommandsIsOff() async throws {
        var command = entry("~/bin/deploy prod")
        command.outcome = .command
        let corrections = Corrections()
        let model = try await selectingOnly(command, corrections: corrections)
        model.voiceCommandsEnabled = { false }
        #expect(!model.canCorrect)
        #expect(model.addDictionaryWord("Hydra") == .failed)
        #expect(model.addReplacement("hydro", "Hydra") == .failed)
        #expect(corrections.words.isEmpty && corrections.replacements.isEmpty)
    }

    @Test func correctionsFromADictationGoToTheGlobalVocabulary() async throws {
        let corrections = Corrections()
        let model = try await selectingOnly(entry("hello"), corrections: corrections)
        #expect(model.addDictionaryWord("Hydra") == .saved)
        #expect(model.addReplacement("hydro", "Hydra") == .saved)
        #expect(corrections.words.map(\.1) == [.global])
        #expect(corrections.replacements.map(\.2) == [.global])
    }

    @Test func aRefusedSheetSaveReturnsTheReasonAndARetrySucceeds() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(entry("hello"), today: "2026-07-10")
        var results: [ConfigRepository.AddResult] = [.refused("dictionary.toml has an unread key"), .saved,
                                                     .refused("replacements.toml has an unread key"), .saved]
        var attempts: [String] = []
        let model = HistoryPaneModel(
            store: store,
            addDictionaryWord: { word, _ in attempts.append(word); return results.removeFirst() },
            analyzeDictionaryWord: { _, _ in VocabularyAnalysis(action: .addWord) },
            addReplacement: { heard, _, _ in attempts.append(heard); return results.removeFirst() },
            openSettings: { _ in })
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.selection = model.groups.first?.rows.first?.id

        #expect(model.saveDictionaryWord("Hydra", .addWord) == "dictionary.toml has an unread key")
        #expect(model.statusMessage == nil)
        #expect(model.saveDictionaryWord("Hydra", .addWord) == nil)
        #expect(model.statusMessage?.contains("Hydra") == true)

        #expect(model.saveReplacement("hydro", "Hydra") == "replacements.toml has an unread key")
        #expect(model.saveReplacement("hydro", "Hydra") == nil)
        #expect(attempts == ["Hydra", "Hydra", "hydro", "hydro"])
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
