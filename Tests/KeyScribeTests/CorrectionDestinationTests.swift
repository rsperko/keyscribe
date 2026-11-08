import Testing
@testable import KeyScribeApp
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

    @Test func voiceCommandsTakesCorrectionsIntoItsOwnVocabulary() {
        let list = CorrectionDestination.list(for: [.direct, .voiceCommands])
        #expect(list.contains { $0.scope == .mode(Mode.voiceCommandsId) })
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
        #expect(draft.buttonTitle == "Add Word")
    }

    @Test func replacementUpdateExplainsTheChangeAndUsesUpdateAction() {
        let draft = VocabularyDraftAnalysis(
            term: "key scribe", replacement: "KeyScribe", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .updateReplacement(currentReplace: "Keyscribe")) })

        #expect(draft.feedback == .update("Updates the existing replacement — “key scribe” currently becomes “Keyscribe”."))
        #expect(draft.canCommit)
        #expect(draft.buttonTitle == "Update Replacement")
    }

    @Test func aLiteralReplacementWithAReturnMarkerWarnsItTypesTheTextButStillSaves() {
        let draft = VocabularyDraftAnalysis(
            replacementTerm: "send it", replacement: "<CR>", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .addReplacement) })

        #expect(draft.feedback == .advisory(ReplacementAuthoring.literalReturnMarkerAdvisory(replace: "<CR>", regex: false)!))
        #expect(draft.canCommit)
    }

    @Test func wordUpdateExplainsTheCasingChangeAndUsesUpdateAction() {
        let draft = VocabularyDraftAnalysis(
            term: "GitHub", replacement: "", regex: false,
            analyze: { _ in VocabularyAnalysis(action: .updateWord(currentWord: "github")) })

        #expect(draft.feedback == .update("Updates the existing word — “GitHub” is currently spelled “github”."))
        #expect(draft.canCommit)
        #expect(draft.buttonTitle == "Update Word")
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

    @Test func theButtonSaysWhatItWillAdd() {
        let replacement = VocabularyDraftAnalysis(
            term: "Cryden", replacement: "Kryten", regex: false, analyze: { _ in VocabularyAnalysis(action: .addReplacement) })
        #expect(replacement.buttonTitle == "Add Replacement")
        let empty = VocabularyDraftAnalysis(term: "", replacement: "", regex: false, analyze: { _ in VocabularyAnalysis(action: .addWord) })
        #expect(empty.buttonTitle == "Add")
    }

    @Test func aReplacementSaysWhatItReplacesAndWhere() {
        let draft = VocabularyDraftAnalysis(
            term: "Cryden", replacement: "Kryten", regex: false, analyze: { _ in VocabularyAnalysis(action: .addReplacement) })
        #expect(draft.replacementSummary(in: .global) == "Replace “Cryden” with “Kryten” in modes that include Global vocabulary.")
        #expect(draft.replacementSummary(in: .mode(id: "email", name: "Email")) == "Replace “Cryden” with “Kryten” in Email.")
        let word = VocabularyDraftAnalysis(term: "Kryten", replacement: "", regex: false, analyze: { _ in VocabularyAnalysis(action: .addWord) })
        #expect(word.replacementSummary(in: .global) == nil)
    }

    @Test func theScopeIsSaidPrecisely() {
        #expect(CorrectionDestination.global.scopeLine == "Saved on this Mac. Applies in modes that include Global vocabulary.")
        #expect(CorrectionDestination.mode(id: "email", name: "Email").scopeLine == "Saved on this Mac. Applies only in Email.")
    }

    @Test func aSharedVocabularySaysWhichModesItReachesAndIsListedLast() {
        var code = Mode(id: "code", name: "Code")
        code.sharedVocabularies = ["programming"]
        var docs = Mode(id: "docs", name: "Docs")
        docs.sharedVocabularies = ["programming"]
        let programming = SharedVocabulary(id: "programming", name: "Programming")
        let unused = SharedVocabulary(id: "medical", name: "Medical")
        let list = CorrectionDestination.list(for: [code, docs], shared: [programming, unused])
        #expect(list.map(\.title) == ["Global", "Code", "Docs", "Programming", "Medical"])
        #expect(list[3].scopeLine == "Saved on this Mac. Applies in Code and Docs.")
        #expect(list[4].scopeLine == "Saved here, but not currently used by any mode.")
        var email = Mode(id: "email", name: "Email")
        email.enabled = false
        email.sharedVocabularies = ["programming"]
        #expect(CorrectionDestination.shared(programming, usedBy: [code, email]).scopeLine
            == "Saved on this Mac. Applies in Code, and in Email once enabled.")
        #expect(CorrectionDestination.shared(programming, usedBy: [email]).scopeLine
            == "Saved here. Applies once Email is enabled.")
        #expect(list[3].isShared)
        let rule = VocabularyDraftAnalysis(term: "pain", replacement: "pane", regex: false, analyze: { _ in VocabularyAnalysis(action: .addWord) })
        #expect(rule.replacementSummary(in: list[3]) == "Replace \u{201C}pain\u{201D} with \u{201C}pane\u{201D} in the modes that use Programming.")
    }

    @Test func aNameAlreadyAddedLeadsToTeachingTheSelectedSpelling() {
        let offer = VocabularyDraftAnalysis.teachableCorrection(
            selected: " Crayton ", term: "Kryten", action: .noChange(.wordAlreadyListed))
        #expect(offer?.heard == "Crayton")
        #expect(offer?.word == "Kryten")
        #expect(VocabularyDraftAnalysis.teachableCorrection(
            selected: "Kryten", term: "Kryten", action: .noChange(.wordAlreadyListed)) == nil)
        #expect(VocabularyDraftAnalysis.isAlreadyAdded(.noChange(.wordCoveredByGlobal)))
        #expect(!VocabularyDraftAnalysis.isAlreadyAdded(.noChange(.replacementAlreadyListed)))
    }

    @Test func aScopeFindsTheRuleAnAddWouldUpdate() {
        let scope = VocabularyScope(
            globalRules: [.init(heard: "slash resume", replace: "/resume<CR>", regex: true, wholeDictation: true)])
        #expect(scope.ownRule(heard: "slash resume", regex: true)?.wholeDictation == true)
        #expect(scope.ownRule(heard: "slash resume", regex: false) == nil)
        let mode = VocabularyScope(globalRules: [], local: .init(rules: [.init(heard: "Teh", replace: "the", regex: false)]))
        #expect(mode.ownRule(heard: "teh", regex: false)?.replace == "the")
    }
}
