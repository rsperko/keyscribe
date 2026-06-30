import Testing
@testable import KeyScribeKit

struct HistoryCorrectionSourceTests {
    @Test func replacementComesOnlyFromHeardSelection() {
        #expect(HistoryCorrectionSource.replacement(selection: "  pat ", selectionIsHeard: true) == "pat")
        #expect(HistoryCorrectionSource.replacement(selection: "pat", selectionIsHeard: false) == "")
    }

    @Test func dictionaryPrefersHeardSelection() {
        let term = HistoryCorrectionSource.dictionary(
            selection: " Postgres ", selectionIsHeard: true, result: "anything here")
        #expect(term == "Postgres")
    }

    @Test func dictionaryFallsBackToOneWordResultWhenSelectionNotHeard() {
        let term = HistoryCorrectionSource.dictionary(
            selection: "ignored", selectionIsHeard: false, result: "  Kubernetes ")
        #expect(term == "Kubernetes")
    }

    @Test func dictionaryRejectsMultiWordResultFallback() {
        let term = HistoryCorrectionSource.dictionary(
            selection: "", selectionIsHeard: false, result: "two words")
        #expect(term == "")
    }

    @Test func hintReflectsSelectionState() {
        #expect(HistoryCorrectionSource.hint(selection: "   ", selectionIsHeard: false) == .selectFirst)
        #expect(HistoryCorrectionSource.hint(selection: " pat ", selectionIsHeard: true) == .usingHeard("pat"))
        #expect(HistoryCorrectionSource.hint(selection: "result words", selectionIsHeard: false) == .selectHeard)
    }
}
