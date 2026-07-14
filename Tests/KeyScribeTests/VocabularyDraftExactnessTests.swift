import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct VocabularyDraftExactnessTests {
    private func addReplacement(_ proposal: VocabularyProposal) -> VocabularyAnalysis {
        VocabularyAnalysis(action: .addReplacement)
    }

    @Test func replacementWhitespaceIsPreservedExactly() {
        let draft = VocabularyDraftAnalysis(
            term: "foo", replacement: "  bar  ", regex: false, analyze: addReplacement)
        #expect(draft.proposal == .replacement(heard: "foo", replace: "  bar  ", regex: false))
    }

    @Test func multilineReplacementIsPreservedExactly() {
        let draft = VocabularyDraftAnalysis(
            term: "foo", replacement: "line one\nline two\n", regex: false, analyze: addReplacement)
        #expect(draft.proposal == .replacement(heard: "foo", replace: "line one\nline two\n", regex: false))
    }

    @Test func emptyReplacementIsAWordInComposer() {
        let draft = VocabularyDraftAnalysis(
            term: "foo", replacement: "", regex: false, analyze: addReplacement)
        #expect(draft.proposal == .word("foo"))
    }

    @Test func whitespaceOnlyReplacementIsAReplacement() {
        let draft = VocabularyDraftAnalysis(
            term: "foo", replacement: "  ", regex: false, analyze: addReplacement)
        #expect(draft.proposal == .replacement(heard: "foo", replace: "  ", regex: false))
    }

    @Test func newlineOnlyReplacementReportsInvisibleFeedback() {
        let draft = VocabularyDraftAnalysis(
            term: "foo", replacement: "\n", regex: false, analyze: addReplacement)
        #expect(draft.feedback == .advisory("Creates a replacement containing 1 line break."))
        #expect(draft.canCommit)
    }

    @Test func editorEmptyReplacementKeepsDeleteTextRule() {
        let draft = VocabularyDraftAnalysis(
            replacementTerm: "foo", replacement: "", regex: false, analyze: addReplacement)
        #expect(draft.replacementRule == .init(heard: "foo", replace: "", regex: false))
    }

    @Test func overLimitReplacementIsRejected() {
        let long = String(repeating: "a", count: ReplacementAuthoring.maxCharacters + 1)
        let draft = VocabularyDraftAnalysis(
            term: "foo", replacement: long, regex: false, analyze: addReplacement)
        #expect(draft.validationIssue == .tooLong)
        #expect(draft.proposal == nil)
        #expect(!draft.canCommit)
    }

    @Test func exactlyAtLimitReplacementIsAccepted() {
        let atLimit = String(repeating: "a", count: ReplacementAuthoring.maxCharacters)
        let draft = VocabularyDraftAnalysis(
            term: "foo", replacement: atLimit, regex: false, analyze: addReplacement)
        #expect(draft.validationIssue == nil)
        #expect(draft.canCommit)
    }

    @Test func nonTerminalReturnMarkerInRegexIsRejected() {
        let draft = VocabularyDraftAnalysis(
            replacementTerm: "foo", replacement: "mid<CR>text", regex: true, analyze: addReplacement)
        #expect(draft.validationIssue == .nonTerminalReturnMarker)
        #expect(!draft.canCommit)
    }

    @Test func terminalReturnMarkerInRegexIsAccepted() {
        let draft = VocabularyDraftAnalysis(
            replacementTerm: "foo", replacement: "value<CR>", regex: true, analyze: addReplacement)
        #expect(draft.validationIssue == nil)
        #expect(draft.canCommit)
    }

    @Test func correctionAppliesRegexReplacementEscapes() {
        #expect(CorrectionReplacement.apply(
            to: "foo", pattern: "foo", replacement: #"first\nsecond"#) == "first\nsecond")
    }

    @Test func correctionUsesTheSavedRulesCaseInsensitiveDefault() {
        #expect(CorrectionReplacement.apply(
            to: "FOO", pattern: "foo", replacement: "bar") == "bar")
    }

    @Test func correctionStripsTerminalReturnMarkerWithoutPressingReturn() {
        #expect(CorrectionReplacement.apply(
            to: "foo", pattern: "foo", replacement: "value<CR>") == "value")
    }

    @Test func oversizedRuleEditRequiresShorteningBeforeUpdate() {
        let huge = String(repeating: "a", count: ReplacementAuthoring.maxCharacters + 100)
        let original = ReplacementsSet.Rule(heard: "huge", replace: huge, regex: false)
        let stillOver = VocabularyDraftAnalysis(
            replacementTerm: "huge", replacement: huge + "b", regex: false, analyze: addReplacement)
        #expect(!stillOver.canUpdateReplacement(from: original))
        let shortened = VocabularyDraftAnalysis(
            replacementTerm: "huge", replacement: "short", regex: false, analyze: addReplacement)
        #expect(shortened.canUpdateReplacement(from: original))
    }
}
