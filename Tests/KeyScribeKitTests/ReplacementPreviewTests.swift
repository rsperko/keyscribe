import Foundation
import Testing
@testable import KeyScribeKit

private func item(_ heard: String, mode: String = "Notes", day: String = "2026-10-20", line: Int) -> HistorySnapshot.Item {
    HistorySnapshot.Item(
        reference: .init(dayFile: "\(day).jsonl", line: line),
        entry: HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), modeName: mode, heard: heard, result: heard,
            outcome: .inserted, cloudInvolved: false, redaction: false, contextCategories: []))
}

private func rule(_ heard: String, _ replace: String) -> ReplacementsSet.Rule {
    ReplacementsSet.Rule(heard: heard, replace: replace, regex: false)
}

private func mode(_ id: String, _ name: String, includeGlobal: Bool = true, rules: [ReplacementsSet.Rule] = []) -> Mode {
    var m = Mode(id: id, name: name)
    m.replacements = .init(includeGlobal: includeGlobal, rules: rules)
    return m
}

private func preview(
    _ phrases: [String], to destination: ReplacementPreview.Destination = .global,
    global: [ReplacementsSet.Rule] = [], modes: [Mode] = [mode("notes", "Notes")],
    history: [HistorySnapshot.Item], searched: Set<HistorySnapshot.Reference>? = nil
) throws -> ReplacementPreview {
    try ReplacementPreview.make(
        phrases: phrases, replacement: "Yugabyte", destination: destination,
        global: ReplacementsSet(rules: global), modes: modes,
        history: history, searched: searched ?? Set(history.map(\.reference)))
}

struct ReplacementPreviewTests {
    @Test func previewsEveryChosenPhraseTogetherAcrossAllHistory() throws {
        let history = [item("Ugabyte is down and Yuga Bite too.", line: 0), item("Restart Ugabyte.", day: "2026-09-01", line: 0)]
        let result = try preview(["Ugabyte", "Yuga Bite"], history: history, searched: [history[0].reference])
        #expect(result.replacementCount == 2)
        #expect(result.changeCount == 3)
        #expect(result.affectedDictations == 2)
        #expect(result.additionalMatches == 1)
        #expect(result.effects.first?.isAdditional == true)
        #expect(result.effects.flatMap(\.changes).map(\.before).sorted() == ["Ugabyte", "Ugabyte", "Yuga Bite"])
        #expect(result.effects.flatMap(\.changes).allSatisfy { $0.after == "Yugabyte" })
    }

    @Test func countsEveryMentionInOneDictationAndKeepsTheSurroundingText() throws {
        let result = try preview(["Ugabyte"], history: [item("Ugabyte here,\nand Ugabyte there", line: 0)])
        let effect = try #require(result.effects.first)
        #expect(effect.changes.count == 2)
        #expect(effect.proposedText == "Yugabyte here,\nand Yugabyte there")
        #expect(effect.changes.map { String(effect.currentText[$0.range]) } == ["Ugabyte", "Ugabyte"])
    }

    @Test func includesLegitimateUsesBecauseTheRuleCannotTellThemApart() throws {
        let result = try preview(["gigabyte"], history: [item("Leave a gigabyte free.", line: 0)])
        #expect(result.changeCount == 1)
    }

    @Test func respectsWordBoundaries() throws {
        let result = try preview(["Ugabyte"], history: [item("Two Ugabytes later.", line: 0)])
        #expect(result.changeCount == 0)
    }

    @Test func appendsNewRulesAndKeepsExistingOrderAndValues() throws {
        let existing = [rule("slash resume", "/resume"), rule("kube cuddle", "kubectl")]
        let result = try preview(["Ugabyte"], global: existing, history: [])
        #expect(result.proposedRules == existing + [rule("Ugabyte", "Yugabyte")])
    }

    @Test func anIdenticalRuleIsAlreadyThereNotANewAddition() throws {
        let existing = [rule("ugabyte", "Yugabyte")]
        let result = try preview(["Ugabyte"], global: existing, history: [item("Ugabyte is down.", line: 0)])
        #expect(result.statuses == [.init(phrase: "Ugabyte", kind: .alreadyAdded)])
        #expect(result.replacementCount == 0)
        #expect(result.proposedRules == existing)
        #expect(result.changeCount == 0)
    }

    @Test func aConflictingRuleIsLeftAloneForExplicitEditing() throws {
        let existing = [rule("Ugabyte", "Uganda")]
        let result = try preview(["Ugabyte", "Yuga Bite"], global: existing,
                                 history: [item("Ugabyte and Yuga Bite.", line: 0)])
        #expect(result.statuses.first == .init(phrase: "Ugabyte", kind: .conflicts(currentOutput: "Uganda")))
        #expect(result.proposedRules == existing + [rule("Yuga Bite", "Yugabyte")])
        #expect(result.effects.flatMap(\.changes).map(\.before) == ["Yuga Bite"])
    }

    @Test func globalRulesSkipModesThatLeaveOutGlobalReplacements() throws {
        let modes = [mode("notes", "Notes"), mode("code", "Code", includeGlobal: false)]
        let history = [item("Ugabyte in notes.", line: 0), item("Ugabyte in code.", mode: "Code", line: 1)]
        let result = try preview(["Ugabyte"], modes: modes, history: history)
        #expect(result.effects.map(\.reference.line) == [0])
    }

    @Test func aModeRuleRunsOnlyInThatModeAndNamesUnknownModes() throws {
        let modes = [mode("notes", "Notes"), mode("code", "Code"), mode("a", "Twin"), mode("b", "Twin")]
        let history = [
            item("Ugabyte in notes.", line: 0), item("Ugabyte in code.", mode: "Code", line: 1),
            item("Ugabyte in a deleted mode.", mode: "Old", line: 2), item("Ugabyte in a twin.", mode: "Twin", line: 3),
        ]
        let result = try preview(["Ugabyte"], to: .mode("notes"), modes: modes, history: history)
        #expect(result.effects.map(\.reference.line) == [0, 2, 3])
        #expect(result.effects.map(\.modeUnknown) == [false, true, true])
    }

    @Test func aModeRuleThatOverridesAGlobalOneSaysWhatItReplaces() throws {
        let result = try preview(["Ugabyte"], to: .mode("notes"), global: [rule("Ugabyte", "Uganda")],
                                 history: [item("Ugabyte is down.", line: 0)])
        #expect(result.statuses == [.init(phrase: "Ugabyte", kind: .overridesGlobal(globalOutput: "Uganda"))])
        #expect(result.proposedRules == [rule("Ugabyte", "Yugabyte")])
        let change = try #require(result.effects.first?.changes.first)
        #expect(change.before == "Uganda")
        #expect(change.after == "Yugabyte")
        #expect(change.phrase == "Ugabyte")
    }

    @Test func flagsAWholeUtteranceReplacement() throws {
        let result = try preview(["Ugabyte"], history: [item("Ugabyte", line: 0), item("Ugabyte is down.", line: 1)])
        #expect(result.effects.map(\.wholeUtterance) == [true, false])
    }

    @Test func previewsAWholeUtteranceReplacementThatBridgesAPause() throws {
        let result = try preview(["Yuga Bite"], history: [item("Yuga, Bite.", line: 0)])
        let effect = try #require(result.effects.first)
        #expect(effect.wholeUtterance)
        #expect(effect.proposedText.contains("Yugabyte"))
        #expect(effect.changes.map(\.phrase) == ["Yuga Bite"])
    }

    @Test func aMissingDestinationModeNeverFallsBackToGlobal() {
        #expect(throws: ReplacementPreview.Failure.destinationMissing) {
            try preview(["Ugabyte"], to: .mode("gone"), history: [])
        }
    }

    @Test func attributesEachChangeToItsPhrase() throws {
        let result = try preview(["Ugabyte", "Yuga Bite"], history: [item("Yuga Bite, then ugabyte.", line: 0)])
        #expect(result.effects.flatMap(\.changes).map(\.phrase) == ["Yuga Bite", "Ugabyte"])
    }

    @Test func aCancelledPreviewStops() async {
        let history = [item("Ugabyte is down.", line: 0)]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try preview(["Ugabyte"], history: history)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
