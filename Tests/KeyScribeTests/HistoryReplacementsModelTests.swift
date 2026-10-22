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

@MainActor
private final class Harness {
    let history = HistorySource()
    var global = ReplacementsSet(rules: [])
    var words = ["Yugabyte"]
    var modes = [Mode(id: "notes", name: "Notes")]
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
                now: { self.now }),
            onSaved: { self.savedCount = $0 })
    }
}

@MainActor
struct HistoryReplacementsModelTests {
    @Test func findsOpenPhrasesAndSetsAsideOnesAlreadyCorrected() async throws {
        let h = Harness()
        h.add("We store the orders in Ugabyte.")
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.load()
        #expect(model.scope == HistorySearchScope(period: .days(30), model: .named("Parakeet Ultra")))
        await model.find()
        #expect(model.step == .choose)
        #expect(model.findings.map(\.phrase) == ["UGBte"])
        #expect(model.handledCount == 1)
        #expect(model.selected.isEmpty)
    }

    @Test func aModeLaunchSearchesAcrossModesAndSavesOnlyToItsDestination() async throws {
        let h = Harness()
        h.add("UGBte in notes.")
        h.add("UGBte in code.", mode: "Code")
        let model = h.model(destination: .mode("notes"), name: "Notes")
        await model.load()
        await model.find()
        #expect(model.searchedCount == 2)
        let finding = try #require(model.findings.first)
        #expect(finding.occurrences.count == 2)
        model.toggle(finding)
        await model.review()
        await model.add()
        #expect(h.saved.map(\.0) == [.mode("notes")])
    }

    @Test func addsExactlyTheReviewedRules() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.global = ReplacementsSet(rules: [.init(heard: "slash resume", replace: "/resume", regex: false)])
        let model = h.model()
        await model.load()
        await model.find()
        model.toggle(try #require(model.findings.first))
        await model.review()
        let preview = try #require(model.preview)
        #expect(model.step == .review)
        await model.add()
        let save = try #require(h.saved.first)
        #expect(save.0 == .global)
        #expect(save.1 == h.global.rules)
        #expect(save.2 == preview.proposedRules)
        #expect(save.3 == "Yugabyte")
        #expect(h.savedCount == 1)
    }

    @Test func changingTheChoicesInvalidatesTheReview() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.load()
        await model.find()
        let finding = try #require(model.findings.first)
        model.toggle(finding)
        await model.review()
        model.toggle(finding)
        #expect(model.preview == nil)
    }

    @Test func changingTheSearchSendsYouBackToFind() async {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.load()
        await model.find()
        model.scope.period = .all
        #expect(model.step == .find)
        #expect(model.findings.isEmpty)
    }

    @Test func historyThatChangedSinceTheSearchIsNotSaved() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.load()
        await model.find()
        model.toggle(try #require(model.findings.first))
        await model.review()
        h.history.overrideFingerprint(HistorySnapshot.Fingerprint(files: ["d.jsonl": 99]))
        await model.add()
        #expect(h.saved.isEmpty)
        #expect(model.issue != nil)
        #expect(model.preview == nil)
    }

    @Test func findingAgainAfterHistoryChangedSearchesTheLatestDictationsAndCanSave() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.load()
        await model.find()
        model.toggle(try #require(model.findings.first))
        await model.review()
        h.add("Restart the UGBte nodes.")
        await model.add()
        #expect(h.saved.isEmpty)
        await model.find()
        #expect(model.searchedCount == 2)
        let finding = try #require(model.findings.first)
        #expect(finding.occurrences.count == 2)
        model.toggle(finding)
        await model.review()
        await model.add()
        #expect(h.saved.count == 1)
        #expect(h.savedCount == 1)
    }

    @Test func changingTheSearchWhileTheFirstSearchRunsDiscardsItsResults() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.load()
        let search = Task { await model.find() }
        await Task.yield()
        try #require(model.isWorking)
        model.scope.period = .all
        await search.value
        #expect(model.step == .find)
        #expect(model.findings.isEmpty)
        #expect(!model.isWorking)
    }

    @Test func searchingAllAvailableHistoryFromResultsRunsTheWiderSearch() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model()
        await model.load()
        model.scope.model = .named("Whisper")
        await model.find()
        #expect(model.findings.isEmpty)
        await model.searchAllAvailableHistory().value
        #expect(model.scope.period == .all)
        #expect(model.step == .choose)
        #expect(!model.isWorking)
    }

    @Test func aDictationIsAlreadyCorrectedOnlyByTheVocabularyItsModeUses() async throws {
        let h = Harness()
        h.modes[0].dictionary = .init(includeGlobal: false, words: [])
        h.add("We store the orders in Ugabyte.")
        h.add("The Ugabyte cluster is slow.", mode: "Code")
        let model = h.model()
        await model.load()
        await model.find()
        #expect(model.findings.map(\.phrase) == ["Ugabyte"])
        #expect(model.handledCount == 0)
    }

    @Test func aChangeToInheritedGlobalRulesAfterReviewingAModeBlocksAdd() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        let model = h.model(destination: .mode("notes"), name: "Notes")
        await model.load()
        await model.find()
        model.toggle(try #require(model.findings.first))
        await model.review()
        h.global = ReplacementsSet(rules: [.init(heard: "UGBte", replace: "Uganda", regex: false)])
        await model.add()
        #expect(h.saved.isEmpty)
        #expect(model.preview == nil)
        #expect(model.issue?.contains("Review again") == true)
    }

    @Test func cancellingStopsTheBackgroundWork() async {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.history.blockUntilCancelled()
        let model = h.model()
        let loading = Task { await model.load() }
        await h.history.workerBlocked.wait()
        loading.cancel()
        await loading.value
        #expect(h.history.workerSawCancellation)
    }

    @Test func aStaleSaveAsksForAFreshReview() async throws {
        let h = Harness()
        h.add("The UGBte cluster is down.")
        h.outcome = .stale(.rulesChanged)
        let model = h.model()
        await model.load()
        await model.find()
        model.toggle(try #require(model.findings.first))
        await model.review()
        await model.add()
        #expect(h.savedCount == nil)
        #expect(model.preview == nil)
        #expect(model.issue?.contains("Review again") == true)
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
