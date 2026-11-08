import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct OverrideCopyTests {
    private func rule(_ replace: String, alone: Bool = false) -> ReplacementsSet.Rule {
        ReplacementsSet.Rule(heard: "pain", replace: replace, regex: false, wholeDictation: alone)
    }

    private func override(_ entry: SharedVocabularyMove.Entry, by: SharedVocabularyOverrides.Source = .mode)
        -> SharedVocabularyOverrides.Override {
        .init(modeId: "markdown", modeName: "Markdown", by: by, entry: entry)
    }

    @Test func saysWhatDecidesInsteadAndWhereToOpenIt() {
        #expect(OverrideCopy.line(override(.rule(rule("panel"))), of: .rule(rule("pane")))
            == "Overridden in Markdown: there it becomes “panel”.")
        #expect(OverrideCopy.line(override(.rule(rule("panel", alone: true))), of: .rule(rule("pane")))
            == "Overridden in Markdown: there it becomes “panel”, only when said alone.")
        #expect(OverrideCopy.line(override(.rule(rule("pane", alone: true))), of: .rule(rule("pane")))
            == "Overridden in Markdown: there it acts only when said alone.")
        #expect(OverrideCopy.line(override(.word("quorlan")), of: .word("Quorlan"))
            == "Overridden in Markdown: spelled “quorlan” there.")
        #expect(OverrideCopy.action(override(.word("quorlan"))) == "Show in Markdown")
    }

    @Test func anEarlierVocabularyIsNamedAndOpened() {
        let medical = override(.rule(rule("pain.")), by: .shared(id: "medical", name: "Medical"))
        #expect(OverrideCopy.line(medical, of: .rule(rule("pane"))) == "Overridden in Markdown by Medical: there it becomes “pain.”.")
        #expect(OverrideCopy.action(medical) == "Show in Medical")
    }
}
