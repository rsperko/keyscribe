import Foundation
import Testing
@testable import KeyScribeKit

private func item(
    _ heard: String, mode: String = "Notes", line: Int, at seconds: TimeInterval = 1_700_000_000,
    outcome: HistoryEntry.Outcome = .inserted
) -> HistorySnapshot.Item {
    HistorySnapshot.Item(
        reference: .init(dayFile: "2026-10-20.jsonl", line: line),
        entry: HistoryEntry(
            timestamp: Date(timeIntervalSince1970: seconds), modeName: mode, heard: heard, result: heard,
            outcome: outcome, cloudInvolved: false, redaction: false, contextCategories: []))
}

private func notes(rules: [ReplacementsSet.Rule] = [], words: [String] = [], liveEdits: Bool = false) -> Mode {
    var m = Mode(id: "notes", name: "Notes")
    m.replacements = .init(includeGlobal: true, rules: rules)
    m.dictionary = .init(includeGlobal: true, words: words)
    m.commands.liveEdits = liveEdits
    return m
}

private let pi = ReplacementsSet.Rule(heard: "p[iy]e?", replace: "pi<CR>", regex: true)

private func preview(
    draft: ReplacementsSet.Rule?, replacing original: ReplacementsSet.Rule? = nil,
    scope: ReplacementPreview.Destination = .mode("notes"), modes: [Mode] = [notes()],
    global: [ReplacementsSet.Rule] = [], dictionary: [String] = [],
    history: [HistorySnapshot.Item], limit: Int = 100, baseline: RuleEffectPreview.Baseline = .current
) throws -> RuleEffectPreview {
    try RuleEffectPreview.make(
        draft: draft, replacing: original, scope: scope,
        config: .init(modes: modes, dictionary: DictionarySet(words: dictionary),
                      replacements: ReplacementsSet(rules: global)),
        history: history, limit: limit, baseline: baseline)
}

struct RuleEffectPreviewTests {
    @Test func aNewRuleShowsEveryDictationItChangesAndFlagsInsideWordAndDroppedReturn() throws {
        let history = [item("I copy the pieces", line: 0), item("nothing here", line: 1)]
        let result = try preview(draft: pi, history: history)
        #expect(result.checked == 2)
        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.before.text == "I copy the pieces")
        #expect(entry.after.text == "I copi the pices")
        #expect(entry.rule?.insideWord == true)
        #expect(entry.rule?.returnOmitted == true)
        #expect(entry.changes.map(\.before) == ["copy", "pieces"])
    }

    @Test func aRuleThatOnlyChangesBehaviourStillCounts() throws {
        let result = try preview(draft: pi, history: [item("pi", line: 0)])
        let entry = try #require(result.entries.first)
        #expect(entry.before.text == "pi")
        #expect(entry.after.text == "pi")
        #expect(entry.after.submit == .return)
        #expect(entry.after.skipsRewrite)
        #expect(!entry.before.skipsRewrite)
        #expect(entry.changes.isEmpty)
        #expect(entry.rule?.ownsWholeDictation == true)
    }

    @Test func editingARuleComparesTodaysRulesWithTheEdit() throws {
        let fixed = ReplacementsSet.Rule(heard: #"\bpi\b"#, replace: "pi<CR>", regex: true)
        let result = try preview(
            draft: fixed, replacing: pi, modes: [notes(rules: [pi])],
            history: [item("I copy the pieces", line: 0), item("pi", line: 1)])
        #expect(result.entries.map(\.before.text) == ["I copi the pices"])
        #expect(result.entries.map(\.after.text) == ["I copy the pieces"])
    }

    @Test func makingARuleWholeDictationOnlyShowsTheSentencesItStopsDamaging() throws {
        var command = pi
        command.wholeDictation = true
        let result = try preview(
            draft: command, replacing: pi, modes: [notes(rules: [pi])], history: [item("I copy the pieces", line: 0)])
        #expect(result.entries.map(\.before.text) == ["I copi the pices"])
        #expect(result.entries.map(\.after.text) == ["I copy the pieces"])
    }

    @Test func anUneditedRuleIsShownAgainstTheScopeWithoutIt() throws {
        let result = try preview(
            draft: pi, replacing: pi, modes: [notes(rules: [pi])], history: [item("I copy the pieces", line: 0)],
            baseline: .withoutRule)
        #expect(result.entries.map(\.after.text) == ["I copi the pices"])
    }

    @Test func entriesCarryWhenAndWhereTheyWereDictated() throws {
        let result = try preview(draft: pi, history: [item("a pie here", line: 0, at: 1_700_000_000)])
        #expect(result.entries.first?.modeName == "Notes")
        #expect(result.entries.first?.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func aWholeDictationRuleLeavesSentencesAlone() throws {
        var command = pi
        command.wholeDictation = true
        let result = try preview(draft: command, history: [item("I copy the pieces", line: 0), item("pie", line: 1)])
        #expect(result.entries.map(\.after.text) == ["pi"])
    }

    @Test func fuzzyCorrectionRunsAfterTheRuleLikeItDoesWhenDictating() throws {
        let rule = ReplacementsSet.Rule(heard: "croydon", replace: "Krytem", regex: false)
        let result = try preview(draft: rule, dictionary: ["Kryten"], history: [item("ask croydon", line: 0)])
        #expect(result.entries.first?.after.text == "ask Kryten")
    }

    @Test func onlyTheMostRecentDictationsInScopeAreChecked() throws {
        let history = [
            item("pie one", line: 0, at: 1), item("pie two", line: 1, at: 3), item("pie three", line: 2, at: 2),
            item("pie elsewhere", mode: "Other", line: 3, at: 4),
        ]
        let other = Mode(id: "other", name: "Other")
        let result = try preview(draft: pi, modes: [notes(), other], history: history, limit: 2)
        #expect(result.checked == 2)
        #expect(result.entries.map(\.before.text) == ["pie two", "pie three"])
    }

    @Test func voiceCommandEntriesAreNotDictationsToCheck() throws {
        let result = try preview(draft: pi, history: [item("pie", line: 0, outcome: .command)])
        #expect(result.checked == 0)
    }

    @Test func sampleTextShowsTheRuleEvenWithNoHistory() throws {
        let sample = try RuleEffectPreview.sample(
            "I copy the pieces", draft: pi, replacing: nil, scope: .mode("notes"),
            config: .init(modes: [notes()], dictionary: DictionarySet(), replacements: ReplacementsSet()))
        #expect(sample.after.text == "I copi the pices")
        #expect(sample.rule?.returnOmitted == true)
        let whole = try RuleEffectPreview.sample(
            "pie", draft: pi, replacing: nil, scope: .mode("notes"),
            config: .init(modes: [notes()], dictionary: DictionarySet(), replacements: ReplacementsSet()))
        #expect(whole.after.submit == .return)
    }

    @Test func theAuditListsOnlyRulesThatWouldMisbehaveOnPastDictations() throws {
        let sean = ReplacementsSet.Rule(heard: "sean", replace: "Shawn", regex: true)
        let fine = ReplacementsSet.Rule(heard: "teh", replace: "the", regex: false)
        let history = [item("I copy the pieces", line: 0), item("ask seanna and teh team", line: 1), item("pie", line: 2)]
        let audit = try RuleEffectPreview.audit(
            scope: .mode("notes"),
            config: .init(modes: [notes(rules: [pi, sean, fine])], dictionary: DictionarySet(), replacements: ReplacementsSet()),
            history: history, limit: 100)
        let findings = audit.findings
        #expect(audit.checked == 3)
        #expect(findings.map(\.rule) == [pi, sean])
        #expect(findings[0].insideWord == 1)
        #expect(findings[0].returnOmitted == 1)
        #expect(findings[0].example?.before.text == "I copy the pieces")
        #expect(findings[1].insideWord == 1)
        #expect(findings[1].returnOmitted == 0)
    }

    @Test func theAuditCatchesADroppedReturnEvenWhenTheWordsStayTheSame() throws {
        let rule = ReplacementsSet.Rule(heard: "pi", replace: "pi<CR>", regex: true)
        let audit = try RuleEffectPreview.audit(
            scope: .mode("notes"),
            config: .init(modes: [notes(rules: [rule])], dictionary: DictionarySet(), replacements: ReplacementsSet()),
            history: [item("say pi please", line: 0)], limit: 100)
        #expect(audit.findings.map(\.returnOmitted) == [1])
        #expect(audit.findings.first?.example?.after.text == "say pi please")
    }

    @Test func anAuditWithNothingInScopeSaysSo() throws {
        let audit = try RuleEffectPreview.audit(
            scope: .mode("notes"),
            config: .init(modes: [notes(rules: [pi])], dictionary: DictionarySet(), replacements: ReplacementsSet()),
            history: [], limit: 100)
        #expect(audit.checked == 0)
        #expect(audit.findings.isEmpty)
    }

    @Test func aModeScopeChecksOnlyThatModesDictations() throws {
        let history = [item("pie here", line: 0), item("pie elsewhere", mode: "Renamed Away", line: 1)]
        let result = try preview(draft: pi, history: history)
        #expect(result.checked == 1)
        let global = try preview(draft: pi, scope: .global, history: history)
        #expect(global.checked == 2)
    }
}
