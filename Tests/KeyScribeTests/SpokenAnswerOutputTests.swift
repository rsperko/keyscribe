import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct SpokenAnswerOutputTests {
    typealias FakeSpeech = SpokenResultOutputTests.FakeSpeech

    private func make(silencer: SpeechSilencer = SpeechSilencer(), voice: String? = "voice.one")
        -> (SpokenAnswerOutput, FakeSpeech, Log)
    {
        let speech = FakeSpeech()
        let log = Log()
        let output = SpokenAnswerOutput(
            speech: speech, silencer: silencer, voice: { voice }, warm: { log.events.append("warm") },
            release: { log.releases += 1 }, duck: { log.events.append($0 ? "duck" : "unduck") })
        output.onShow = { name, text, _ in log.events.append("show \(name): \(text)") }
        output.onSpeaking = { log.events.append("speaking") }
        output.onEnded = { log.events.append("ended") }
        output.onClosed = { log.events.append("closed") }
        return (output, speech, log)
    }

    final class Log {
        var events: [String] = []
        var releases = 0
    }

    @Test func theAnswerIsShownAtOnceAndReadInTheChosenVoice() {
        let (output, speech, log) = make()
        output.answer("Reply by Friday.", name: "Ask About Selection", since: .now())
        #expect(log.events == ["show Ask About Selection: Reply by Friday."])
        #expect(speech.spoken.map(\.text) == ["Reply by Friday."])
        #expect(speech.spoken.map(\.voice) == ["voice.one"])
        speech.start()
        #expect(log.events.suffix(2) == ["duck", "speaking"])
        speech.finish()
        #expect(log.events.suffix(2) == ["unduck", "ended"])
    }

    @Test func pressingTheShortcutWarmsTheVoice() {
        let (output, _, log) = make()
        output.prepare()
        #expect(log.events == ["warm"])
    }

    @Test func theAnswerWaitsForTheDictationPanelToClose() {
        let silencer = SpeechSilencer()
        let (output, speech, log) = make(silencer: silencer)
        silencer.dictationHUD(visible: true)
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        #expect(log.events == ["show Ask: Reply by Friday."])
        #expect(speech.spoken.isEmpty)
        silencer.dictationHUD(visible: false)
        #expect(speech.spoken.map(\.text) == ["Reply by Friday."])
    }

    @Test func aNewRecordingDropsAnAnswerNotYetPlayed() {
        let silencer = SpeechSilencer()
        let (output, speech, log) = make(silencer: silencer)
        silencer.dictationHUD(visible: true)
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        output.stop()
        silencer.recordingStarted()
        silencer.dictationHUD(visible: false)
        silencer.recordingEnded()
        #expect(speech.spoken.isEmpty)
        #expect(log.events.last == "ended")
    }

    @Test func anAnswerAsksForWhatItInterruptsToBeResumed() {
        let silencer = SpeechSilencer()
        let agent = silencer.registered(FakeSpeech())
        var resumed: [Bool] = []
        agent.onFinished = { resumed.append(silencer.resumesInterrupted) }
        silencer.speak("backend: Done.", voice: nil, with: agent)
        let (output, _, _) = make(silencer: silencer)
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        #expect(resumed == [true])
    }

    @Test func anAnswerInterruptsAnAgentReplyAndTheReplyQueueWaitsUntilItEnds() {
        let silencer = SpeechSilencer()
        let agent = silencer.registered(FakeSpeech())
        var agentCalls = 0
        silencer.onAvailable = { agentCalls += 1 }
        silencer.speak("backend: Done.", voice: nil, with: agent)
        let (output, speech, _) = make(silencer: silencer)
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        #expect(!agent.isSpeaking)
        #expect(speech.isSpeaking)
        #expect(!silencer.isAvailable(for: agent))
        let before = agentCalls
        speech.finish()
        #expect(agentCalls == before + 1)
        #expect(silencer.isAvailable(for: agent))
    }

    @Test func stoppingSilencesTheAnswer() {
        let (output, speech, log) = make()
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        speech.start()
        output.stop()
        #expect(!speech.isSpeaking)
        #expect(log.events.suffix(2) == ["unduck", "ended"])
    }

    @Test func aNewAnswerReplacesTheOneStillPlaying() {
        let (output, speech, _) = make()
        output.answer("First.", name: "Ask", since: .now())
        speech.start()
        output.answer("Second.", name: "Ask", since: .now())
        #expect(speech.spoken.map(\.text) == ["First.", "Second."])
        #expect(speech.isSpeaking)
    }

    @Test func theFirstSoundIsTimedFromTheGivenMoment() {
        let (output, speech, _) = make()
        var timings: [Double] = []
        output.onFirstAudio = { timings.append($0) }
        let since = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds - 1_500_000_000)
        output.answer("Reply by Friday.", name: "Ask", since: since)
        speech.start()
        speech.finish()
        output.answer("Again.", name: "Ask", since: .now())
        #expect(timings.count == 1)
        #expect(timings.first.map { $0 >= 1500 } == true)
    }
}

extension SpokenAnswerOutputTests {
    @Test func aVoiceThatRestartsMidAnswerIsTimedAndAnnouncedOnce() {
        let (output, speech, log) = make()
        var timings = 0
        output.onFirstAudio = { _ in timings += 1 }
        output.answer("Reply by Friday. Then ship it.", name: "Ask", since: .now())
        speech.start()
        speech.start()
        #expect(timings == 1)
        #expect(log.events.filter { $0 == "speaking" }.count == 1)
    }
}

extension SpokenAnswerOutputTests {
    @Test func theVoiceReadsTheAnswerWithoutMarkupWhileThePanelShowsItAsWritten() {
        let (output, speech, log) = make()
        output.answer("Run `make test`, then see https://example.com/runbook.", name: "Ask", since: .now())
        #expect(log.events.first == "show Ask: Run `make test`, then see https://example.com/runbook.")
        #expect(speech.spoken.map(\.text) == ["Run make test, then see a link."])
    }

    @Test func closingStopsTheAnswerAndClosesThePanel() {
        let (output, speech, log) = make()
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        speech.start()
        output.close()
        #expect(!speech.isSpeaking)
        #expect(log.events.suffix(2) == ["ended", "closed"])
    }

    @Test func theVoiceIsLetGoOnceTheAnswerEnds() {
        let (output, speech, log) = make()
        output.prepare()
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        speech.start()
        #expect(log.releases == 0)
        speech.finish()
        #expect(log.releases == 1)
    }

    @Test func aTakeThatEndsWithoutAnAnswerLetsTheWarmedVoiceGo() {
        let (output, _, log) = make()
        output.prepare()
        output.takeEnded()
        output.takeEnded()
        #expect(log.events == ["warm"])
        #expect(log.releases == 1)
    }

    @Test func aTakeEndingWhileItsAnswerPlaysKeepsTheVoice() {
        let (output, speech, log) = make()
        output.prepare()
        output.answer("Reply by Friday.", name: "Ask", since: .now())
        output.takeEnded()
        #expect(log.releases == 0)
        speech.finish()
        #expect(log.releases == 1)
    }
}
