import AppKit
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct HUDStateTests {
    @Test func previewFixturesCoverEveryVisibleHUDState() {
        #expect(HUDPreview.names == [
            "ready", "recording", "recording-latched", "loading-model", "transcribing",
            "rewriting", "rewriting-three-badges", "redacted-rewrite", "rewriting-with-local-transcript",
            "inserted", "copied", "copied-long-reason", "no-speech", "nothing-heard", "failed", "rewrite-fallback",
            "microphone-error", "command-not-recognized", "command-not-recognized-long", "accessibility-error",
            "recording-countdown", "stopped-at-limit", "stopped-at-limit-local", "choice", "choice-five",
            "choice-listening", "choice-retry", "choice-heard", "choice-heard-long",
        ])
        for name in HUDPreview.names {
            #expect(HUDPreview.state(named: name) != nil)
        }
        #expect(HUDPreview.state(named: "unknown") == nil)
    }

    @Test func previewLaunchIsUnavailableOutsideDevelopmentBuilds() {
        #expect(HUDPreview.state(
            from: ["KeyScribe", "--hud-preview", "recording"], isDevelopmentBuild: false) == nil)
    }

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

    @Test func transcribingLeadsWithTheResolvedModeName() {
        let state = HUDState.transcribing(mode: "Email")
        #expect(state.primaryText == "Email")
        #expect(state.secondaryText == "Transcribing")
    }

    @Test func loadingModelNamesTheWaitAndStaysCancellable() {
        let state = HUDState.loadingModel(mode: "Email")
        #expect(state.primaryText == "Email")
        #expect(state.secondaryText == "Loading speech model…")
        #expect(state.indicator == .preparing)
        #expect(state.holdsKeyFocus)
        #expect(state.dataBoundaryBadges.isEmpty)
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

    @Test func stateChangesCarryAStableVoiceOverAnnouncement() {
        #expect(HUDState.recording(mode: "Polish", level: 0.4, latchedTrigger: nil).voiceOverAnnouncement == "Recording")
        #expect(HUDState.transcribing(mode: "Email").voiceOverAnnouncement == "Transcribing")
        #expect(HUDState.loadingModel(mode: "Email").voiceOverAnnouncement == "Loading speech model")
        #expect(HUDState.rewriting(
            connection: "Gemini", mode: "Email", redacted: false,
            contextCategories: [], offerLocalTranscript: false).voiceOverAnnouncement == "Rewriting with Gemini")
        #expect(HUDState.complete(outcome: .inserted, mode: "Polish").voiceOverAnnouncement == "Inserted. Polish")
        #expect(HUDState.complete(outcome: .copied(.focusChanged), mode: "Polish").voiceOverAnnouncement
            == "Copied instead of inserted. Focus changed while \(Branding.appName) was working")
        #expect(HUDState.localFallback(outcome: .inserted, mode: "Polish").voiceOverAnnouncement
            == "Inserted without rewriting. Rewrite could not be completed")
        #expect(HUDState.error(message: "Transcription failed", action: nil).voiceOverAnnouncement == "Transcription failed")
    }

    @Test func transientAndDismissalStatesAreNotAnnounced() {
        #expect(HUDState.hidden.voiceOverAnnouncement == nil)
        #expect(HUDState.ready(mode: "Edit Selection").voiceOverAnnouncement == nil)
    }

    @Test func recordingSecondaryTextShowsTheStopCueOnlyWhenLatched() {
        #expect(HUDState.recording(mode: "Plain Dictation", level: 0.4, latchedTrigger: nil).secondaryText == "Listening")
        #expect(HUDState.recording(mode: "Plain Dictation", level: 0.4, latchedTrigger: "Right-⌥").secondaryText
            == "Listening — tap Right-⌥ again to stop")
    }

    @Test func recordingVoiceOverIsConstantAcrossLevelAndLatchState() {
        #expect(HUDState.recording(mode: "Polish", level: 0.1, latchedTrigger: nil).voiceOverAnnouncement == "Recording")
        #expect(HUDState.recording(mode: "Polish", level: 0.9, latchedTrigger: "Right-⌥").voiceOverAnnouncement == "Recording")
    }
    @Test func recordingInTheFinalStretchSaysWhenItStops() {
        let countdown = RecordingCountdown(secondsLeft: 25, totalSeconds: 30)
        let state = HUDState.recording(mode: "Plain Dictation", level: 0.4, latchedTrigger: "Right-⌥", countdown: countdown)
        #expect(state.secondaryText == "Stops in 0:25")
        #expect(state.voiceOverAnnouncement == "Recording stops in 25 seconds")
        #expect(state.recordingCountdown == countdown)
        #expect(state.holdsKeyFocus)
    }

    @Test func countdownFractionDrainsToZero() {
        #expect(RecordingCountdown(secondsLeft: 30, totalSeconds: 30).fractionLeft == 1)
        #expect(RecordingCountdown(secondsLeft: 15, totalSeconds: 30).fractionLeft == 0.5)
        #expect(RecordingCountdown(secondsLeft: 0, totalSeconds: 30).fractionLeft == 0)
    }

    @Test func stoppedAtLimitSaysTheRewriteWasSkipped() {
        let state = HUDState.stoppedAtLimit(outcome: .inserted, limit: "5-minute", rewriteSkipped: true)
        #expect(state.primaryText == "Stopped at the 5-minute limit")
        #expect(state.secondaryText == "Inserted without rewriting — dictate again to continue")
        #expect(state.indicator == .limit)
        #expect(state.offersPasteLast == false)
        #expect(state.voiceOverAnnouncement
            == "Stopped at the 5-minute limit. Inserted without rewriting — dictate again to continue")
    }

    @Test func stoppedAtLimitWithoutARewriteJustSaysInserted() {
        let state = HUDState.stoppedAtLimit(outcome: .inserted, limit: "5-minute", rewriteSkipped: false)
        #expect(state.secondaryText == "Inserted — dictate again to continue")
    }

    @Test func stoppedAtLimitThatCopiedExplainsWhyAndOffersPaste() {
        let state = HUDState.stoppedAtLimit(outcome: .copied(.focusChanged), limit: "5-minute", rewriteSkipped: true)
        #expect(state.secondaryText == "Focus changed while \(Branding.appName) was working")
        #expect(state.offersPasteLast)
    }

    @Test func aCommandsProgressReplacesTranscribingWithoutTakingFocus() {
        let state = HUDState.transcribing(mode: "Voice Commands", status: "Opening Slack\u{2026}")
        #expect(state.secondaryText == "Opening Slack\u{2026}")
        #expect(state.voiceOverAnnouncement == "Opening Slack\u{2026}")
        #expect(!state.holdsKeyFocus)
        #expect(HUDState.transcribing(mode: "Voice Commands").holdsKeyFocus)
    }

    @Test func aQuestionTakesKeyFocusWhileItIsShownLikeTheRecordingHUD() {
        let prompt = HUDPreview.choicePrompt
        #expect(HUDState.choice(prompt, status: .waiting(note: nil)).holdsKeyFocus)
        #expect(HUDState.choice(prompt, status: .listening(latchedTrigger: nil)).holdsKeyFocus)
        #expect(HUDState.choice(prompt, status: .working).holdsKeyFocus)
    }

    @Test func aQuestionIsAnnouncedOnceThenOnlyItsChanges() {
        let prompt = HUDPreview.choicePrompt
        let waiting = HUDState.choice(prompt, status: .waiting(note: nil))
        #expect(waiting.voiceOverAnnouncement(after: .hidden)?.hasPrefix("Which one?. 1, Personal Mail, Safari") == true)
        let listening = HUDState.choice(prompt, status: .listening(latchedTrigger: nil))
        #expect(listening.voiceOverAnnouncement(after: waiting) == "Recording")
        #expect(waiting.voiceOverAnnouncement(after: listening) == nil)
        let retry = HUDState.choice(prompt, status: .waiting(note: "Choose 1\u{2013}2."))
        #expect(retry.voiceOverAnnouncement(after: listening) == "Choose 1\u{2013}2.")
    }

    @Test func anAdvisoryReadsLikeAnErrorButIsMarkedAsAdvisory() {
        let state = HUDState.advisory(message: "dictionary.toml — “termz” has no effect")
        #expect(state.primaryText == "dictionary.toml — “termz” has no effect")
        #expect(state.secondaryText == nil)
        #expect(state.voiceOverAnnouncement == "dictionary.toml — “termz” has no effect")
        #expect(state.indicator == .advisory)
        #expect(!state.holdsKeyFocus)
    }

    @Test func anUnrecognizedCommandShowsItsTitleThenTheHeardExcerptOnce() {
        let state = HUDState.error(message: "Command not recognized", action: nil, heard: HeardExcerpt(heard: "stitch to Mail"))
        #expect(state.primaryText == "Command not recognized")
        #expect(state.secondaryText == "Heard \u{201C}stitch to Mail\u{201D}")
        #expect(state.secondaryIsHeardExcerpt)
        #expect(state.voiceOverAnnouncement == "Command not recognized. Heard \u{201C}stitch to Mail\u{201D}")
        #expect(state.indicator == .error)
        #expect(state.panelWidth == 280)
        let plain = HUDState.error(message: "Command not recognized", action: nil)
        #expect(plain.secondaryText == nil)
        #expect(plain.voiceOverAnnouncement == "Command not recognized")
        #expect(!plain.secondaryIsHeardExcerpt)
        #expect(!HUDState.commandDone(summary: "Mail").secondaryIsHeardExcerpt)
    }

    @Test func aRetainedQuestionAnnouncesOnlyTheHeardExcerptThatReplacedItsNote() {
        let prompt = HUDPreview.choicePrompt
        let listening = HUDState.choice(prompt, status: .listening(latchedTrigger: nil))
        let heard = HUDState.choice(prompt, status: .waiting(note: nil, heard: HeardExcerpt(heard: "tube")))
        #expect(heard.secondaryText == "Heard \u{201C}tube\u{201D}")
        #expect(heard.secondaryIsHeardExcerpt)
        #expect(heard.voiceOverAnnouncement(after: listening) == "Heard \u{201C}tube\u{201D}")
        #expect(!HUDState.choice(prompt, status: .waiting(note: "Choose 1\u{2013}2.")).secondaryIsHeardExcerpt)
    }

    @Test(arguments: [false, true])
    func aHeardExcerptNeverGrowsPastTwoLines(_ inChoice: Bool) throws {
        func height(_ heard: String) throws -> CGFloat {
            let hud = HUDController()
            let excerpt = HeardExcerpt(heard: heard)
            hud.render(inChoice
                ? .choice(HUDPreview.choicePrompt, status: .waiting(note: nil, heard: excerpt))
                : .error(message: "Command not recognized", action: nil, heard: excerpt))
            defer { hud.render(.hidden) }
            return try #require(hud.panelFrame?.height)
        }
        let short = try height("tube")
        let wide = try height(String(repeating: "\u{8A71}", count: HeardExcerpt.characterBudget))
        let line = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 11))
        #expect(wide > short)
        #expect(wide - short < line * 1.5)
    }

    @Test func aWaitingPanelRefusesKeyFocusEvenWhenClicked() {
        let hud = HUDController()
        hud.render(.choice(HUDPreview.choicePrompt, status: .waiting(note: nil)))
        #expect(hud.panelCanBecomeKey == false)
        hud.render(.choice(HUDPreview.choicePrompt, status: .listening(latchedTrigger: nil)))
        #expect(hud.panelCanBecomeKey == true)
        hud.render(.hidden)
    }

    @Test func aQuestionRendersEveryRowWithinTheScreen() {
        let hud = HUDController()
        hud.render(HUDPreview.state(named: "choice-five")!)
        let height = hud.panelFrame?.height ?? 0
        #expect(height > 200)
        #expect(height < 600)
        #expect(hud.panelFrame?.width == 320)
        hud.render(.hidden)
    }

    @Test func clickingAWaitingQuestionRunsEachRowWithoutTakingKeyFocus() throws {
        let hud = HUDController()
        var hits: [String] = []
        hud.onChooseVoiceCommand = { _, identity in if hits.last != identity { hits.append(identity) } }
        hud.onCancelVoiceCommandChoice = { _ in if hits.last != "cancel" { hits.append("cancel") } }
        hud.render(.choice(HUDPreview.choicePrompt, status: .waiting(note: nil)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let view = try #require(hud.panelContentView)
        let window = try #require(view.window)
        var y = view.bounds.maxY - 2
        while y > 0 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 40, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            y -= 4
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(hits == HUDPreview.choicePrompt.rows.map(\.identity) + ["cancel"])
        #expect(!window.isKeyWindow)
        hud.render(.hidden)
    }
}
