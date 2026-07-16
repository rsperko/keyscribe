import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct VocabularyScopePickerTests {
    @Test func groupsEditableModesByEnabledStateAndExcludesPlainDictation() {
        var email = Mode(id: "email", name: "Email")
        email.enabled = true
        var notes = Mode(id: "notes", name: "Notes")
        notes.enabled = false

        let sections = VocabularyScopePicker.sections(for: [.direct, email, notes])

        #expect(sections.enabled.map(\.id) == ["email"])
        #expect(sections.disabled.map(\.id) == ["notes"])
    }

    @Test func fallsBackToGlobalWhenTheSelectedModeNoLongerExists() {
        let selection = VocabularyScopeDestination.mode("deleted-mode")

        #expect(VocabularyScopePicker.resolved(selection, in: [.direct]) == .global)
    }

    @Test func editingAMissingModeRuleDoesNotRemoveTheGlobalRuleFromAnalysis() {
        let globalRule = ReplacementsSet.Rule(heard: "deploy", replace: "release", regex: false)
        let missingModeRule = ReplacementsSet.Rule(heard: "deploy", replace: "ship", regex: false)
        let scope = VocabularyScope(
            globalRules: [globalRule],
            local: .init(rules: []))

        let analysisScope = VocabularyEditAnalysis.scope(for: scope, excluding: missingModeRule)

        #expect(analysisScope.globalRules == [globalRule])
    }

    @MainActor @Test func openingModeVocabularySelectsItsScope() {
        let navigation = SettingsNavigationModel()

        navigation.openVocabulary(for: "email")

        #expect(navigation.destination == .vocabulary)
        #expect(navigation.vocabularyScope == .mode("email"))
    }
}
