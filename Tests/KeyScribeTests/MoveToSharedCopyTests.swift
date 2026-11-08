import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct MoveToSharedCopyTests {
    @Test func namesTheEntryWhoUsesTheVocabularyAndWhatTheModeNewlyGets() {
        let plan = SharedVocabularyMove.Plan(users: ["Coding agent", "Markdown"], newlyIncluded: .init(words: 1, rules: 2), conflict: nil)
        #expect(MoveToSharedCopy.lines(
            .rule(.init(heard: "pain", replace: "pane", regex: false)), plan: plan, vocabularyName: "Programming", modeName: "Markdown")
            == [
                "Move this replacement to Programming?",
                "Programming is used by Coding agent and Markdown. Future edits will apply to both.",
                "Markdown will also start using the 1 word and 2 replacements already in Programming.",
            ])
    }

    @Test func aSingleUserAndNothingNew() {
        let plan = SharedVocabularyMove.Plan(users: ["Markdown"], newlyIncluded: .init(words: 0, rules: 0), conflict: nil)
        #expect(MoveToSharedCopy.lines(.word("Kubernetes"), plan: plan, vocabularyName: "Programming", modeName: "Markdown") == [
            "Move “Kubernetes” to Programming?",
            "Programming is used by Markdown.",
        ])
        let many = SharedVocabularyMove.Plan(users: ["A", "B", "Markdown"], newlyIncluded: nil, conflict: nil)
        #expect(MoveToSharedCopy.lines(.word("Kubernetes"), plan: many, vocabularyName: "Programming", modeName: "Markdown")[1]
            == "Programming is used by A, B, and Markdown. Future edits will apply to all 3.")
    }
}
