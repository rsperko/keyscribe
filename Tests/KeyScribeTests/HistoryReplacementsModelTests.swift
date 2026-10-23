import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

private final class HistorySource: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HistorySnapshot.Item] = []
    private var fingerprint = HistorySnapshot.Fingerprint(files: ["d.jsonl": 1])
    private var blocking = false
    private var sawCancellation = false
    let workerBlocked = Signal("HistorySource.workerBlocked")

    var current: HistorySnapshot {
        if lock.withLock({ blocking }) {
            workerBlocked.fire()
            let deadline = Date().addingTimeInterval(10)
            while !Task.isCancelled, Date() < deadline { usleep(1000) }
            lock.withLock { sawCancellation = Task.isCancelled }
        }
        return lock.withLock { HistorySnapshot(items: items, unreadableLines: 0, fingerprint: fingerprint) }
    }

    private var override: HistorySnapshot.Fingerprint?
    var currentFingerprint: HistorySnapshot.Fingerprint { lock.withLock { override ?? fingerprint } }
    func overrideFingerprint(_ value: HistorySnapshot.Fingerprint) { lock.withLock { override = value } }

    func blockUntilCancelled() { lock.withLock { blocking = true } }
    var workerSawCancellation: Bool { lock.withLock { sawCancellation } }

    func append(_ entry: HistoryEntry) {
        lock.withLock {
            items.append(.init(reference: .init(dayFile: "d.jsonl", line: items.count), entry: entry))
            fingerprint = HistorySnapshot.Fingerprint(files: ["d.jsonl": items.count])
        }
    }
}

private final class Work: @unchecked Sendable {
    struct Hold {
        let blocked: Signal
        let release = DispatchSemaphore(value: 0)
    }

    private let lock = NSLock()
    private var discoveryCount = 0
    private var previewCount = 0
    private var discoveryHold: Hold?
    private var previewHold: Hold?

    var discoveries: Int { lock.withLock { discoveryCount } }
    var previews: Int { lock.withLock { previewCount } }

    func holdNextDiscovery() -> Hold {
        let hold = Hold(blocked: Signal("Work.discoveryBlocked"))
        lock.withLock { discoveryHold = hold }
        return hold
    }

    func holdNextPreview() -> Hold {
        let hold = Hold(blocked: Signal("Work.previewBlocked"))
        lock.withLock { previewHold = hold }
        return hold
    }

    func discovering() {
        let hold = lock.withLock { () -> Hold? in
            discoveryCount += 1
            defer { discoveryHold = nil }
            return discoveryHold
        }
        pause(hold)
    }

    func previewing() {
        let hold = lock.withLock { () -> Hold? in
            previewCount += 1
            defer { previewHold = nil }
            return previewHold
        }
        pause(hold)
    }

    private func pause(_ hold: Hold?) {
        guard let hold else { return }
        hold.blocked.fire()
        _ = hold.release.wait(timeout: .now() + 10)
    }
}

@MainActor
private final class Harness {
    let history = HistorySource()
    let work = Work()
    var global = ReplacementsSet(rules: [])
    var words = ["Yugabyte"]
    var modes: [Mode] = {
        var notes = Mode(id: "notes", name: "Notes")
        notes.dictionary.words = ["Yugabyte"]
        return [notes]
    }()
    var saved: [(ReplacementPreview.Destination, [ReplacementsSet.Rule], [ReplacementsSet.Rule], String?)] = []
    var outcome = ConfigRepository.BatchOutcome.saved
    var savedCount: Int?
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func add(_ heard: String, mode: String = "Notes", engine: String = "Parakeet Ultra") {
        var entry = HistoryEntry(
            timestamp: now.addingTimeInterval(-3600), modeName: mode, heard: heard, result: heard,
            outcome: .inserted, cloudInvolved: false, redaction: false, contextCategories: [])
        entry.engine = engine
        history.append(entry)
    }

    func model(destination: ReplacementPreview.Destination = .global, name: String = "Global") -> HistoryReplacementsModel {
        let history = history
        let work = work
        return HistoryReplacementsModel(
            word: "Yugabyte", destination: destination, destinationName: name, historyEnabled: true,
            dependencies: .init(
                loadSnapshot: { history.current },
                fingerprint: { history.currentFingerprint },
                vocabulary: { .init(global: self.global, globalWords: self.words, modes: self.modes) },
                save: { destination, expected, proposed, word in
                    self.saved.append((destination, expected, proposed, word))
                    return self.outcome
                },
                now: { self.now },
                discover: { target, texts, dictionary in
                    work.discovering()
                    return AliasDiscovery.find(target: target, in: texts, dictionary: dictionary)
                },
                makePreview: { request in
                    work.previewing()
                    return try request.make()
                }),
            onSaved: { self.savedCount = $0 })
    }
}

@MainActor
struct HistoryReplacementsModelTests {
    @Test func openingSearchesAllSavedHistoryAndSpeechModelsAutomatically() async {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.add("Restart UGBte.", engine: "Whisper")
        let model = h.model()
        await model.refresh()
        #expect(model.scope == HistorySearchScope(period: .all, model: .all))
        #expect(model.searchedCount == 2)
        #expect(model.findings.first?.occurrences.count == 2)
        #expect(model.selected.isEmpty)
        #expect(!model.canAdd)
    }

    @Test func findsOpenPhrasesAndSetsAsideOnesAlreadyCorrected() async {
        let h = Harness()
        h.add("We store the orders in Ugabyte.")
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        #expect(model.findings.map(\.phrase) == ["UGBte"])
        #expect(model.handledCount == 1)
    }

    @Test func uncheckedSuggestionsShowDiscoveryContextWithoutReplayingHistory() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.add("Restart UGBte tonight.")
        let model = h.model()
        await model.refresh()
        let id = try #require(model.phrases.first?.id)
        #expect(model.discoveryExcerpts(for: id).map(\.match) == ["UGBte", "UGBte"])
        #expect(model.discoveryExcerpts(for: id).first?.after == " cluster is down.")
        #expect(h.work.previews == 0)
        model.updatePhrase(id, heard: "UGBte cluster")
        #expect(model.discoveryExcerpts(for: id).isEmpty)
    }

    @Test func editingUseInsteadReusesDiscoveryAndReplaysHistoryOncePerPreview() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.add("The database nodes restarted.")
        let model = h.model()
        await model.refresh()
        let found = try #require(model.phrases.first?.id)
        model.updatePhrase(model.addPhrase(), heard: "database")
        model.updatePhrase(model.addPhrase(), heard: "nodes")
        await model.refresh()
        #expect(h.work.discoveries == 1)
        #expect(h.work.previews == 1)
        for text in ["Yugabyte DB", "YugabyteDB", "Yugabyte"] {
            model.replacement = text
            await model.refresh()
        }
        #expect(h.work.discoveries == 1)
        #expect(h.work.previews == 4)
        model.updatePhrase(found, heard: "cluster")
        await model.refresh()
        #expect(h.work.previews == 4)
        #expect(model.canAdd)
    }

    @Test func selectedRowsShowTheirShareOfTheOneCombinedPreview() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.add("The database is slow.")
        let model = h.model()
        await model.refresh()
        let found = try #require(model.phrases.first?.id)
        model.toggle(found)
        let manual = model.addPhrase()
        model.updatePhrase(manual, heard: "database")
        await model.refresh()
        #expect(h.work.previews == 1)
        #expect(model.effects(for: found).map(\.effect.proposedText) == ["The Yugabyte cluster is down."])
        #expect(model.effects(for: manual).map(\.effect.proposedText) == ["The Yugabyte is slow."])
        #expect(model.preview?.changeCount == 2)
        #expect(model.showsCombinedPreview)
    }

    @Test func aSelectedRowWhoseChangesMergedPointsToTheCombinedPreview() async throws {
        let h = Harness()
        h.add("The database nodes are slow.")
        let model = h.model()
        await model.refresh()
        let first = model.addPhrase()
        model.updatePhrase(first, heard: "database")
        let second = model.addPhrase()
        model.updatePhrase(second, heard: "nodes")
        await model.refresh()
        #expect(model.unattributedChangeCount > 0)
        #expect(model.effects(for: first).isEmpty)
        #expect(model.isOnlyInCombinedPreview(first))
        #expect(model.isOnlyInCombinedPreview(second))
        #expect(model.showsCombinedPreview)
    }

    @Test func aRowWithItsOwnChangesOrNoChangesIsNotSentToTheCombinedPreview() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        let found = try #require(model.phrases.first?.id)
        model.toggle(found)
        let manual = model.addPhrase()
        model.updatePhrase(manual, heard: "nowhere")
        await model.refresh()
        #expect(!model.isOnlyInCombinedPreview(found))
        #expect(!model.isOnlyInCombinedPreview(manual))
    }

    @Test func selectionPreviewsAndSavesWithoutASeparateReviewStep() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.global = ReplacementsSet(rules: [.init(heard: "slash resume", replace: "/resume", regex: false)])
        let model = h.model()
        await model.refresh()
        let phrase = try #require(model.phrases.first)
        model.toggle(phrase.id)
        #expect(!model.canAdd)
        await model.refresh()
        let preview = try #require(model.preview)
        #expect(model.effects(for: phrase.id).first?.effect.proposedText == "The Yugabyte cluster is down.")
        #expect(model.canAdd)
        await model.add()
        let save = try #require(h.saved.first)
        #expect(save.1 == h.global.rules)
        #expect(save.2 == preview.proposedRules)
        #expect(save.3 == "Yugabyte")
        #expect(h.savedCount == 1)
    }

    @Test func changingUseInsteadRebuildsPreviewsAndPreservesTheDictionaryWordAndSelection() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        let id = try #require(model.phrases.first?.id)
        model.toggle(id)
        await model.refresh()
        model.replacement = "YugaByte database "
        #expect(model.preview == nil)
        #expect(!model.canAdd)
        await model.refresh()
        #expect(model.selected == [id])
        #expect(model.effects(for: id).first?.effect.proposedText == "The YugaByte database  cluster is down.")
        await model.add()
        #expect(h.saved.first?.2.last?.replace == "YugaByte database ")
        #expect(h.saved.first?.3 == "Yugabyte")
        #expect(h.words == ["Yugabyte"])
    }

    @Test(arguments: [" ", "  ", "\t", "\n", " \t\r\n"])
    func whitespaceUseInsteadWarnsButSavesExactlyAsAuthored(_ value: String) async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        #expect(model.replacementAdvisory == nil)
        model.toggle(try #require(model.phrases.first?.id))
        model.replacement = value
        await model.refresh()
        #expect(model.replacementAdvisory == VocabularyDraftAnalysis.invisibleOnlyDescription(value))
        #expect(model.replacementAdvisory != nil)
        #expect(model.replacementIssue == nil)
        #expect(model.canAdd)
        await model.add()
        #expect(h.saved.first?.2.last?.replace == value)
    }

    @Test func editingAHeardPhraseRebuildsItsActualExamples() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        let id = try #require(model.phrases.first?.id)
        model.toggle(id)
        model.updatePhrase(id, heard: "cluster")
        await model.refresh()
        #expect(model.effects(for: id).first?.effect.proposedText == "The UGBte Yugabyte is down.")
        await model.add()
        #expect(h.saved.first?.2.last?.heard == "cluster")
    }

    @Test func manualPhrasesCanBeAddedWhenDiscoveryFindsNothing() async throws {
        let h = Harness()
        h.add("The database is down.")
        let model = h.model()
        await model.refresh()
        #expect(model.phrases.isEmpty)
        let id = model.addPhrase()
        model.updatePhrase(id, heard: "  database  ")
        await model.refresh()
        #expect(model.preview?.changeCount == 1)
        #expect(model.canAdd)
        await model.add()
        #expect(h.saved.first?.2.last?.heard == "database")
    }

    @Test func aBlankManualRowIsAnInactiveDraft() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        let found = try #require(model.phrases.first?.id)
        model.toggle(found)
        await model.refresh()
        #expect(model.canAdd)
        let previews = h.work.previews
        let blank = model.addPhrase()
        #expect(model.canAdd)
        #expect(!model.isChecked(blank))
        #expect(model.phraseIssue(blank) == nil)
        #expect(model.activePhrases.map(\.id) == [found])
        await model.refresh()
        #expect(h.work.previews == previews)
        await model.add()
        #expect(h.saved.first?.2.map(\.heard) == ["UGBte"])
    }

    @Test func typingAManualPhraseIncludesItUntilTheUserUnchecksIt() async {
        let h = Harness()
        let model = h.model()
        await model.refresh()
        let id = model.addPhrase()
        #expect(!model.isChecked(id))
        model.updatePhrase(id, heard: "database")
        #expect(model.isChecked(id))
        model.toggle(id)
        model.updatePhrase(id, heard: "databases")
        #expect(!model.isChecked(id))
        model.updatePhrase(id, heard: "")
        model.updatePhrase(id, heard: "db")
        #expect(!model.isChecked(id))
    }

    @Test func theFooterSaysWhatIsNeededBeforeAdding() async {
        let h = Harness()
        let model = h.model()
        await model.refresh()
        #expect(model.addGuidance == "Select phrases to add.")
        let id = model.addPhrase()
        #expect(model.addGuidance == "Enter a heard phrase, or select a suggestion.")
        model.updatePhrase(id, heard: "bad\nphrase")
        #expect(model.addGuidance == "Fix the phrase marked in red before adding.")
    }

    @Test func uncheckingAPhraseRemovesItFromTheSave() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        let id = try #require(model.phrases.first?.id)
        model.toggle(id)
        await model.refresh()
        model.toggle(id)
        #expect(model.preview == nil)
        await model.refresh()
        await model.add()
        #expect(h.saved.isEmpty)
    }

    @Test func conflictsAreVisibleBesideUnselectedPhrasesAndAreNeverOverwritten() async throws {
        let h = Harness()
        h.add("The database is down.")
        h.global = .init(rules: [.init(heard: "database", replace: "storage", regex: false)])
        let model = h.model()
        await model.refresh()
        let id = model.addPhrase()
        model.updatePhrase(id, heard: "database")
        await model.refresh()
        #expect(model.status(for: id) == .conflicts(currentOutput: "storage"))
        model.toggle(id)
        await model.refresh()
        #expect(model.status(for: id) == .conflicts(currentOutput: "storage"))
        #expect(!model.canAdd)
        await model.add()
        #expect(h.saved.isEmpty)
    }

    @Test func invalidDraftsCannotBeSaved() async {
        let h = Harness()
        let model = h.model()
        await model.refresh()
        let id = model.addPhrase()
        model.updatePhrase(id, heard: "bad\nphrase")
        await model.refresh()
        #expect(model.phraseIssue(id) != nil)
        #expect(!model.canAdd)
        model.updatePhrase(id, heard: "database")
        model.replacement = String(repeating: "x", count: ReplacementAuthoring.maxCharacters + 1)
        await model.refresh()
        #expect(model.replacementIssue != nil)
        #expect(!model.canAdd)
        await model.add()
        #expect(h.saved.isEmpty)
    }

    @Test func duplicateDraftsCannotBeSavedAsSeparateRules() async {
        let h = Harness()
        let model = h.model()
        await model.refresh()
        let first = model.addPhrase()
        model.updatePhrase(first, heard: "database")
        let second = model.addPhrase()
        model.updatePhrase(second, heard: "DATABASE")
        await model.refresh()
        #expect(model.phraseIssue(second) != nil)
        #expect(!model.canAdd)
    }

    @Test func focusIsRequestedOnlyByAnExplicitAddOrEdit() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        #expect(model.focusRequest == nil)
        let found = try #require(model.phrases.first?.id)
        model.toggleEditing(found)
        #expect(model.editing.contains(found))
        #expect(model.focusRequest == found)
        model.focusHandled(found)
        #expect(model.focusRequest == nil)
        model.searchAgain()
        await model.refresh()
        #expect(model.focusRequest == nil)
        #expect(model.editing.contains(found))
        let manual = model.addPhrase()
        #expect(model.focusRequest == manual)
        model.focusHandled(found)
        #expect(model.focusRequest == manual)
        model.toggleEditing(found)
        #expect(!model.editing.contains(found))
        #expect(model.focusRequest == manual)
    }

    @Test func changingFiltersSearchesAgainOnTheSameSurface() async {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        model.scope.model = .named("Whisper")
        #expect(model.preview == nil)
        await model.refresh()
        #expect(model.phrases.isEmpty)
        #expect(model.searchedCount == 0)
        model.scope.model = .all
        await model.refresh()
        #expect(model.phrases.count == 1)
    }

    @Test func changingFiltersWhileASearchRunsPublishesOnlyTheNewSearch() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.add("Restart UGBte.", engine: "Whisper")
        let model = h.model()
        let hold = h.work.holdNextDiscovery()
        let first = Task { await model.refresh() }
        await hold.blocked.wait()
        model.scope.model = .named("Whisper")
        await model.refresh()
        #expect(model.searchedCount == 1)
        hold.release.signal()
        await first.value
        #expect(h.work.discoveries == 2)
        #expect(model.searchedCount == 1)
        #expect(model.findings.first?.occurrences.count == 1)
        #expect(!model.isWorking)
    }

    @Test func lateWorkCannotRestoreAnObsoletePreviewOrEnableAdd() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        model.toggle(try #require(model.phrases.first?.id))
        let hold = h.work.holdNextPreview()
        let stale = Task { await model.refresh() }
        await hold.blocked.wait()
        model.replacement = "YugabyteDB"
        hold.release.signal()
        await stale.value
        #expect(model.preview == nil)
        #expect(!model.canAdd)
        await model.refresh()
        #expect(model.preview?.replacement == "YugabyteDB")
        #expect(model.canAdd)
    }

    @Test func refreshingSearchPreservesChosenEditsAndManualPhrases() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        let found = try #require(model.phrases.first?.id)
        model.toggle(found)
        model.updatePhrase(found, heard: "cluster")
        let manual = model.addPhrase()
        model.updatePhrase(manual, heard: "database")
        model.scope.model = .named("Whisper")
        await model.refresh()
        #expect(model.searchedCount == 0)
        #expect(model.phrases.map(\.heard) == ["cluster", "database"])
        #expect(model.selected == [found, manual])
        #expect(model.preview?.additionalMatches == 1)
        #expect(model.canAdd)
    }

    @Test func aModeLaunchSearchesAcrossModesAndSavesOnlyToItsDestination() async throws {
        let h = Harness()
        h.add("UGBte in notes.")
        h.add("UGBte in code.", mode: "Code")
        let model = h.model(destination: .mode("notes"), name: "Notes")
        await model.refresh()
        #expect(model.searchedCount == 2)
        let id = try #require(model.phrases.first?.id)
        model.toggle(id)
        await model.refresh()
        await model.add()
        #expect(h.saved.map(\.0) == [.mode("notes")])
    }

    @Test func historyThatChangedSinceTheSearchIsNotSavedAndAsksForASearchRefresh() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        model.toggle(try #require(model.phrases.first?.id))
        await model.refresh()
        h.history.overrideFingerprint(HistorySnapshot.Fingerprint(files: ["d.jsonl": 99]))
        await model.add()
        #expect(h.saved.isEmpty)
        #expect(model.problem?.recovery == .refreshSearch)
        #expect(!model.canAdd)
    }

    @Test func refreshingAfterHistoryChangedIncludesLatestDictationsAndCanSave() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        model.toggle(try #require(model.phrases.first?.id))
        await model.refresh()
        h.add("Restart the UGBte nodes.")
        await model.add()
        #expect(h.saved.isEmpty)
        model.searchAgain()
        await model.refresh()
        #expect(model.searchedCount == 2)
        #expect(model.selected.count == 1)
        await model.add()
        #expect(h.savedCount == 1)
    }

    @Test func aDictationIsAlreadyCorrectedOnlyByTheVocabularyItsModeUses() async {
        let h = Harness()
        h.modes[0].dictionary = .init(includeGlobal: false, words: [])
        h.add("We store the orders in Ugabyte.")
        h.add("The Ugabyte cluster is slow.", mode: "Code")
        let model = h.model()
        await model.refresh()
        #expect(model.findings.map(\.phrase) == ["Ugabyte"])
        #expect(model.handledCount == 0)
    }

    @Test func changedVocabularyAtAddRebuildsThePreviewAndWaitsForAnotherAdd() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model(destination: .mode("notes"), name: "Notes")
        await model.refresh()
        let id = try #require(model.phrases.first?.id)
        model.toggle(id)
        await model.refresh()
        h.global = ReplacementsSet(rules: [.init(heard: "UGBte", replace: "Uganda", regex: false)])
        await model.add()
        #expect(h.saved.isEmpty)
        #expect(h.work.discoveries == 1)
        #expect(model.selected == [id])
        #expect(model.status(for: id) == .overridesGlobal(globalOutput: "Uganda"))
        #expect(model.notice != nil)
        #expect(model.problem == nil)
        #expect(model.canAdd)
        await model.add()
        #expect(h.savedCount == 1)
    }

    @Test func aStaleSaveRebuildsThePreviewAndKeepsTheDraft() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.outcome = .stale(.rulesChanged)
        let model = h.model()
        await model.refresh()
        let id = try #require(model.phrases.first?.id)
        model.toggle(id)
        await model.refresh()
        await model.add()
        #expect(h.savedCount == nil)
        #expect(model.selected == [id])
        #expect(model.notice != nil)
        #expect(model.canAdd)
        h.outcome = .saved
        await model.add()
        #expect(h.savedCount == 1)
    }

    @Test func aRemovedWordSavesNothingAndOffersNoRefresh() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.outcome = .stale(.wordRemoved)
        let model = h.model()
        await model.refresh()
        model.toggle(try #require(model.phrases.first?.id))
        await model.refresh()
        await model.add()
        #expect(h.savedCount == nil)
        #expect(model.problem?.message.contains("no longer in Global") == true)
        #expect(model.problem?.recovery == nil)
        #expect(!model.canAdd)
    }

    @Test func aWordRemovedBeforeAddIsReportedOnTheFirstClick() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.refresh()
        model.toggle(try #require(model.phrases.first?.id))
        await model.refresh()
        h.words = []
        await model.add()
        #expect(h.saved.isEmpty)
        #expect(model.notice == nil)
        #expect(model.problem?.message.contains("no longer in Global") == true)
        #expect(model.problem?.recovery == nil)
        #expect(!model.canAdd)
    }

    @Test func aWordRemovedFromTheModeBeforeAddIsReportedOnTheFirstClick() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model(destination: .mode("notes"), name: "Notes")
        await model.refresh()
        model.toggle(try #require(model.phrases.first?.id))
        await model.refresh()
        h.modes[0].dictionary.words = []
        await model.add()
        #expect(h.saved.isEmpty)
        #expect(model.notice == nil)
        #expect(model.problem?.message.contains("no longer in Notes") == true)
    }

    @Test func aModeRemovedBeforeAddIsReportedOnTheFirstClick() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model(destination: .mode("notes"), name: "Notes")
        await model.refresh()
        model.toggle(try #require(model.phrases.first?.id))
        await model.refresh()
        h.modes = []
        await model.add()
        #expect(h.saved.isEmpty)
        #expect(model.notice == nil)
        #expect(model.problem?.message == "Notes no longer exists. Nothing was added.")
        #expect(model.problem?.recovery == nil)
    }

    @Test func cancellingStopsTheBackgroundWork() async {
        let h = Harness()
        h.history.blockUntilCancelled()
        let model = h.model()
        let loading = Task { await model.refresh() }
        await h.history.workerBlocked.wait()
        loading.cancel()
        await loading.value
        #expect(h.history.workerSawCancellation)
    }

    @Test func closingDiscardsLateBackgroundResults() async {
        let h = Harness()
        h.history.blockUntilCancelled()
        let model = h.model()
        let loading = Task { await model.refresh() }
        await h.history.workerBlocked.wait()
        model.close()
        loading.cancel()
        await loading.value
        #expect(model.snapshot == nil)
        #expect(model.phrases.isEmpty)
        #expect(!model.isWorking)
    }

    @Test func excerptsKeepEightWordsEachSide() {
        let text = "one two three four five six seven eight nine UGBte a b c d e f g h i j"
        let range = text.range(of: "UGBte")!
        let excerpt = HistoryReplacementsModel.excerpt(text, range: range)
        #expect(excerpt.before == "…two three four five six seven eight nine ")
        #expect(excerpt.match == "UGBte")
        #expect(excerpt.after == " a b c d e f g h…")
    }
}
