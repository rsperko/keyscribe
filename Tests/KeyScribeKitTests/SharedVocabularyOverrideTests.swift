import Testing
@testable import KeyScribeKit

struct SharedVocabularyOverrideTests {
    private func rule(_ heard: String, _ replace: String, alone: Bool = false) -> ReplacementsSet.Rule {
        ReplacementsSet.Rule(heard: heard, replace: replace, regex: false, wholeDictation: alone)
    }

    private let programming = SharedVocabulary(
        id: "programming", name: "Programming", words: ["Quorlan"], rules: [.init(heard: "pain", replace: "pane", regex: false)])

    private func mode(_ id: String, _ name: String, uses: [String] = ["programming"], words: [String] = [], rules: [ReplacementsSet.Rule] = []) -> Mode {
        var m = Mode(id: id, name: name)
        m.sharedVocabularies = uses
        m.dictionary.words = words
        m.replacements.rules = rules
        return m
    }

    @Test func aModesOwnDifferentEntryOverridesItThere() {
        let modes = [
            mode("markdown", "Markdown", words: ["quorlan"], rules: [rule("Pain", "panel")]),
            mode("code", "Code"),
            mode("notes", "Notes", uses: [], rules: [rule("pain", "x")]),
        ]
        #expect(SharedVocabularyOverrides.of(.rule(rule("pain", "pane")), in: programming, modes: modes, shared: [programming])
            == [.init(modeId: "markdown", modeName: "Markdown", by: .mode, entry: .rule(rule("Pain", "panel")))])
        #expect(SharedVocabularyOverrides.of(.word("Quorlan"), in: programming, modes: modes, shared: [programming])
            == [.init(modeId: "markdown", modeName: "Markdown", by: .mode, entry: .word("quorlan"))])
    }

    @Test func anIdenticalOwnEntryIsNoOverrideButADifferentScopeIs() {
        let same = [mode("markdown", "Markdown", words: ["Quorlan"], rules: [rule("pain", "pane")])]
        #expect(SharedVocabularyOverrides.of(.rule(rule("pain", "pane")), in: programming, modes: same, shared: [programming]).isEmpty)
        #expect(SharedVocabularyOverrides.of(.word("Quorlan"), in: programming, modes: same, shared: [programming]).isEmpty)
        let alone = [mode("markdown", "Markdown", rules: [rule("pain", "pane", alone: true)])]
        #expect(SharedVocabularyOverrides.of(.rule(rule("pain", "pane")), in: programming, modes: alone, shared: [programming]).count == 1)
    }

    @Test func aVocabularyListedEarlierThatDisagreesOverridesIt() {
        let medical = SharedVocabulary(id: "medical", name: "Medical", rules: [rule("pain", "pain.")])
        let modes = [mode("code", "Code", uses: ["medical", "programming"])]
        #expect(SharedVocabularyOverrides.of(.rule(rule("pain", "pane")), in: programming, modes: modes, shared: [programming, medical])
            == [.init(modeId: "code", modeName: "Code", by: .shared(id: "medical", name: "Medical"), entry: .rule(rule("pain", "pain.")))])
        let after = [mode("code", "Code", uses: ["programming", "medical"])]
        #expect(SharedVocabularyOverrides.of(.rule(rule("pain", "pane")), in: programming, modes: after, shared: [programming, medical]).isEmpty)
    }
}
