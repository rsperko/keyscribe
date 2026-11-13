import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct TextOnlyResultsTests {
    typealias FakeSpeech = SpokenResultOutputTests.FakeSpeech
    typealias FakeLLM = SpokenResultOutputTests.FakeLLM
    typealias SettingsBox = SpokenResultOutputTests.SettingsBox

    final class Log {
        var events: [String] = []
    }

    private func agents(
        _ box: SettingsBox, silencer: SpeechSilencer = SpeechSilencer(), mayShow: @escaping () -> Bool = { true }
    ) -> (SpokenResultOutput, FakeSpeech, Log) {
        let speech = FakeSpeech()
        let log = Log()
        let output = SpokenResultOutput(
            client: FakeLLM(), permits: { _ in true }, speech: speech, silencer: silencer, settings: { box.value },
            connection: { _ in nil }, warm: { log.events.append("warm") }, release: { log.events.append("release") },
            duck: { log.events.append($0 ? "duck" : "unduck") }, duckGrace: .zero, mayShow: mayShow)
        output.onSpeaking = { speaking in
            guard let speaking else { return log.events.append("hide") }
            log.events.append("\(speaking.textOnly ? "text" : "voice") \(speaking.name): \(speaking.text)")
        }
        output.onHeard = { log.events.append("heard \($0.text) reader:\($0.reader?.rawValue ?? "-")") }
        return (output, speech, log)
    }

    private func settled() async {
        for _ in 0..<200 { await Task.yield() }
    }

    private static let textOnly = SpokenResultSettings(enabled: true, voice: "bf_emma", textOnly: true)

    @Test func aTextOnlyReplyIsShownAtOnceWithoutTouchingTheVoiceOrOtherAudio() async {
        let (output, speech, log) = agents(SettingsBox(Self.textOnly))
        output.finished(conversation: "pi:s1", handle: "api", answer: "Done. Tests pass.", origin: "r1")
        await settled()
        #expect(speech.spoken.isEmpty)
        #expect(log.events == ["text api: Done. Tests pass.", "heard api: Done. Tests pass. reader:-"])
    }

    @Test func textOnlyRepliesWaitTheirTurnInOrderAndTheNextAppearsWhenThePanelCloses() async {
        let (output, speech, log) = agents(SettingsBox(Self.textOnly))
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        output.attention(conversation: "pi:s3", handle: "web", .approval)
        await settled()
        #expect(log.events.filter { !$0.hasPrefix("heard") } == ["text api: First."])
        #expect(output.displayed == .init(name: "api", text: "First.", textOnly: true))
        output.dismissed()
        await settled()
        output.dismissed()
        await settled()
        output.dismissed()
        await settled()
        #expect(log.events.filter { !$0.hasPrefix("heard") } == [
            "text api: First.", "hide", "text docs: Second.", "hide", "text web: Waiting for approval.", "hide",
        ])
        #expect(output.displayed == nil)
        #expect(speech.spoken.isEmpty)
    }

    @Test func aNewerReplyFromAWaitingConversationReplacesItsOlderOneWithoutReplaying() async {
        let (output, _, log) = agents(SettingsBox(Self.textOnly))
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Old docs.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: "New docs.")
        await settled()
        output.dismissed()
        await settled()
        output.dismissed()
        await settled()
        #expect(log.events.filter { $0.hasPrefix("text") } == ["text api: First.", "text docs: New docs."])
    }

    @Test func stopClearsTheShownReplyAndEverythingWaiting() async {
        let (output, _, log) = agents(SettingsBox(Self.textOnly))
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        await settled()
        output.stop()
        output.dismissed()
        await settled()
        #expect(log.events.filter { !$0.hasPrefix("heard") } == ["text api: First.", "hide"])
        #expect(output.displayed == nil)
    }

    @Test func forgettingTheShownConversationMovesToTheNextReply() async {
        let (output, _, log) = agents(SettingsBox(Self.textOnly))
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        await settled()
        output.forget(conversation: "pi:s1")
        await settled()
        #expect(log.events.filter { !$0.hasPrefix("heard") } == ["text api: First.", "hide", "text docs: Second."])
    }

    @Test func aReplyFromTheConversationInFrontIsStillSkippedWhenTextOnly() async {
        let speech = FakeSpeech()
        var shown: [String] = []
        let output = SpokenResultOutput(
            client: FakeLLM(), permits: { _ in true }, speech: speech, silencer: SpeechSilencer(), settings: { Self.textOnly },
            connection: { _ in nil }, inFront: { $0 == "pi:s1" })
        output.onSpeaking = { if let speaking = $0 { shown.append(speaking.text) } }
        output.finished(conversation: "pi:s1", handle: "api", answer: "In front.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Docs done.")
        await settled()
        #expect(shown == ["Docs done."])
    }

    @Test func choosingTextOnlyStopsTheReplyBeingSpokenShowsItAndKeepsTheQueue() async {
        let box = SettingsBox(SpokenResultSettings(enabled: true, voice: "bf_emma"))
        let (output, speech, log) = agents(box)
        output.finished(conversation: "pi:s1", handle: "api", answer: "Spoken.")
        await settled()
        speech.start()
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Shown.")
        await settled()
        box.value.textOnly = true
        output.settingsChanged()
        await settled()
        #expect(!speech.isSpeaking)
        #expect(speech.spoken.count == 1)
        #expect(output.displayed == .init(name: "api", text: "Spoken.", textOnly: true))
        #expect(log.events.filter { $0.hasPrefix("heard") }.count == 1)
        output.dismissed()
        await settled()
        #expect(output.displayed == .init(name: "docs", text: "Shown.", textOnly: true))
        output.finished(conversation: "pi:s3", handle: "web", answer: "Spoken again.")
        await settled()
        box.value.textOnly = false
        output.settingsChanged()
        output.dismissed()
        await settled()
        #expect(speech.spoken.map(\.text) == ["api: Spoken.", "web: Spoken again."])
    }

    @Test func choosingTextOnlyShowsAReplyHandedToTheVoiceButNotYetAudible() async {
        let box = SettingsBox(SpokenResultSettings(enabled: true))
        let (output, speech, log) = agents(box)
        output.finished(conversation: "pi:s1", handle: "api", answer: "Preparing.")
        await settled()
        box.value.textOnly = true
        output.settingsChanged()
        await settled()
        #expect(!speech.isSpeaking)
        #expect(output.displayed == .init(name: "api", text: "Preparing.", textOnly: true))
        #expect(log.events.filter { $0.hasPrefix("heard") } == ["heard api: Preparing. reader:-"])
    }

    @Test func repeatingAShownUpdateAfterChoosingAVoiceSpeaksIt() async {
        let box = SettingsBox(Self.textOnly)
        let (output, speech, log) = agents(box)
        output.finished(conversation: "pi:s1", handle: "api", answer: "Shown.")
        await settled()
        output.dismissed()
        box.value.textOnly = false
        output.settingsChanged()
        #expect(output.repeatLast() == .repeating("api"))
        await settled()
        #expect(speech.spoken.map(\.text) == ["api: Shown."])
        speech.start()
        #expect(log.events.last == "voice api: Shown.")
        #expect(log.events.contains("duck"))
        #expect(output.displayed == nil)
    }

    @Test func turningTextOnlyOnLetsTheWarmVoiceGoAndNeverWarmsIt() async {
        let box = SettingsBox(SpokenResultSettings(enabled: true))
        let (output, _, log) = agents(box)
        #expect(log.events == ["warm"])
        box.value.textOnly = true
        output.settingsChanged()
        output.finished(conversation: "pi:s1", handle: "api", answer: "Shown.")
        await settled()
        #expect(log.events.filter { $0 == "warm" || $0 == "release" } == ["warm", "release"])
    }

    @Test func aTextOnlyReplyIsShownEvenWhileSomethingElseIsSpeaking() async {
        let silencer = SpeechSilencer()
        let other = FakeSpeech()
        silencer.register(other)
        let (output, _, log) = agents(SettingsBox(Self.textOnly), silencer: silencer)
        silencer.speak("A preview.", voice: nil, with: other)
        output.finished(conversation: "pi:s1", handle: "api", answer: "Shown.")
        await settled()
        #expect(log.events.first == "text api: Shown.")
    }

    @Test func dictationHoldsTextOnlyRepliesAndClosesTheOneShownWithoutLosingTheRest() async {
        let silencer = SpeechSilencer()
        let (output, _, log) = agents(SettingsBox(Self.textOnly), silencer: silencer)
        silencer.recordingStarted()
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        #expect(log.events.isEmpty)
        silencer.recordingEnded()
        await settled()
        #expect(log.events == ["text api: First.", "heard api: First. reader:-"])
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        await settled()
        silencer.dictationHUD(visible: true)
        await settled()
        #expect(log.events.last == "hide")
        #expect(output.displayed == nil)
        silencer.dictationHUD(visible: false)
        await settled()
        #expect(log.events.suffix(2) == ["text docs: Second.", "heard docs: Second. reader:-"])
    }

    @Test func aReplyWaitingBehindAnAnswerIsNeitherShownNorRecordedUntilThePanelIsFree() async {
        var free = false
        let (output, _, log) = agents(SettingsBox(Self.textOnly), mayShow: { free })
        output.finished(conversation: "pi:s1", handle: "api", answer: "Waiting.")
        await settled()
        #expect(log.events.isEmpty)
        free = true
        output.panelFreed()
        await settled()
        #expect(log.events == ["text api: Waiting.", "heard api: Waiting. reader:-"])
    }

    @MainActor private final class SharedPanel {
        let box: SettingsBox
        let silencer = SpeechSilencer()
        let answerSpeech = FakeSpeech()
        let answers: SpokenAnswerOutput
        var agents: SpokenResultOutput!
        var agentSpeech: FakeSpeech!
        let log = Log()
        var answerOnPanel = false

        init(_ settings: SpokenResultSettings) {
            box = SettingsBox(settings)
            let box = box
            answers = SpokenAnswerOutput(speech: answerSpeech, silencer: silencer, voice: { nil }, textOnly: { box.value.textOnly })
            let speech = FakeSpeech()
            agentSpeech = speech
            agents = SpokenResultOutput(
                client: FakeLLM(), permits: { _ in true }, speech: speech, silencer: silencer, settings: { box.value },
                connection: { _ in nil }, duckGrace: .zero,
                mayShow: { [unowned self] in
                    !self.answerOnPanel || (!self.answers.isActive && !self.answers.showsText)
                })
            agents.onSpeaking = { [unowned self] in
                guard let speaking = $0, !self.answerOnPanel || !self.answers.isActive && !self.answers.showsText else { return }
                self.answerOnPanel = false
                self.log.events.append("\(speaking.textOnly ? "text" : "voice") \(speaking.name): \(speaking.text)")
            }
            agents.onHeard = { [unowned self] in self.log.events.append("heard \($0.text)") }
            answers.onShow = { [unowned self] name, _, _ in
                self.answerOnPanel = true
                self.agents.yieldPanel()
                self.log.events.append("answer \(name)")
            }
            answers.onClosed = { [unowned self] in
                self.answerOnPanel = false
                self.agents.panelFreed()
            }
        }

        func choose(textOnly: Bool) {
            box.value.textOnly = textOnly
            agents.settingsChanged()
            answers.settingsChanged()
        }
    }

    @Test func choosingTextOnlyWhileAnAnswerSpeaksKeepsItsPanelAndTheWaitingUpdateFollowsIt() async {
        let panel = SharedPanel(SpokenResultSettings(enabled: true))
        panel.answers.answer("Reply by Friday.", name: "Ask", since: .now())
        panel.answerSpeech.start()
        panel.agents.finished(conversation: "pi:s1", handle: "api", answer: "Waiting.")
        await settled()
        panel.choose(textOnly: true)
        await settled()
        #expect(panel.answers.showsText)
        #expect(!panel.log.events.contains { $0.hasPrefix("text api") || $0.hasPrefix("heard") })
        panel.answers.close()
        await settled()
        #expect(panel.log.events.suffix(2) == ["text api: Waiting.", "heard api: Waiting."])
        panel.agents.finished(conversation: "pi:s2", handle: "docs", answer: "Next.")
        panel.agents.dismissed()
        await settled()
        #expect(panel.log.events.last == "heard docs: Next.")
    }

    @Test func anAnswerTakingThePanelFromAShownUpdateHandsItBackAfterward() async {
        let panel = SharedPanel(Self.textOnly)
        panel.agents.finished(conversation: "pi:s1", handle: "api", answer: "Shown.")
        await settled()
        panel.agents.finished(conversation: "pi:s2", handle: "docs", answer: "Next.")
        await settled()
        panel.answers.answer("Reply by Friday.", name: "Ask", since: .now())
        await settled()
        #expect(panel.log.events.last == "answer Ask")
        panel.answers.close()
        await settled()
        #expect(panel.log.events.last == "text api: Shown.")
        panel.agents.dismissed()
        await settled()
        #expect(panel.log.events.suffix(2) == ["text docs: Next.", "heard docs: Next."])
        #expect(panel.log.events.filter { $0 == "heard api: Shown." }.count == 1)
    }

    private func answers(textOnly: Bool) -> (SpokenAnswerOutput, FakeSpeech, Log, (Bool) -> Void) {
        let speech = FakeSpeech()
        let log = Log()
        var textOnly = textOnly
        let output = SpokenAnswerOutput(
            speech: speech, silencer: SpeechSilencer(), voice: { "bf_emma" }, textOnly: { textOnly },
            warm: { log.events.append("warm") }, release: { log.events.append("release") },
            duck: { log.events.append($0 ? "duck" : "unduck") })
        output.onShow = { name, text, spoken in log.events.append("\(spoken ? "voice" : "text") \(name): \(text)") }
        output.onSpeaking = { log.events.append("speaking") }
        output.onEnded = { log.events.append("ended") }
        output.onClosed = { log.events.append("closed") }
        return (output, speech, log, { textOnly = $0 })
    }

    @Test func aTextOnlyAnswerIsShownWithoutWarmingSpeakingOrLoweringAudio() {
        let (output, speech, log, _) = answers(textOnly: true)
        output.prepare()
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        #expect(log.events == ["text Ask: Reply by Friday."])
        #expect(speech.spoken.isEmpty)
        #expect(output.showsText)
        #expect(!output.isActive)
        output.close()
        #expect(log.events.last == "closed")
        #expect(!output.showsText)
    }

    @Test func aTextOnlyAnswerLetsGoOfAVoiceWarmedBeforeTheChoiceChanged() {
        let (output, _, log, setTextOnly) = answers(textOnly: false)
        output.prepare()
        setTextOnly(true)
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        #expect(log.events == ["warm", "release", "text Ask: Reply by Friday."])
    }

    @Test func choosingTextOnlyStopsAnAnswerBeingSpokenAndLeavesItsText() {
        let (output, speech, log, setTextOnly) = answers(textOnly: false)
        output.prepare()
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        speech.start()
        setTextOnly(true)
        output.settingsChanged()
        #expect(!speech.isSpeaking)
        #expect(output.showsText)
        #expect(log.events.last == "text Ask: Reply by Friday.")
        #expect(log.events.contains("unduck"))
        #expect(log.events.contains("release"))
    }

    @Test func anAnswerWaitingToSpeakIsShownAsTextOnceTextOnlyIsChosen() {
        let silencer = SpeechSilencer()
        let speech = FakeSpeech()
        var textOnly = false
        var shown: [String] = []
        let output = SpokenAnswerOutput(speech: speech, silencer: silencer, voice: { nil }, textOnly: { textOnly })
        output.onShow = { name, text, spoken in shown.append("\(spoken ? "voice" : "text") \(name): \(text)") }
        silencer.dictationHUD(visible: true)
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        textOnly = true
        silencer.dictationHUD(visible: false)
        #expect(speech.spoken.isEmpty)
        #expect(shown == ["voice Ask: Reply by Friday.", "text Ask: Reply by Friday."])
        #expect(output.showsText)
    }

    @Test func switchingBackToAVoiceSpeaksTheNextAnswer() {
        let (output, speech, log, setTextOnly) = answers(textOnly: true)
        output.answer("First.", name: "Ask", since: .now())
        setTextOnly(false)
        output.answer("Second.", name: "Ask", since: .now())
        #expect(speech.spoken.map(\.text) == ["Second."])
        #expect(log.events.contains("voice Ask: Second."))
        #expect(!output.showsText)
    }

    private func panel(readingTime: Duration = .milliseconds(50), voiceOver: Bool = false)
        -> (SpeakingHUDController, FakeChordRegistrar, () -> Int)
    {
        let escape = FakeChordRegistrar()
        let hud = SpeakingHUDController(escape: escape, defaults: UserDefaults(suiteName: "text-only-\(UUID().uuidString)")!, displays: .unfocused)
        hud.readingTime = { _ in readingTime }
        hud.voiceOverRunning = { voiceOver }
        var closed = 0
        hud.onClose = { closed += 1 }
        hud.showText(name: "api", text: "Done. Tests pass.")
        return (hud, escape, { closed })
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aTextOnlyPanelShowsItsTextWithCloseAndCopyAndAnHonestStatus() {
        let (hud, escape, closed) = panel(readingTime: .seconds(60))
        defer { hud.hide() }
        #expect(hud.shownName == "api")
        #expect(hud.showsSummary)
        #expect(hud.isFinished)
        #expect(hud.offersCopy)
        #expect(hud.status == SpeakingHUDLayout.textOnlyWithEscape)
        #expect(!hud.status.localizedCaseInsensitiveContains("speak"))
        escape.lastRegistrations.first?.onPressed()
        #expect(closed() == 1)
    }

    @Test func aTextOnlyPanelStartsItsCountdownAsSoonAsItAppears() async {
        let (hud, _, closed) = panel()
        defer { hud.hide() }
        await settle { closed() == 1 }
        #expect(closed() == 1)
    }

    @Test func hoverAndVoiceOverHoldATextOnlyPanel() async {
        let (hovered, _, hoveredClosed) = panel()
        defer { hovered.hide() }
        hovered.hover(true)
        let (spoken, _, voiceOverClosed) = panel(voiceOver: true)
        defer { spoken.hide() }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(hoveredClosed() == 0)
        #expect(voiceOverClosed() == 0)
        hovered.hover(false)
        await settle { hoveredClosed() == 1 }
        #expect(hoveredClosed() == 1)
    }

    @Test func aSpokenAnswerStillWaitsForPlaybackBeforeItsCountdown() async {
        let escape = FakeChordRegistrar()
        let hud = SpeakingHUDController(escape: escape, defaults: UserDefaults(suiteName: "text-only-\(UUID().uuidString)")!, displays: .unfocused)
        defer { hud.hide() }
        hud.readingTime = { _ in .milliseconds(30) }
        hud.voiceOverRunning = { false }
        var closed = 0
        hud.onClose = { closed += 1 }
        hud.showText(name: "api", text: "Shown.")
        hud.show(name: "Ask", summary: "Spoken.", answer: true, preparing: true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(closed == 0)
        #expect(hud.status == SpeakingHUDLayout.preparingWithEscape)
    }

    @Test func theVoicePickerOffersTextOnlyFirstAndKeepsTheNamedVoice() {
        let model = CodingAgentsSettingsModel(
            agentsDir: FileManager.default.temporaryDirectory.appendingPathComponent("text-only-\(UUID().uuidString)"), connectors: [])
        model.load(spokenResult: SpokenResultSettings(enabled: true, voice: "bf_emma"))
        var saved: [SpokenResultSettings] = []
        model.onSpokenResultChange = { saved.append($0) }
        #expect(model.voiceChoice == "bf_emma")
        model.voiceChoice = CodingAgentsSettingsModel.textOnlyChoice
        #expect(model.spokenResult.textOnly)
        #expect(model.spokenResult.voice == "bf_emma")
        #expect(model.voiceChoice == CodingAgentsSettingsModel.textOnlyChoice)
        model.voiceChoice = "bf_emma"
        #expect(!model.spokenResult.textOnly)
        #expect(saved.map(\.textOnly) == [true, false])
        #expect(SpokenVoices.all.allSatisfy { $0.id != CodingAgentsSettingsModel.textOnlyChoice })
    }
}
