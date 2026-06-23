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
        #expect(state.primaryText == "Inserted without rewriting")
        #expect(state.secondaryText == "Rewrite could not be completed")
        #expect(state.offersPasteLast == false)
    }

    @Test func localFallbackCopiedTellsTheTruthAndOffersPaste() {
        let state = HUDState.localFallback(outcome: .copied(.focusChanged), mode: "Polished Dictation")
        #expect(state.primaryText == "Copied without rewriting")
        #expect(state.secondaryText == "Focus changed while KeyScribe was working")
        #expect(state.offersPasteLast)
    }

    @Test func readyAcknowledgesTheOneShotMode() {
        let state = HUDState.ready(mode: "Work on Selection")
        #expect(state.primaryText == "Work on Selection")
        #expect(state.secondaryText == "Next dictation")
    }

    @Test func rewritingBadgesListEachBoundaryCategorySeparately() {
        let state = HUDState.rewriting(
            connection: "Gemini", redacted: false,
            contextCategories: ["app", "visible text"], offerLocalTranscript: false)
        #expect(state.dataBoundaryBadges == ["Cloud rewrite", "App shared", "Visible text shared"])
    }

    @Test func redactionReplacesContextWithTheRedactionBadge() {
        let state = HUDState.rewriting(
            connection: "Gemini", redacted: true,
            contextCategories: [], offerLocalTranscript: false)
        #expect(state.dataBoundaryBadges == ["Cloud rewrite", "Best-effort redaction"])
    }

    @Test func nonRewritingStatesHaveNoBoundaryBadges() {
        #expect(HUDState.complete(outcome: .inserted, mode: "Polished Dictation").dataBoundaryBadges.isEmpty)
        #expect(HUDState.ready(mode: "Work on Selection").dataBoundaryBadges.isEmpty)
        #expect(HUDState.error(message: "Transcription failed", action: nil).dataBoundaryBadges.isEmpty)
    }

    @Test func microphoneErrorOffersOpenMicrophoneSettings() {
        let state = HUDState.error(message: "Could not start the microphone", action: .openMicrophoneSettings)
        #expect(state.primaryText == "Could not start the microphone")
        #expect(state.errorAction == .openMicrophoneSettings)
    }

    @Test func errorWithoutARecoveryOffersNoAction() {
        let state = HUDState.error(message: "Transcription failed", action: nil)
        #expect(state.primaryText == "Transcription failed")
        #expect(state.errorAction == nil)
    }

    @Test func copiedBecauseAccessibilityOffExplainsClipboardAndHidesPasteButton() {
        let state = HUDState.complete(outcome: .copied(.accessibilityDenied), mode: "Plain Dictation")
        #expect(state.primaryText == "Copied instead of inserted")
        #expect(state.secondaryText == "Accessibility is off — copied to the clipboard. Paste with ⌘V.")
        #expect(state.offersPasteLast == false)
    }
}
