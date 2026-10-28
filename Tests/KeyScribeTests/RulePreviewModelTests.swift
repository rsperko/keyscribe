import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct RulePreviewModelTests {
    private let pi = ReplacementsSet.Rule(heard: "p[iy]e?", replace: "pi<CR>", regex: true)

    private func item(_ heard: String, line: Int) -> HistorySnapshot.Item {
        HistorySnapshot.Item(
            reference: .init(dayFile: "2026-10-20.jsonl", line: line),
            entry: HistoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(line)), modeName: "Notes", heard: heard,
                result: heard, outcome: .inserted, cloudInvolved: false, redaction: false, contextCategories: []))
    }

    private final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func hit() { lock.withLock { _count += 1 } }
    }

    private func model(history: [HistorySnapshot.Item]?, loads: Loads = Loads()) -> RulePreviewModel {
        var notes = Mode(id: "notes", name: "Notes")
        notes.commands.liveEdits = false
        let config = RuleEffectPreview.Config(modes: [notes], dictionary: DictionarySet(), replacements: ReplacementsSet())
        return RulePreviewModel(
            source: .init(
                scope: .mode("notes"), config: { @Sendable in config },
                history: history.map { items in { @Sendable in loads.hit(); return items } }),
            debounce: .zero)
    }

    private func settle(_ model: RulePreviewModel) async {
        for _ in 0..<200 where model.isWorking { try? await Task.sleep(for: .milliseconds(5)) }
        await model.work?.value
    }

    @Test func aDraftIsCheckedAgainstHistoryAndTheSample() async {
        let model = model(history: [item("I copy the pieces", line: 0), item("plain words", line: 1)])
        model.sampleText = "a pie"
        model.update(draft: pi, original: nil)
        await settle(model)
        #expect(model.history?.checked == 2)
        #expect(model.history?.entries.map(\.after.text) == ["I copi the pices"])
        #expect(model.sample?.after.text == "a pi")
        #expect(model.sample?.rule?.returnOmitted == true)
    }

    @Test func historyIsReadOnceAcrossEdits() async {
        let loads = Loads()
        let model = model(history: [item("pie", line: 0)], loads: loads)
        model.update(draft: pi, original: nil)
        await settle(model)
        var edited = pi
        edited.wholeDictation = true
        model.update(draft: edited, original: nil)
        await settle(model)
        #expect(loads.count == 1)
        #expect(model.history?.entries.first?.after.submit == .return)
    }

    @Test func withHistoryOffOnlyTheSampleIsShown() async {
        let model = model(history: nil)
        model.sampleText = "pie"
        model.update(draft: pi, original: nil)
        await settle(model)
        #expect(model.history == nil)
        #expect(!model.historyAvailable)
        #expect(model.sample?.after.skipsRewrite == true)
    }

    @Test func theLatestDraftWins() async {
        let model = model(history: [item("pie", line: 0)])
        model.update(draft: pi, original: nil)
        model.update(draft: nil, original: nil)
        await settle(model)
        #expect(model.history?.entries.isEmpty == true)
    }

    private final class Items: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [HistorySnapshot.Item] = []
        private var _loads = 0
        var items: [HistorySnapshot.Item] {
            get { lock.withLock { _items } }
            set { lock.withLock { _items = newValue } }
        }
        var loads: Int { lock.withLock { _loads } }
        func load() -> [HistorySnapshot.Item] { lock.withLock { _loads += 1; return _items } }
    }

    private func auditModel(_ history: Items) -> RulePreviewModel {
        var notes = Mode(id: "notes", name: "Notes")
        notes.commands.liveEdits = false
        notes.replacements.rules = [pi]
        let config = RuleEffectPreview.Config(modes: [notes], dictionary: DictionarySet(), replacements: ReplacementsSet())
        return RulePreviewModel(
            source: .init(scope: .mode("notes"), config: { @Sendable in config }, history: { @Sendable in history.load() }),
            debounce: .zero)
    }

    @Test func checkingRulesListsTheOnesThatMisbehaveAndHowManyWereChecked() async {
        let history = Items()
        history.items = [item("I copy the pieces", line: 0)]
        let model = auditModel(history)
        await model.checkRules()
        #expect(model.audit?.findings.map(\.rule) == [pi])
        #expect(model.audit?.checked == 1)
    }

    @Test func eachCheckReadsHistoryAgain() async {
        let history = Items()
        let model = auditModel(history)
        await model.checkRules()
        #expect(model.audit?.checked == 0)
        history.items = [item("I copy the pieces", line: 0)]
        await model.checkRules()
        #expect(history.loads == 2)
        #expect(model.audit?.checked == 1)
    }

    @Test func anUneditedRuleShowsWhatItDoesAndAnEditShowsWhatSavingChanges() async {
        let history = Items()
        history.items = [item("I copy the pieces", line: 0)]
        let model = auditModel(history)
        model.update(draft: pi, original: pi)
        await settle(model)
        #expect(!model.comparesEdit)
        #expect(model.history?.entries.map(\.after.text) == ["I copi the pices"])
        var command = pi
        command.wholeDictation = true
        model.update(draft: command, original: pi)
        await settle(model)
        #expect(model.comparesEdit)
        #expect(model.history?.entries.map(\.after.text) == ["I copy the pieces"])
    }
}
