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

    @Test func aFailedDeliveryStillExplainsWhyTheRewriteReplyWasNotUsed() {
        var refused = entry("run the tests")
        refused.outcome = .failed
        refused.failureReason = "Not sent: keyscribe refused the message"
        refused.fallbackReason = "The reply dropped a protected token"
        refused.received = "garbled"
        #expect(whyLocalWasKept(refused) == "The reply dropped a protected token")
        #expect(showsUnusedReplyNote(refused))
    }

    @Test func aDeliveredRewriteShowsNoLocalTextExplanation() {
        var rewritten = entry("Run the tests.")
        rewritten.received = "Run the tests."
        #expect(whyLocalWasKept(rewritten) == nil)
        #expect(!showsUnusedReplyNote(rewritten))
    }

    @Test func aSkippedRewriteExplainsTheSkipEvenAfterAFailedDelivery() {
        var skipped = entry("run the tests")
        skipped.outcome = .failed
        skipped.rewriteSkippedMs = 2_000
        #expect(whyLocalWasKept(skipped) == HUDState.skippedLine(2))
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

    private func fallbackEntry() -> HistoryEntry {
        var value = entry("the plan.")
        value.id = "take-1"
        value.heard = "the plan"
        value.outcome = .localFallback
        value.fallbackReason = "HTTP 503"
        return value
    }

    private func rewriteDetails() -> RewriteDetails {
        RewriteDetails(
            connectionId: "c1", connection: "Smart", model: "m2", redaction: false, contextCategories: [],
            prompt: "new prompt", fellBack: false, received: "The plan.")
    }

    @Test func aRewriteAgainUpdatesTheSelectedFallbackInPlaceAndKeepsItSelected() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(fallbackEntry(), today: "2026-07-10")
        let model = model(store)
        let details = rewriteDetails()
        var asked: [String] = []
        model.rewriteAgain = { asked.append($0.heard); return .rewritten(text: "The plan.", details: details) }
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.selection = model.groups.first?.rows.first?.id
        #expect(model.canRewriteSelectedAgain)

        model.rewriteSelectedAgain()
        await model.rewriteAgainTask?.value
        for _ in 0..<80 where model.selected?.outcome != .rewrittenLater { try await Task.sleep(for: .milliseconds(25)) }

        #expect(asked == ["the plan"])
        #expect(model.selected?.result == "The plan.")
        #expect(model.selected?.connection == "Smart")
        #expect(store.entries(limit: nil).map(\.outcome) == [.rewrittenLater])
        #expect(!model.canRewriteSelectedAgain)
        #expect(model.statusMessage?.contains("Smart") == true)
    }

    @Test func aRewriteThatCannotRunLeavesTheEntryAndSaysWhy() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(fallbackEntry(), today: "2026-07-10")
        let model = model(store)
        model.rewriteAgain = { _ in .unavailable("The AI rewrite failed again: HTTP 503.") }
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.selection = model.groups.first?.rows.first?.id

        model.rewriteSelectedAgain()
        await model.rewriteAgainTask?.value

        #expect(store.entries(limit: nil).map(\.outcome) == [.localFallback])
        #expect(model.statusMessage == "The AI rewrite failed again: HTTP 503.")
        #expect(model.canRewriteSelectedAgain)
    }

    @Test func aDictationDeletedDuringARewriteIsNotRecreatedAndTheClipboardIsLeftAlone() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = fallbackEntry()
        try store.append(original, today: "2026-07-10")
        let model = model(store)
        var copied: [String] = []
        model.copyText = { copied.append($0) }
        let details = rewriteDetails()
        model.rewriteAgain = { entry in
            _ = store.delete(entry)
            return .rewritten(text: "The plan.", details: details)
        }
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.selection = model.groups.first?.rows.first?.id

        model.rewriteSelectedAgain()
        await model.rewriteAgainTask?.value

        #expect(store.entries(limit: nil).isEmpty)
        #expect(copied.isEmpty)
        #expect(model.statusMessage == "This dictation was deleted, so its rewrite was not kept.")
        #expect(model.selectedUnsavedRewrite == nil)
    }

    @Test func aRewriteThatCouldNotBeSavedIsOfferedUntilALaterRetrySavesOne() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(fallbackEntry(), today: "2026-07-10")
        let file = store.dir.appendingPathComponent("2026-07-10.jsonl")
        let saved = try Data(contentsOf: file)
        let model = model(store)
        let details = rewriteDetails()
        model.rewriteAgain = { _ in
            try? Data([0xFF, 0xFE]).write(to: file)
            return .rewritten(text: "First try.", details: details)
        }
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.selection = model.groups.first?.rows.first?.id

        model.rewriteSelectedAgain()
        await model.rewriteAgainTask?.value
        #expect(model.selectedUnsavedRewrite == "First try.")

        try saved.write(to: file)
        model.rewriteAgain = { _ in .rewritten(text: "Second try.", details: details) }
        model.rewriteSelectedAgain()
        await model.rewriteAgainTask?.value
        #expect(model.selectedUnsavedRewrite == nil)
        #expect(store.entries(limit: nil).map(\.result) == ["Second try."])
    }

    @MainActor private final class Gate { var open = false }

    @Test(arguments: [false, true])
    func aRewriteThatFinishesAfterHistoryClosedChangesNothing(saveFails: Bool) async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(fallbackEntry(), today: "2026-07-10")
        let file = store.dir.appendingPathComponent("2026-07-10.jsonl")
        let before = try Data(contentsOf: file)
        let model = model(store)
        let gate = Gate()
        let details = rewriteDetails()
        model.rewriteAgain = { _ in
            while !gate.open { try? await Task.sleep(for: .milliseconds(5)) }
            if saveFails { try? Data([0xFF, 0xFE]).write(to: file) }
            return .rewritten(text: "Late.", details: details)
        }
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.selection = model.groups.first?.rows.first?.id

        model.rewriteSelectedAgain()
        let task = model.rewriteAgainTask
        model.releaseForClose()
        gate.open = true
        await task?.value
        try await Task.sleep(for: .milliseconds(100))

        if !saveFails { #expect(try Data(contentsOf: file) == before) }
        #expect(!model.hasEntries)
        #expect(!model.rewritingAgain)
        #expect(model.unsavedRewrite == nil)
        #expect(model.statusMessage == nil)
    }

    @Test func theSelectedDictationShowsLikelyMishearingsAndACommandShowsNone() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var dictation = entry("Cryden, make a pane")
        dictation.id = "d"
        var command = entry("open Cryden")
        command.id = "c"
        command.outcome = .command
        command.timestamp = Date(timeIntervalSince1970: 2_000_000)
        try store.append(dictation, today: "2026-07-10")
        try store.append(command, today: "2026-07-10")
        let model = model(store)
        var asked: [String] = []
        model.mishearingHints = { entry in
            asked.append(entry.heard)
            return [.init(phrase: "Cryden", term: "Kryten", origin: .global)]
        }
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }

        model.selection = model.groups.flatMap(\.rows).first { $0.entry.id == "d" }?.id
        await model.hintsTask?.value
        #expect(model.hints == [.init(phrase: "Cryden", term: "Kryten", origin: .global)])

        model.selection = model.groups.flatMap(\.rows).first { $0.entry.id == "c" }?.id
        await model.hintsTask?.value
        #expect(model.hints.isEmpty)
        #expect(asked == ["Cryden, make a pane"])
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

    @Test func copyReplyCopiesWhatWasReadAloud() async throws {
        let reply = AgentHistoryFacts.spokenReplyEntry(
            id: "r1", mode: "Coding agent",
            reply: .init(at: Date(timeIntervalSince1970: 1_700_000_000), conversation: "docs", text: "docs: Done."))
        let model = try await selectingOnly(reply, corrections: Corrections())
        var copied: String?
        model.copyText = { copied = $0 }
        model.copyReply()
        #expect(copied == "docs: Done.")
    }

    private func spokenReply() -> HistoryEntry {
        AgentHistoryFacts.spokenReplyEntry(
            id: "r1", mode: "Coding agent",
            reply: .init(at: Date(timeIntervalSince1970: 1_700_000_000), conversation: "docs", text: "docs: Done.", voice: "natural"))
    }

    @Test func aReplyCanBeReadAgainWithTheMacOSVoiceAndStopped() async throws {
        let model = try await selectingOnly(spokenReply(), corrections: Corrections())
        var read: [String] = []
        var ended: (() -> Void)?
        var stops = 0
        model.readWithMacOSVoice = { text, onEnd in read.append(text); ended = onEnd; return .started }
        model.stopHistorySpeech = { stops += 1 }
        model.readReplyWithMacOSVoice()
        #expect(read == ["docs: Done."])
        #expect(model.speaking == .macOSVoice)
        #expect(model.statusMessage == nil)
        ended?()
        #expect(model.speaking == nil)
        model.readReplyWithMacOSVoice()
        model.stopSpeaking()
        #expect(stops == 1)
        #expect(model.speaking == nil)
    }

    @Test func nothingPlaysWhileDictatingAndTheStatusSaysWhy() async throws {
        let model = try await selectingOnly(spokenReply(), corrections: Corrections())
        model.readWithMacOSVoice = { _, _ in .dictating }
        model.readReplyWithMacOSVoice()
        #expect(model.speaking == nil)
        #expect(model.statusMessage?.contains("while you\u{2019}re dictating") == true)
    }

    private func holding(_ playback: SpokenAttempt.Playback = .finished) -> SpokenAttempt {
        var attempt = SpokenAttempt(id: "a1", at: Date(), text: "docs: Done.", voice: "af_heart")
        attempt.audio = Data("RIFF-original".utf8)
        attempt.playback = playback
        return attempt
    }

    @Test func theHeldAudioCanBePlayedAgainAndStopped() async throws {
        let model = try await selectingOnly(spokenReply(), corrections: Corrections())
        let attempt = holding()
        model.spokenAudio = { _ in attempt }
        var played: [Data] = []
        var ended: (() -> Void)?
        var stops = 0
        model.playHeldAudio = { data, onEnd in played.append(data); ended = onEnd; return .started }
        model.stopHistorySpeech = { stops += 1 }
        model.playSpokenAudio()
        #expect(played == [Data("RIFF-original".utf8)])
        #expect(model.speaking == .audio)
        ended?()
        #expect(model.speaking == nil)
        model.playSpokenAudio()
        model.stopSpeaking()
        #expect(stops == 1)
        #expect(model.speaking == nil)
        #expect(model.spokenAudio?("r1")?.playback == .finished)
    }

    @Test func aPlayerThatRefusesLeavesNoStopButtonAndSaysSo() async throws {
        let model = try await selectingOnly(spokenReply(), corrections: Corrections())
        model.spokenAudio = { _ in self.holding() }
        model.playHeldAudio = { _, onEnd in onEnd(); return .failed }
        model.playSpokenAudio()
        #expect(model.speaking == nil)
        #expect(model.statusMessage == "Couldn\u{2019}t play the generated audio.")
    }

    @Test func theHeldAudioCannotBePlayedWhileTheReplyIsStillBeingReadAloud() async throws {
        let model = try await selectingOnly(spokenReply(), corrections: Corrections())
        model.spokenAudio = { _ in self.holding(.playing) }
        #expect(!model.canPlaySpokenAudio)
        model.spokenAudio = { _ in self.holding(.finished) }
        #expect(model.canPlaySpokenAudio)
    }

    @Test func closingHistoryStopsWhatItIsPlaying() async throws {
        let model = try await selectingOnly(spokenReply(), corrections: Corrections())
        model.spokenAudio = { _ in self.holding() }
        var stops = 0
        model.playHeldAudio = { _, _ in .started }
        model.stopHistorySpeech = { stops += 1 }
        model.playSpokenAudio()
        model.releaseForClose()
        #expect(stops == 1)
        #expect(model.speaking == nil)
    }

    @Test func anEntryNoLongerInHistoryIsNotWaitedForAndTheUserIsTold() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var kept = entry("kept dictation")
        kept.id = "kept"
        try store.append(kept, today: "2026-07-10")
        let model = model(store)
        model.show(entry: "deleted")
        for _ in 0..<80 where model.statusMessage == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(model.statusMessage == "That reply is no longer in History.")
        model.reload()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(model.selected?.id == "kept")
    }

    @Test func historyOpensAtAChosenEntry() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var older = spokenReply()
        older.id = "older"
        older.timestamp = Date(timeIntervalSince1970: 1_600_000_000)
        try store.append(older, today: "2026-07-09")
        var newer = entry("newest dictation")
        newer.id = "newer"
        try store.append(newer, today: "2026-07-10")
        let model = model(store)
        model.show(entry: "older")
        for _ in 0..<80 where model.selected?.id != "older" { try await Task.sleep(for: .milliseconds(25)) }
        #expect(model.selected?.id == "older")
    }

    @Test func savingSpokenAudioWritesTheOriginalAudioAndAReportWhereTheUserChose() async throws {
        let model = try await selectingOnly(spokenReply(), corrections: Corrections())
        var attempt = SpokenAttempt(id: "a1", at: Date(timeIntervalSince1970: 1_700_000_000), text: "docs: Done.", voice: "af_heart")
        attempt.audio = Data("RIFF-original".utf8)
        attempt.reader = .natural
        var asked: [String] = []
        model.spokenAudio = { $0 == "r1" ? attempt : nil }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        var revealed: [URL] = []
        model.chooseSpokenAudioFolder = { asked.append("asked"); return destination }
        model.revealInFinder = { revealed.append($0) }
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Spoken reply \(local.string(from: attempt.at))"
        #expect(model.selectedSpokenAudio?.id == "a1")
        model.saveSpokenAudio()
        #expect(asked.count == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        #expect(files == ["\(name) report.txt", "\(name).wav"])
        let wav = destination.appendingPathComponent("\(name).wav")
        #expect(try Data(contentsOf: wav) == Data("RIFF-original".utf8))
        let report = try String(contentsOf: destination.appendingPathComponent("\(name) report.txt"), encoding: .utf8)
        #expect(report.contains("Text read: docs: Done."))
        #expect(revealed.map(\.lastPathComponent) == ["\(name).wav"])
        model.saveSpokenAudio()
        #expect(revealed.map(\.lastPathComponent) == ["\(name).wav", "\(name) 2.wav"])
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("\(name) 2 report.txt").path))
    }

    @Test func aSaveThatFailsHalfwayLeavesNothingBehindAndCanBeRetried() async throws {
        let model = try await selectingOnly(spokenReply(), corrections: Corrections())
        var attempt = SpokenAttempt(id: "a1", at: Date(timeIntervalSince1970: 1_700_000_000), text: "docs: Done.", voice: "af_heart")
        attempt.audio = Data("RIFF".utf8)
        model.spokenAudio = { _ in attempt }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        model.chooseSpokenAudioFolder = { destination }
        model.revealInFinder = { _ in }
        model.writeFile = { data, url in
            if url.lastPathComponent.hasSuffix("report.txt") { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .withoutOverwriting)
        }
        model.saveSpokenAudio()
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(model.statusMessage == "Couldn\u{2019}t save the generated audio.")
        model.writeFile = { try $0.write(to: $1, options: .withoutOverwriting) }
        model.saveSpokenAudio()
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 2)
    }

    @Test func noSpokenAudioIsOfferedOnceItIsGone() async throws {
        let model = try await selectingOnly(spokenReply(), corrections: Corrections())
        model.spokenAudio = { _ in nil }
        #expect(model.selectedSpokenAudio == nil)
        var withoutAudio = SpokenAttempt(id: "a1", at: Date(), text: "docs: Done.", voice: "af_heart")
        withoutAudio.reader = .macOS
        model.spokenAudio = { _ in withoutAudio }
        #expect(model.selectedSpokenAudio == nil)
    }

    @Test func deletingAReplyForgetsItsSpokenAudio() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.append(spokenReply())
        let model = model(store)
        model.reload()
        for _ in 0..<80 where !model.hasEntries { try await Task.sleep(for: .milliseconds(25)) }
        model.selection = model.groups.first?.rows.first?.id
        var forgotten: [[String]] = []
        model.forgetSpokenAudio = { forgotten.append($0) }
        model.deleteSelected()
        #expect(forgotten == [["r1"]])
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
