import Testing
@testable import KeyScribeKit

struct SharedVocabularyMoveTests {
    private func rule(_ heard: String, _ replace: String) -> ReplacementsSet.Rule {
        ReplacementsSet.Rule(heard: heard, replace: replace, regex: false)
    }

    private var markdown: Mode {
        var m = Mode(id: "markdown", name: "Markdown")
        m.dictionary.words = ["Kubernetes"]
        m.replacements.rules = [rule("pain", "pane")]
        return m
    }

    private var agent: Mode {
        var m = Mode(id: "agent", name: "Coding agent")
        m.sharedVocabularies = ["programming"]
        return m
    }

    private let programming = SharedVocabulary(
        id: "programming", name: "Programming", words: ["Rust"], rules: [.init(heard: "kube", replace: "k8s", regex: false)])

    @Test func movingNamesWhoWillUseItAndWhatTheModeNewlyGets() {
        let plan = SharedVocabularyMove.plan(.rule(rule("pain", "pane")), from: markdown, to: programming, modes: [agent, markdown])
        #expect(plan.users == ["Coding agent", "Markdown"])
        #expect(plan.newlyIncluded == .init(words: 1, rules: 1))
        #expect(plan.conflict == nil)
    }

    @Test func aDisabledUserIsNamedAsDisabled() {
        var email = agent
        email.enabled = false
        let plan = SharedVocabularyMove.plan(.word("Kubernetes"), from: markdown, to: programming, modes: [email, markdown])
        #expect(plan.users == ["Coding agent (disabled)", "Markdown"])
    }

    @Test func aModeAlreadyUsingTheVocabularyGetsNothingNew() {
        var mode = markdown
        mode.sharedVocabularies = ["programming"]
        let plan = SharedVocabularyMove.plan(.word("Kubernetes"), from: mode, to: programming, modes: [mode])
        #expect(plan.newlyIncluded == nil)
        #expect(plan.users == ["Markdown"])
    }

    @Test func aDifferentEntryInTheDestinationIsAConflictNeverOverwritten() {
        let destination = SharedVocabulary(
            id: "programming", name: "Programming", words: ["kubernetes"], rules: [.init(heard: "Pain", replace: "panel", regex: false)])
        #expect(SharedVocabularyMove.plan(.rule(rule("pain", "pane")), from: markdown, to: destination, modes: []).conflict
            == "Programming already replaces “Pain” with “panel”.")
        #expect(SharedVocabularyMove.plan(.word("Kubernetes"), from: markdown, to: destination, modes: []).conflict
            == "Programming already spells it “kubernetes”.")
    }

    @Test func applyingMovesTheEntryAndAttachesTheMode() {
        var vocabulary = programming
        var mode = markdown
        SharedVocabularyMove.apply(.rule(rule("pain", "pane")), to: &vocabulary, from: &mode)
        #expect(vocabulary.rules == programming.rules + [rule("pain", "pane")])
        #expect(mode.replacements.rules.isEmpty)
        #expect(mode.sharedVocabularies == ["programming"])
        SharedVocabularyMove.apply(.word("Kubernetes"), to: &vocabulary, from: &mode)
        #expect(vocabulary.words == ["Rust", "Kubernetes"])
        #expect(mode.dictionary.words.isEmpty)
        #expect(mode.sharedVocabularies == ["programming"])
    }

    @Test func anIdenticalDestinationEntryIsNotDuplicated() {
        var vocabulary = SharedVocabulary(id: "programming", name: "Programming", rules: [rule("pain", "pane")])
        var mode = markdown
        SharedVocabularyMove.apply(.rule(rule("pain", "pane")), to: &vocabulary, from: &mode)
        #expect(vocabulary.rules == [rule("pain", "pane")])
    }
}
