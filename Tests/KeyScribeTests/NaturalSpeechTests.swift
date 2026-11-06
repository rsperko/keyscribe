import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct NaturalSpeechTests {
    final class FakePlayer: AudioPlaying {
        var onFinished: (() -> Void)?
        var played: [Data] = []
        var isPlaying = false
        var accepts = true
        func play(_ audio: Data) -> Bool {
            guard accepts else { return false }
            played.append(audio)
            isPlaying = true
            return true
        }
        func stop() { isPlaying = false }
        func finish() {
            isPlaying = false
            onFinished?()
        }
    }

    final class Synth: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(text: String, voice: String)] = []
        private var held: [CheckedContinuation<Void, Never>] = []
        private var holding = false
        var holds: Bool {
            get { lock.withLock { holding } }
            set { lock.withLock { holding = newValue } }
        }
        var fails = false
        var calls: [(text: String, voice: String)] { lock.withLock { _calls } }
        func run(_ text: String, _ voice: String) async throws -> Data {
            lock.withLock { _calls.append((text, voice)) }
            await withCheckedContinuation { continuation in
                let waits = lock.withLock { () -> Bool in
                    if holding { held.append(continuation) }
                    return holding
                }
                if !waits { continuation.resume() }
            }
            if fails { throw CocoaError(.fileReadCorruptFile) }
            return Data(text.utf8)
        }
        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                holding = false
                defer { held = [] }
                return held
            }
            for continuation in pending { continuation.resume() }
        }
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func settled() async {
        for _ in 0..<200 { await Task.yield() }
    }

    private func make(
        ready: Bool = true, synth: Synth = Synth(), outcome: @escaping (Bool) -> Void = { _ in },
        fallbackLimit: @escaping (String) -> Duration = NaturalSpeech.fallbackLimit,
        synthesisLimit: @escaping (String) -> Duration = NaturalSpeech.fallbackLimit
    ) -> (NaturalSpeech, FakePlayer, SpokenResultOutputTests.FakeSpeech, Synth) {
        let player = FakePlayer()
        let fallback = SpokenResultOutputTests.FakeSpeech()
        let speech = NaturalSpeech(
            ready: { ready }, synthesize: { try await synth.run($0, $1) }, player: player, fallback: fallback, outcome: outcome,
            fallbackLimit: fallbackLimit, synthesisLimit: synthesisLimit)
        return (speech, player, fallback, synth)
    }

    @Test func aSuccessfulRetryReplacesTheMacOSVoiceStillSpeaking() async {
        let synth = Synth()
        synth.fails = true
        let (speech, player, fallback, _) = make(synth: synth)
        var finished = 0
        speech.onFinished = { finished += 1 }
        speech.speak("One.", voice: nil)
        await until { fallback.isSpeaking }
        #expect(fallback.isSpeaking)
        synth.fails = false
        speech.speak("Two.", voice: nil)
        #expect(!fallback.isSpeaking)
        await until { player.isPlaying }
        #expect(player.isPlaying)
        fallback.finish()
        #expect(finished == 0)
        #expect(speech.isSpeaking)
    }

    @Test func aRequestDuringPlaybackStopsTheOldAudioAndIgnoresItsCompletion() async {
        let synth = Synth()
        let (speech, player, _, _) = make(synth: synth)
        var finished = 0
        speech.onFinished = { finished += 1 }
        speech.speak("One.", voice: nil)
        await until { player.isPlaying }
        #expect(player.isPlaying)
        synth.holds = true
        speech.speak("Two.", voice: nil)
        #expect(!player.isPlaying)
        player.onFinished?()
        #expect(finished == 0)
        #expect(speech.isSpeaking)
        await settled()
        synth.release()
        await until { player.played.last == Data("Two.".utf8) }
        #expect(player.played.last == Data("Two.".utf8))
        player.finish()
        #expect(finished == 1)
    }

    @Test func aMacOSVoiceThatNeverFinishesIsEndedAfterItsLimit() async {
        let (speech, _, fallback, _) = make(ready: false, fallbackLimit: { _ in .milliseconds(50) })
        var finished = 0
        speech.onFinished = { finished += 1 }
        speech.speak("Done.", voice: nil)
        #expect(speech.isSpeaking)
        try? await Task.sleep(for: .milliseconds(300))
        await settled()
        #expect(!speech.isSpeaking)
        #expect(!fallback.isSpeaking)
        #expect(finished == 1)
    }

    @Test func anEarlierUtterancesLimitNeverEndsTheOneSpeakingNow() async {
        let (speech, _, fallback, _) = make(
            ready: false, fallbackLimit: { $0 == "Two." ? .milliseconds(50) : .seconds(30) })
        var finished = 0
        speech.onFinished = { finished += 1 }
        speech.speak("Two.", voice: nil)
        fallback.finish()
        speech.speak("Three.", voice: nil)
        try? await Task.sleep(for: .milliseconds(300))
        await until { finished == 1 }
        #expect(finished == 1)
        #expect(speech.isSpeaking)
    }

    @Test func theMacOSVoiceLimitGrowsWithTheText() {
        #expect(NaturalSpeech.fallbackLimit(String(repeating: "word ", count: 40)) > NaturalSpeech.fallbackLimit("Done."))
        #expect(NaturalSpeech.fallbackLimit("Done.") >= .seconds(10))
    }

    @Test func itReportsStartingOnlyWhenTheAudioActuallyPlays() async {
        let synth = Synth()
        synth.holds = true
        let (speech, _, _, _) = make(synth: synth)
        var started = 0
        speech.onStarted = { started += 1 }
        speech.speak("Done.", voice: nil)
        await until { speech.isSpeaking }
        #expect(speech.isSpeaking)
        #expect(started == 0)
        synth.release()
        for _ in 0..<400 where started == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(started == 1)
    }

    @Test func theSystemVoiceStartingIsReported() {
        let (speech, _, fallback, _) = make(ready: false)
        var started = 0
        speech.onStarted = { started += 1 }
        speech.speak("Done.", voice: nil)
        fallback.start()
        #expect(started == 1)
    }

    @Test func aReadyVoiceThatFallsBackSaysSoAndOneThatPlaysSaysItPlayed() async {
        let synth = Synth()
        var outcomes: [Bool] = []
        let (speech, _, _, _) = make(synth: synth, outcome: { outcomes.append($0) })
        speech.speak("One.", voice: nil)
        await until { outcomes == [true] }
        synth.fails = true
        speech.speak("Two.", voice: nil)
        await until { outcomes == [true, false] }
        #expect(outcomes == [true, false])
    }

    @Test func aVoiceNotYetInstalledReportsNoFallback() async {
        var outcomes: [Bool] = []
        let (speech, _, _, _) = make(ready: false, outcome: { outcomes.append($0) })
        speech.speak("Done.", voice: nil)
        await settled()
        #expect(outcomes.isEmpty)
    }

    @Test func aReadyVoiceSpeaksTheTextInTheChosenVoice() async {
        let (speech, player, fallback, synth) = make()
        speech.speak("Build passed.", voice: "bf_emma")
        await until { player.played == [Data("Build passed.".utf8)] }
        #expect(synth.calls.map { "\($0.text)|\($0.voice)" } == ["Build passed.|bf_emma"])
        #expect(player.played == [Data("Build passed.".utf8)])
        #expect(fallback.spoken.isEmpty)
    }

    @Test func aVoiceNotInTheListSpeaksInTheRecommendedOne() async {
        let (speech, _, _, synth) = make()
        speech.speak("Done.", voice: "com.apple.voice.compact.en-US.Samantha")
        await until { synth.calls.map(\.voice) == ["af_heart"] }
        #expect(synth.calls.map(\.voice) == ["af_heart"])
    }

    @Test func beforeTheVoiceIsReadyTheSystemVoiceSpeaks() async {
        let (speech, player, fallback, synth) = make(ready: false)
        speech.speak("Done.", voice: "bf_emma")
        await until { fallback.spoken.map(\.text) == ["Done."] }
        #expect(fallback.spoken.map(\.text) == ["Done."])
        #expect(fallback.spoken.first?.voice == nil)
        #expect(synth.calls.isEmpty)
        #expect(player.played.isEmpty)
    }

    @Test func aVoiceThatFailsToSynthesizeFallsBackToTheSystemVoice() async {
        let synth = Synth()
        synth.fails = true
        let (speech, player, fallback, _) = make(synth: synth)
        speech.speak("Done.", voice: nil)
        await until { fallback.spoken.map(\.text) == ["Done."] }
        #expect(fallback.spoken.map(\.text) == ["Done."])
        #expect(player.played.isEmpty)
    }

    @Test func itIsSpeakingFromTheRequestUntilPlaybackFinishes() async {
        let synth = Synth()
        synth.holds = true
        let (speech, player, _, _) = make(synth: synth)
        var finished = 0
        speech.onFinished = { finished += 1 }
        speech.speak("Done.", voice: nil)
        await until { speech.isSpeaking }
        #expect(speech.isSpeaking)
        synth.release()
        for _ in 0..<400 where !player.isPlaying { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(speech.isSpeaking)
        player.finish()
        #expect(!speech.isSpeaking)
        #expect(finished == 1)
    }

    @Test func stoppingWhileTheVoiceIsBeingMadePlaysNothing() async {
        let synth = Synth()
        synth.holds = true
        let (speech, player, _, _) = make(synth: synth)
        var finished = 0
        speech.onFinished = { finished += 1 }
        speech.speak("Done.", voice: nil)
        await settled()
        speech.stop()
        #expect(!speech.isSpeaking)
        synth.release()
        await settled()
        #expect(player.played.isEmpty)
        #expect(finished == 1)
    }

    @Test func aVoiceThatIsNeverMadeFallsBackToTheSystemVoiceAfterItsLimit() async {
        let synth = Synth()
        synth.holds = true
        var outcomes: [Bool] = []
        let (speech, player, fallback, _) = make(
            synth: synth, outcome: { outcomes.append($0) }, synthesisLimit: { _ in .milliseconds(30) })
        speech.speak("Done.", voice: nil)
        for _ in 0..<200 where fallback.spoken.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(fallback.spoken.map(\.text) == ["Done."])
        #expect(outcomes == [false])
        fallback.finish()
        #expect(!speech.isSpeaking)
        synth.release()
        await settled()
        #expect(player.played.isEmpty)
    }

    @Test func voicesStillBeingMadePastTheirLimitAreNotJoinedByMore() async {
        let synth = Synth()
        synth.holds = true
        let (speech, _, fallback, _) = make(synth: synth, synthesisLimit: { _ in .milliseconds(20) })
        for text in ["One.", "Two."] {
            speech.speak(text, voice: nil)
            for _ in 0..<200 where fallback.spoken.last?.text != text { try? await Task.sleep(for: .milliseconds(5)) }
        }
        speech.speak("Three.", voice: nil)
        await until { synth.calls.map(\.text) == ["One.", "Two."] }
        #expect(synth.calls.map(\.text) == ["One.", "Two."])
        #expect(fallback.spoken.last?.text == "Three.")
        synth.release()
        await until { speech.unfinishedSyntheses == 0 }
        speech.speak("Four.", voice: nil)
        await until { synth.calls.map(\.text) == ["One.", "Two.", "Four."] }
        #expect(synth.calls.map(\.text) == ["One.", "Two.", "Four."])
    }

    @Test func aNewRequestReplacesOneStillBeingMade() async {
        let synth = Synth()
        synth.holds = true
        let (speech, player, _, _) = make(synth: synth)
        speech.speak("First.", voice: nil)
        await settled()
        synth.holds = false
        speech.stop()
        speech.speak("Second.", voice: nil)
        await settled()
        synth.release()
        await until { player.played == [Data("Second.".utf8)] }
        #expect(player.played == [Data("Second.".utf8)])
    }

    @Test func stoppingStopsBothThePlayerAndTheSystemVoice() async {
        let (speech, player, fallback, _) = make()
        speech.speak("Done.", voice: nil)
        await settled()
        let before = fallback.stops
        speech.stop()
        #expect(!player.isPlaying)
        #expect(fallback.stops == before + 1)
    }

    @Test func theSystemVoiceFinishingIsReported() async {
        let (speech, _, fallback, _) = make(ready: false)
        var finished = 0
        speech.onFinished = { finished += 1 }
        speech.speak("Done.", voice: nil)
        fallback.finish()
        #expect(finished == 1)
    }

    @Test func speakingAgainReplacesTheResultStillBeingMade() async {
        let (speech, player, _, _) = make()
        speech.speak("one", voice: nil)
        speech.speak("two", voice: nil)
        await until { player.played == [Data("two".utf8)] }
        #expect(player.played == [Data("two".utf8)])
    }

    @Test func stoppingWhilePlayingReportsFinishedOnce() async {
        let (speech, player, _, _) = make()
        speech.speak("one", voice: nil)
        await until { player.isPlaying }
        #expect(player.isPlaying)
        var finished = 0
        speech.onFinished = { finished += 1 }
        speech.stop()
        speech.stop()
        #expect(finished == 1)
    }
}

@MainActor
struct WAVPlayerTests {
    private func silentWAV(samples: Int = 16_000) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000)); append(UInt32(32_000))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        data.append(Data(count: bytes))
        return data
    }

    @Test func aDecodeErrorEndsPlaybackLikeAFinish() async throws {
        let player = WAVPlayer()
        var finished = 0
        player.onFinished = { finished += 1 }
        #expect(player.play(silentWAV()))
        let current = try #require(player.current)
        player.audioPlayerDecodeErrorDidOccur(current, error: CocoaError(.fileReadCorruptFile))
        for _ in 0..<50 { await Task.yield() }
        #expect(finished == 1)
        #expect(!player.isPlaying)
        player.stop()
    }
}
