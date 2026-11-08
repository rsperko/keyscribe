import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct PendingAttachmentTests {
    private let code = Mode(id: "code", name: "Code")

    private func rule(_ replace: String, alone: Bool = false) -> ReplacementsSet.Rule {
        ReplacementsSet.Rule(heard: "pain", replace: replace, regex: false, wholeDictation: alone)
    }

    private var competition: SharedVocabularyConflicts.Competition {
        .init(key: "l:pain", phrase: "pain", options: [
            .init(entry: .rule(rule("pane")), sources: ["Programming"]),
            .init(entry: .rule(rule("pane", alone: true)), sources: ["Medical"]),
        ])
    }

    @Test func aDisagreementBlocksUntilChosenAndTheChoiceKeepsTheWholeRule() {
        let item = PendingAttachment(mode: code, competition: competition)
        #expect(PendingAttachment.unsettled([item], choices: [:]))
        let choices: [String: SharedVocabularyMove.Entry] = [item.id: .rule(rule("pane", alone: true))]
        #expect(!PendingAttachment.unsettled([item], choices: choices))
        #expect(PendingAttachment.settlements([item], choices: choices) == ["code": .init(rules: [rule("pane", alone: true)])])
    }

    @Test func aChoiceThatIsNoLongerOfferedDoesNotSettleIt() {
        let item = PendingAttachment(mode: code, competition: competition)
        let stale: [String: SharedVocabularyMove.Entry] = [item.id: .rule(rule("panel"))]
        #expect(PendingAttachment.unsettled([item], choices: stale))
        #expect(PendingAttachment.settlements([item], choices: stale).isEmpty)
    }

    @Test func aChosenSpellingBecomesTheModesOwnWord() {
        let item = PendingAttachment(mode: code, competition: .init(key: "w:kubernetes", phrase: "Kubernetes", options: [
            .init(entry: .word("Kubernetes"), sources: ["Programming"]), .init(entry: .word("kubernetes"), sources: ["Medical"]),
        ]))
        #expect(PendingAttachment.settlements([item], choices: [item.id: .word("kubernetes")]) == ["code": .init(words: ["kubernetes"])])
    }

    @Test func optionsWithTheSameOutputAreToldApartByWhereTheyAct() {
        #expect(VocabularyConflictCopy.caption(competition.options[0]) == "From Programming · Anywhere in a sentence")
        #expect(VocabularyConflictCopy.caption(competition.options[1]) == "From Medical · Only when said alone")
    }
}
