import Foundation
import Testing
@testable import KeyScribeApp

@MainActor
struct HistorySpeechTests {
    private func make(accepts: Bool = true) -> (HistorySpeech, NaturalSpeechTests.FakePlayer, SpokenResultOutputTests.FakeSpeech, SpeechSilencer) {
        let (speech, player, voice, silencer, _) = makeWithAudio(accepts: accepts)
        return (speech, player, voice, silencer)
    }

    private func makeWithAudio(accepts: Bool = true)
        -> (HistorySpeech, NaturalSpeechTests.FakePlayer, SpokenResultOutputTests.FakeSpeech, SpeechSilencer, HeldAudioSpeech)
    {
        let player = NaturalSpeechTests.FakePlayer()
        player.accepts = accepts
        let voice = SpokenResultOutputTests.FakeSpeech()
        let silencer = SpeechSilencer()
        let audio = HeldAudioSpeech(player: player)
        return (HistorySpeech(audio: audio, voice: voice, silencer: silencer), player, voice, silencer, audio)
    }

    @Test func heldAudioPlaysAndReportsItsEnd() {
        let (speech, player, _, _) = make()
        var ended = 0
        #expect(speech.play(Data("RIFF".utf8), onEnd: { ended += 1 }) == .started)
        #expect(player.played == [Data("RIFF".utf8)])
        player.finish()
        #expect(ended == 1)
    }

    @Test func aPlayerThatRefusesIsReportedAsFailedNotAsPlaying() {
        let (speech, _, _, _) = make(accepts: false)
        var ended = 0
        #expect(speech.play(Data("RIFF".utf8), onEnd: { ended += 1 }) == .failed)
    }

    @Test func nothingStartsWhileDictating() {
        let (speech, player, voice, silencer) = make()
        silencer.recordingStarted()
        #expect(speech.play(Data("RIFF".utf8), onEnd: {}) == .dictating)
        #expect(speech.read("docs: Done.", onEnd: {}) == .dictating)
        #expect(player.played.isEmpty)
        #expect(voice.spoken.isEmpty)
    }

    @Test func theMacOSVoiceReadsAndOneStopEndsWhicheverIsSpeaking() {
        let (speech, player, voice, _) = make()
        var ended: [String] = []
        #expect(speech.read("docs: Done.", onEnd: { ended.append("voice") }) == .started)
        #expect(voice.spoken.map(\.text) == ["docs: Done."])
        speech.stop()
        #expect(ended == ["voice"])
        #expect(speech.play(Data("RIFF".utf8), onEnd: { ended.append("audio") }) == .started)
        speech.stop()
        #expect(ended == ["voice", "audio"])
        #expect(!player.isPlaying)
    }

    @Test func audioRefusedWhileDictatingIsNotKeptForLater() {
        let (speech, player, _, silencer, audio) = makeWithAudio()
        silencer.recordingStarted()
        #expect(speech.play(Data("RIFF".utf8), onEnd: {}) == .dictating)
        silencer.recordingEnded()
        audio.speak("", voice: nil)
        #expect(player.played.isEmpty)
    }

    @Test func switchingFromTheAudioToTheMacOSVoiceLeavesAQueuedReplyQueued() {
        let (speech, _, voice, silencer) = make()
        let reply = SpokenResultOutputTests.FakeSpeech()
        silencer.register(reply)
        silencer.onAvailable = { if silencer.isAvailable(for: reply) { reply.speak("api: Done.", voice: nil) } }
        var ended: [String] = []
        #expect(speech.play(Data("RIFF".utf8), onEnd: { ended.append("audio") }) == .started)
        #expect(speech.read("docs: Done.", onEnd: { ended.append("voice") }) == .started)
        #expect(reply.spoken.isEmpty)
        #expect(voice.spoken.map(\.text) == ["docs: Done."])
        #expect(ended.isEmpty)
        voice.finish()
        #expect(ended == ["voice"])
    }
}
