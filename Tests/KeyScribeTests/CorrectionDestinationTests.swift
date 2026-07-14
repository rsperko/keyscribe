import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct CorrectionDestinationTests {
    @Test func listExcludesDisabledAndSystemModesButKeepsGlobal() {
        var enabledMode = Mode(id: "code", name: "Code")
        enabledMode.enabled = true
        var disabledMode = Mode(id: "email", name: "Email")
        disabledMode.enabled = false
        let systemMode = Mode.direct

        let list = CorrectionDestination.list(for: [enabledMode, disabledMode, systemMode])

        #expect(list.first == .global)
        #expect(list.contains { $0.scope == .mode("code") })
        #expect(!list.contains { $0.scope == .mode("email") })
        #expect(!list.contains { $0.scope == .mode(Mode.directId) })
    }

    @MainActor
    @Test func saveFailedMessageNamesTheRightSurface() {
        let global = CorrectionPanelController.saveFailedMessage(for: .global)
        #expect(global.contains("Maintenance"))

        let mode = CorrectionPanelController.saveFailedMessage(
            for: .mode(id: "email", name: "Email"))
        #expect(mode.contains("Modes"))
        #expect(mode.contains("Email"))
    }

    @Test func duplicateWordProducesVisibleExistingStatusAndDisablesCommit() {
        let draft = VocabularyDraftAnalysis(
            term: "KeyScribe", replacement: "", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .noChange(.wordAlreadyListed)) })

        #expect(draft.feedback == .existing("Already in Words to Recognize."))
        #expect(!draft.canCommit)
        #expect(draft.buttonTitle == "Add")
    }

    @Test func replacementUpdateExplainsTheChangeAndUsesUpdateAction() {
        let draft = VocabularyDraftAnalysis(
            term: "key scribe", replacement: "KeyScribe", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .updateReplacement(currentReplace: "Keyscribe")) })

        #expect(draft.feedback == .update("Updates the existing replacement — “key scribe” currently becomes “Keyscribe”."))
        #expect(draft.canCommit)
        #expect(draft.buttonTitle == "Update")
    }

    @Test func globalCoverageProducesVisibleExistingStatusAndDisablesCommit() {
        let draft = VocabularyDraftAnalysis(
            term: "KeyScribe", replacement: "", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .noChange(.wordCoveredByGlobal)) })

        #expect(draft.feedback == .existing("Already included from your global vocabulary."))
        #expect(!draft.canCommit)
    }

    @Test func modeReplacementOverrideProducesAdvisoryFeedback() {
        let advisory = VocabularyAnalysis.Advisory(
            kind: .overridesGlobal,
            message: "Overrides the global replacement.")
        let draft = VocabularyDraftAnalysis(
            term: "key scribe", replacement: "KeyScribe", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .addReplacement, advisories: [advisory]) })

        #expect(draft.feedback == .advisory("Overrides the global replacement."))
    }

    @Test func existingReplacementCanStillBeAppliedToTheSelection() {
        let draft = VocabularyDraftAnalysis(
            term: "key scribe", replacement: "KeyScribe", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .noChange(.replacementAlreadyListed)) })

        #expect(!draft.canCommit)
        #expect(draft.canApplyCorrection)
    }

    @Test func replacementEditAnalysisOwnsValidationAndIdentityGating() {
        let original = ReplacementsSet.Rule(heard: "key scribe", replace: "KeyScribe", regex: false)
        let valid = VocabularyDraftAnalysis(
            replacementTerm: " key scribe ", replacement: "Key Scribe", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .addReplacement) })
        let conflict = VocabularyDraftAnalysis(
            replacementTerm: "other", replacement: "value", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .updateReplacement(currentReplace: "old")) })
        let invalidRegex = VocabularyDraftAnalysis(
            replacementTerm: "(", replacement: "value", regex: true,
            analyze: { _ in VocabularyAnalysis(action: .addReplacement) })

        #expect(valid.replacementRule == .init(heard: "key scribe", replace: "Key Scribe", regex: false))
        #expect(valid.canUpdateReplacement(from: original))
        #expect(conflict.hasReplacementIdentityConflict)
        #expect(!conflict.canUpdateReplacement(from: original))
        #expect(invalidRegex.validationIssue == .invalidRegex)
    }
}
