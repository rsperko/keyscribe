import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct HUDStateTests {
    @Test func completedInsertedCarriesTheResolvedModeName() {
        let state = HUDState.complete(outcome: .inserted, mode: "Polish")
        #expect(state.primaryText == "Inserted")
        #expect(state.secondaryText == "Polish")
        #expect(state.offersPasteLast == false)
    }

    @Test func completedCopiedExplainsFocusChangeAndOffersPaste() {
        let state = HUDState.complete(outcome: .copied(.focusChanged), mode: "Edit Selection")
        #expect(state.primaryText == "Copied instead of inserted")
        #expect(state.secondaryText == "Focus changed while \(Branding.appName) was working")
        #expect(state.offersPasteLast)
    }

    @Test func localFallbackInsertedSaysRewriteFailed() {
        let state = HUDState.localFallback(outcome: .inserted, mode: "Polish")
        #expect(state.primaryText == "Inserted without rewriting")
        #expect(state.secondaryText == "Rewrite could not be completed")
        #expect(state.offersPasteLast == false)
    }

    @Test func localFallbackCopiedTellsTheTruthAndOffersPaste() {
        let state = HUDState.localFallback(outcome: .copied(.focusChanged), mode: "Polish")
        #expect(state.primaryText == "Copied without rewriting")
        #expect(state.secondaryText == "Focus changed while \(Branding.appName) was working")
        #expect(state.offersPasteLast)
    }

    @Test func readyAcknowledgesTheOneShotMode() {
        let state = HUDState.ready(mode: "Edit Selection")
        #expect(state.primaryText == "Edit Selection")
        #expect(state.secondaryText == "Next dictation")
    }

    @Test func armingDictationIsCancellable() {
        let state = HUDState.arming(mode: "Plain Dictation")
        #expect(state.primaryText == "Plain Dictation")
        #expect(state.secondaryText == "Preparing dictation")
        #expect(state.holdsKeyFocus)
        #expect(state.indicator == .preparing)
        #expect(HUDState.recording(mode: "Plain Dictation", level: 0).indicator == .recording)
    }

    @Test func transcribingLeadsWithTheResolvedModeName() {
        let state = HUDState.transcribing(mode: "Email")
        #expect(state.primaryText == "Email")
        #expect(state.secondaryText == "Transcribing")
    }

    @Test func rewritingBadgesListEachBoundaryCategorySeparately() {
        let state = HUDState.rewriting(
            connection: "Gemini", mode: "Email", redacted: false,
            contextCategories: ["app", "preceding text"], offerLocalTranscript: false)
        #expect(state.dataBoundaryBadges == ["Cloud rewrite", "App shared", "Preceding text shared"])
    }

    @Test func rewritingCarriesTheResolvedModeName() {
        let state = HUDState.rewriting(
            connection: "Gemini", mode: "Email", redacted: false,
            contextCategories: [], offerLocalTranscript: false)
        #expect(state.primaryText == "Email")
        #expect(state.secondaryText == "Rewriting with Gemini")
    }

    @Test func rewritingWithBadgesUsesTheTallerProcessingHUD() {
        let state = HUDState.rewriting(
            connection: "Gemini", mode: "Email", redacted: false,
            contextCategories: ["app"], offerLocalTranscript: false)
        #expect(state.contentHeight == 78)
    }

    @Test func rewritingEscapeWithBadgesUsesTheTallestProcessingHUD() {
        let state = HUDState.rewriting(
            connection: "Gemini", mode: "Email", redacted: false,
            contextCategories: ["app"], offerLocalTranscript: true)
        #expect(state.contentHeight == 104)
    }

    @Test func redactionReplacesContextWithTheRedactionBadge() {
        let state = HUDState.rewriting(
            connection: "Gemini", mode: "Private Note", redacted: true,
            contextCategories: [], offerLocalTranscript: false)
        #expect(state.dataBoundaryBadges == ["Cloud rewrite", "Best-effort redaction"])
    }

    @Test func nonRewritingStatesHaveNoBoundaryBadges() {
        #expect(HUDState.complete(outcome: .inserted, mode: "Polish").dataBoundaryBadges.isEmpty)
        #expect(HUDState.ready(mode: "Edit Selection").dataBoundaryBadges.isEmpty)
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
