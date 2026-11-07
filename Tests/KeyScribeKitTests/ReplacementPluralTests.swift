import Testing
@testable import KeyScribeKit

struct ReplacementPluralTests {
    @Test func aOneWordRuleWritingALowercaseWordOffersItsPlural() {
        let rule = ReplacementsSet.Rule(heard: "pain", replace: "pane", regex: false)
        #expect(ReplacementPlural.offer(for: rule, among: [rule])
            == ReplacementsSet.Rule(heard: "pains", replace: "panes", regex: false))
    }

    @Test(arguments: [
        ReplacementsSet.Rule(heard: "mark", replace: "Marc", regex: false),
        ReplacementsSet.Rule(heard: "bus", replace: "car", regex: false),
        ReplacementsSet.Rule(heard: "cat", replace: "dish", regex: false),
        ReplacementsSet.Rule(heard: "berry", replace: "cherry", regex: false),
        ReplacementsSet.Rule(heard: "pain", replace: "pane", regex: false, wholeDictation: true),
        ReplacementsSet.Rule(heard: "pain", replace: "pane", regex: true),
        ReplacementsSet.Rule(heard: "and and", replace: "&&", regex: false),
        ReplacementsSet.Rule(heard: "dot", replace: ".", regex: false),
    ])
    func aRuleOutsideThePlainPluralOffersNone(_ rule: ReplacementsSet.Rule) {
        #expect(ReplacementPlural.offer(for: rule, among: []) == nil)
    }

    @Test func aRuleThatAlreadyExistsForThePluralMeansNoOffer() {
        let rule = ReplacementsSet.Rule(heard: "pain", replace: "pane", regex: false)
        #expect(ReplacementPlural.offer(for: rule, among: [.init(heard: "Pains", replace: "aches", regex: false)]) == nil)
    }
}

struct ModeReplacementBatchTests {
    @Test func aModeKeepsEveryRuleAddedTogether() {
        var mode = Mode(id: "code", name: "Code")
        mode.replacements.rules = [.init(heard: "teh", replace: "the", regex: false)]
        let updated = mode.addingReplacements([
            .init(heard: "pain", replace: "pane", regex: false), .init(heard: "pains", replace: "panes", regex: false),
        ])
        #expect(updated.replacements.rules.map(\.heard) == ["teh", "pain", "pains"])
    }
}
