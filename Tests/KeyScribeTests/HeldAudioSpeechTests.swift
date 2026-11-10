import Foundation
import Testing
@testable import KeyScribeApp

@MainActor
struct HeldAudioSpeechTests {
    @Test func itPlaysTheExactHeldBytesOnceAndReportsTheEnd() {
        let player = NaturalSpeechTests.FakePlayer()
        let speech = HeldAudioSpeech(player: player)
        var started = 0
        var finished = 0
        speech.onStarted = { started += 1 }
        speech.onFinished = { finished += 1 }
        speech.prepare(Data("RIFF-held".utf8))
        speech.speak("", voice: nil)
        #expect(player.played == [Data("RIFF-held".utf8)])
        #expect(started == 1)
        #expect(speech.isSpeaking)
        player.finish()
        #expect(finished == 1)
        speech.speak("", voice: nil)
        #expect(player.played.count == 1)
    }

    @Test func stoppingEndsItOnceAndAPlayerThatRefusesEndsAtOnce() {
        let player = NaturalSpeechTests.FakePlayer()
        let speech = HeldAudioSpeech(player: player)
        var finished = 0
        speech.onFinished = { finished += 1 }
        speech.prepare(Data("RIFF".utf8))
        speech.speak("", voice: nil)
        speech.stop()
        speech.stop()
        #expect(finished == 1)
        player.accepts = false
        speech.prepare(Data("RIFF".utf8))
        speech.speak("", voice: nil)
        #expect(finished == 2)
    }
}
