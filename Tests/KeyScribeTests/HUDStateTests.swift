import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct HUDStateTests {
    @Test func completedInsertedCarriesTheResolvedModeName() {
        let state = HUDState.complete(outcome: .inserted, mode: "Polished Dictation")
        #expect(state.primaryText == "Inserted")
        #expect(state.secondaryText == "Polished Dictation")
        #expect(state.offersPasteLast == false)
    }

    @Test func completedCopiedExplainsFocusChangeAndOffersPaste() {
        let state = HUDState.complete(outcome: .copied(.focusChanged), mode: "Work on Selection")
        #expect(state.primaryText == "Copied instead of inserted")
        #expect(state.secondaryText == "Focus changed while KeyScribe was working")
        #expect(state.offersPasteLast)
    }

    @Test func localFallbackInsertedSaysRewriteFailed() {
        let state = HUDState.localFallback(outcome: .inserted, mode: "Polished Dictation")
        #expect(state.primaryText == "Inserted local transcript")
        #expect(state.secondaryText == "Rewrite could not be completed")
        #expect(state.offersPasteLast == false)
    }

    @Test func localFallbackCopiedTellsTheTruthAndOffersPaste() {
        let state = HUDState.localFallback(outcome: .copied(.focusChanged), mode: "Polished Dictation")
        #expect(state.primaryText == "Copied local transcript instead of inserting")
        #expect(state.secondaryText == "Focus changed while KeyScribe was working")
        #expect(state.offersPasteLast)
    }

    @Test func readyAcknowledgesTheOneShotMode() {
        let state = HUDState.ready(mode: "Work on Selection")
        #expect(state.primaryText == "Work on Selection")
        #expect(state.secondaryText == "Next dictation")
    }
}
