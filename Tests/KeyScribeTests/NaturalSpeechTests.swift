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
        var lastPlaybackFailed = false
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
        var failsOn: String?
        var holdsOn: String?
        var error: (any Error)?
        var exclusive = false
        private var running = 0
        var calls: [(text: String, voice: String)] { lock.withLock { _calls } }
        func run(_ text: String, _ voice: String) async throws -> SpokenAudio {
            let busy = lock.withLock { () -> Bool in
                if exclusive && running > 0 { return true }
                running += 1
                _calls.append((text, voice))
                return false
            }
            if busy { throw WorkBusy() }
            defer { lock.withLock { running -= 1 } }
            await withCheckedContinuation { continuation in
                let waits = lock.withLock { () -> Bool in
                    let waits = holding || holdsOn.map { text.contains($0) } == true
                    if waits { held.append(continuation) }
                    return waits
                }
                if !waits { continuation.resume() }
            }
            if let error { throw error }
            if fails || failsOn.map({ text.contains($0) }) == true { throw CocoaError(.fileReadCorruptFile) }
            return SpokenAudio(wav: Data(text.utf8))
        }
        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                holding = false
                holdsOn = nil
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
        ready: Bool = true, synth: Synth = Synth(), outcome: @escaping (Bool, String?, String?) -> Void = { _, _, _ in },
        fallbackLimit: @escaping (String) -> Duration = NaturalSpeech.fallbackLimit,
        synthesisLimit: @escaping (String) -> Duration = NaturalSpeech.fallbackLimit, attempts: SpokenAttempts? = nil,
        busyWait: Duration = NaturalSpeech.busyWait, followingLimit: @escaping (String) -> Duration = NaturalSpeech.followingLimit,
        sentenceAtATime: Bool = false
    ) -> (NaturalSpeech, FakePlayer, SpokenResultOutputTests.FakeSpeech, Synth) {
        let player = FakePlayer()
        let fallback = SpokenResultOutputTests.FakeSpeech()
        let speech = NaturalSpeech(
            ready: { ready }, synthesize: { try await synth.run($0, $1) }, player: player, fallback: fallback, outcome: outcome,
            fallbackLimit: fallbackLimit, synthesisLimit: synthesisLimit, attempts: attempts, busyWait: busyWait,
            details: { natural in natural ? [.init(label: "Output", value: "USB DAC, 48000 Hz")] : [] },
            followingLimit: followingLimit, sentenceAtATime: sentenceAtATime)
        return (speech, player, fallback, synth)
    }

    private let answer = "Reply to Dana by Friday. Then ship the release. Ask Sam about the date."

    @Test func aLongAnswerStartsPlayingAfterItsFirstSentence() async {
        let synth = Synth()
        let (speech, player, _, _) = make(synth: synth, sentenceAtATime: true)
        var started = 0
        var finished = 0
        speech.onStarted = { started += 1 }
        speech.onFinished = { finished += 1 }
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        #expect(player.played == [Data("Reply to Dana by Friday.".utf8)])
        await until { synth.calls.count == 3 }
        #expect(synth.calls.map(\.text) == ["Reply to Dana by Friday.", "Then ship the release.", "Ask Sam about the date."])
        player.finish()
        await until { player.played.count == 2 }
        #expect(player.played.last == Data("Then ship the release.".utf8))
        #expect(speech.isSpeaking)
        player.finish()
        await until { player.played.count == 3 }
        #expect(player.played.last == Data("Ask Sam about the date.".utf8))
        player.finish()
        #expect(player.played.count == 3)
        #expect(started == 1)
        #expect(finished == 1)
        #expect(!speech.isSpeaking)
    }

    @Test func aSentenceNotReadyYetIsWaitedForWithoutEndingTheAnswer() async {
        let synth = Synth()
        let (speech, player, _, _) = make(synth: synth, sentenceAtATime: true)
        var finished = 0
        speech.onFinished = { finished += 1 }
        synth.holdsOn = "ship"
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        await until { synth.calls.count == 2 }
        player.finish()
        #expect(speech.isSpeaking)
        #expect(finished == 0)
        synth.release()
        await until { player.played.count == 2 }
        #expect(player.played.last == Data("Then ship the release.".utf8))
    }

    @Test func stoppingAnAnswerDropsTheSentencesStillToCome() async {
        let synth = Synth()
        let (speech, player, _, _) = make(synth: synth, sentenceAtATime: true)
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        await until { synth.calls.count == 3 }
        speech.stop()
        player.onFinished?()
        await settled()
        #expect(player.played.count == 1)
        #expect(!speech.isSpeaking)
    }

    @Test func aLaterSentenceTheNaturalVoiceCannotMakeIsReadByTheMacOSVoice() async {
        let synth = Synth()
        let (speech, player, fallback, _) = make(synth: synth, sentenceAtATime: true)
        synth.failsOn = "ship"
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        await until { synth.calls.count >= 2 }
        await settled()
        player.finish()
        await until { fallback.isSpeaking }
        #expect(fallback.spoken.map(\.text) == ["Then ship the release. Ask Sam about the date."])
        #expect(speech.isSpeaking)
    }

    @Test func aSentenceThatWillNotPlayIsReadByTheMacOSVoiceWithTheRest() async {
        let synth = Synth()
        let (speech, player, fallback, _) = make(synth: synth, sentenceAtATime: true)
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        await until { synth.calls.count == 3 }
        await settled()
        player.accepts = false
        player.finish()
        await until { fallback.isSpeaking }
        #expect(fallback.spoken.map(\.text) == ["Then ship the release. Ask Sam about the date."])
    }

    @Test func aSentenceThatFailsWhilePlayingIsReadAgainWithTheRest() async {
        let synth = Synth()
        let (speech, player, fallback, _) = make(synth: synth, sentenceAtATime: true)
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        await until { synth.calls.count == 3 }
        await settled()
        player.lastPlaybackFailed = true
        player.finish()
        await until { fallback.isSpeaking }
        #expect(fallback.spoken.map(\.text) == [answer])
    }

    @Test func aLaterSentenceThatStallsIsReadByTheMacOSVoiceSoon() async {
        let synth = Synth()
        synth.holdsOn = "ship"
        let (speech, player, fallback, _) = make(
            synth: synth, followingLimit: { _ in .milliseconds(50) }, sentenceAtATime: true)
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        player.finish()
        await until { fallback.isSpeaking }
        #expect(fallback.spoken.map(\.text) == ["Then ship the release. Ask Sam about the date."])
        synth.release()
    }

    @Test func aStoppedAnswerStillCountsItsSentenceUntilTheVoiceLetsGo() async {
        let synth = Synth()
        synth.holdsOn = "ship"
        let (speech, player, _, _) = make(synth: synth, sentenceAtATime: true)
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        await until { synth.calls.count == 2 }
        speech.stop()
        #expect(speech.unfinishedSyntheses == 1)
        synth.release()
        await until { speech.unfinishedSyntheses == 0 }
        #expect(speech.unfinishedSyntheses == 0)
    }

    @Test func askingAgainRightAfterStoppingStillUsesTheNaturalVoice() async {
        let synth = Synth()
        synth.exclusive = true
        synth.holdsOn = "ship"
        let (speech, player, fallback, _) = make(synth: synth, sentenceAtATime: true)
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        await until { synth.calls.count == 2 }
        speech.stop()
        speech.speak("A second answer for you. It has two sentences.", voice: nil)
        try? await Task.sleep(for: .milliseconds(100))
        synth.release()
        await until { player.played.count == 2 }
        #expect(player.played.last == Data("A second answer for you.".utf8))
        #expect(fallback.spoken.isEmpty)
    }

    @Test func withoutSentencePlaybackTheWholeAnswerIsMadeAtOnce() async {
        let synth = Synth()
        let (speech, player, _, _) = make(synth: synth)
        speech.speak(answer, voice: nil)
        await until { player.isPlaying }
        #expect(synth.calls.map(\.text) == [answer])
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
        let (speech, _, _, _) = make(synth: synth, outcome: { natural, _, _ in outcomes.append(natural) })
        speech.speak("One.", voice: nil)
        await until { outcomes == [true] }
        synth.fails = true
        speech.speak("Two.", voice: nil)
        await until { outcomes == [true, false] }
        #expect(outcomes == [true, false])
    }

    @Test func aVoiceNotYetInstalledReportsNoFallback() async {
        var outcomes: [Bool] = []
        let (speech, _, _, _) = make(ready: false, outcome: { natural, _, _ in outcomes.append(natural) })
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
            synth: synth, outcome: { natural, _, _ in outcomes.append(natural) }, synthesisLimit: { _ in .milliseconds(30) })
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

    private func recorded(_ speech: NaturalSpeech, in attempts: SpokenAttempts) -> SpokenAttempt? {
        speech.attempt.flatMap { attempts.attempt($0) }
    }

    @Test func aPlayedReplyIsKeptWithTheExactAudioItPlayedUntilItFinishes() async throws {
        let attempts = SpokenAttempts()
        let (speech, player, _, _) = make(attempts: attempts)
        speech.speak("Build passed.", voice: "bf_emma")
        await until { player.isPlaying }
        let playing = try #require(recorded(speech, in: attempts))
        #expect(playing.text == "Build passed.")
        #expect(playing.voice == "bf_emma")
        #expect(playing.audio == player.played.last)
        #expect(playing.reader == .natural)
        #expect(playing.playback == .playing)
        #expect(playing.details == [.init(label: "Output", value: "USB DAC, 48000 Hz")])
        attempts.awaitLink(speech.attempt)
        player.finish()
        #expect(recorded(speech, in: attempts)?.playback == .finished)
    }

    @Test func unusableAudioIsReadByTheMacOSVoiceAndKeptWithTheReason() async throws {
        let attempts = SpokenAttempts()
        let synth = Synth()
        synth.error = SpokenAudio.Unusable(problem: .silent, audio: SpokenAudio(wav: Data("quiet".utf8)))
        var outcomes: [Bool] = []
        let (speech, player, fallback, _) = make(synth: synth, outcome: { natural, _, _ in outcomes.append(natural) }, attempts: attempts)
        speech.speak("Done.", voice: nil)
        await until { fallback.spoken.map(\.text) == ["Done."] }
        #expect(player.played.isEmpty)
        #expect(outcomes == [false])
        let attempt = try #require(recorded(speech, in: attempts))
        #expect(attempt.reader == .macOS)
        #expect(attempt.macOSReason == "the natural voice made silent audio")
        #expect(speech.macOSReason == "the natural voice made silent audio")
        #expect(attempt.audio == Data("quiet".utf8))
        fallback.start()
        attempts.awaitLink(speech.attempt)
        #expect(recorded(speech, in: attempts)?.playback == .playing)
        fallback.finish()
        #expect(recorded(speech, in: attempts)?.playback == .finished)
    }

    @Test func aVoiceStillBusyWithAnEarlierReplySaysSo() async {
        let attempts = SpokenAttempts()
        let synth = Synth()
        synth.error = WorkBusy()
        let (speech, _, fallback, _) = make(synth: synth, attempts: attempts, busyWait: .milliseconds(30))
        speech.speak("Done.", voice: nil)
        await until { !fallback.spoken.isEmpty }
        #expect(recorded(speech, in: attempts)?.macOSReason == "the natural voice was still busy with earlier audio")
    }

    @Test func aVoiceNotInstalledIsReadByTheMacOSVoiceAndSaysWhy() {
        let attempts = SpokenAttempts()
        let (speech, _, _, _) = make(ready: false, attempts: attempts)
        speech.speak("Done.", voice: nil)
        #expect(recorded(speech, in: attempts)?.reader == .macOS)
        #expect(recorded(speech, in: attempts)?.macOSReason == "the natural voice isn\u{2019}t installed")
        #expect(recorded(speech, in: attempts)?.details.isEmpty == true)
    }

    @Test func anAttemptNothingSavesIsDroppedOnceItsPlaybackEnds() async {
        let attempts = SpokenAttempts()
        let (speech, player, _, _) = make(attempts: attempts)
        speech.speak("Repeat of an earlier reply.", voice: nil)
        await until { player.isPlaying }
        let replay = speech.attempt
        player.finish()
        #expect(replay.flatMap { attempts.attempt($0) } == nil)
        speech.speak("Stopped before it played.", voice: nil)
        let stopped = speech.attempt
        speech.stop()
        #expect(stopped.flatMap { attempts.attempt($0) } == nil)
    }

    @Test func stoppingAReplyMidwayRecordsItAsInterruptedAndAFailedDecodeAsFailed() async {
        let attempts = SpokenAttempts()
        let (speech, player, _, _) = make(attempts: attempts)
        speech.speak("One.", voice: nil)
        await until { player.isPlaying }
        let first = speech.attempt
        attempts.awaitLink(first)
        speech.stop()
        #expect(first.flatMap { attempts.attempt($0) }?.playback == .interrupted)
        speech.speak("Two.", voice: nil)
        await until { player.isPlaying }
        attempts.awaitLink(speech.attempt)
        player.lastPlaybackFailed = true
        player.finish()
        #expect(recorded(speech, in: attempts)?.playback == .failed)
    }

    @Test func aReplyRightAfterAStopWaitsForTheStoppedOneToSettleAndUsesTheNaturalVoice() async {
        let synth = Synth()
        synth.exclusive = true
        synth.holds = true
        let (speech, player, fallback, _) = make(synth: synth)
        speech.speak("One.", voice: nil)
        await until { synth.calls.count == 1 }
        speech.stop()
        synth.holds = false
        speech.speak("Two.", voice: nil)
        try? await Task.sleep(for: .milliseconds(60))
        synth.release()
        await until { player.played == [Data("Two.".utf8)] }
        #expect(player.played == [Data("Two.".utf8)])
        #expect(fallback.spoken.isEmpty)
    }

    @Test func aVoiceBusyPastItsWaitGoesToTheMacOSVoice() async {
        let attempts = SpokenAttempts()
        let synth = Synth()
        synth.exclusive = true
        synth.holds = true
        let (speech, _, fallback, _) = make(synth: synth, attempts: attempts, busyWait: .milliseconds(40))
        speech.speak("One.", voice: nil)
        await until { synth.calls.count == 1 }
        speech.stop()
        speech.speak("Two.", voice: nil)
        await until { !fallback.spoken.isEmpty }
        #expect(fallback.spoken.map(\.text) == ["Two."])
        #expect(recorded(speech, in: attempts)?.macOSReason == "the natural voice was still busy with earlier audio")
        synth.release()
    }

    @Test func aReplyMadeWhileAnEarlierOneIsStillFinishingIsNoted() async {
        let attempts = SpokenAttempts()
        let synth = Synth()
        synth.holds = true
        let (speech, _, fallback, _) = make(synth: synth, synthesisLimit: { _ in .milliseconds(20) }, attempts: attempts)
        speech.speak("One.", voice: nil)
        await until { !fallback.spoken.isEmpty }
        #expect(recorded(speech, in: attempts)?.macOSReason == "the natural voice took too long")
        speech.speak("Two.", voice: nil)
        #expect(recorded(speech, in: attempts)?.notes == ["Started while an earlier synthesis was still finishing."])
        synth.release()
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
        #expect(player.lastPlaybackFailed)
        #expect(!player.isPlaying)
        player.stop()
    }
}
