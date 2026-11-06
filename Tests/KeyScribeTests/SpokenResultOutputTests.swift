import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct SpokenResultOutputTests {
    final class FakeLLM: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [(system: String, user: String)] = []
        private var held: CheckedContinuation<Void, Never>?
        var reply = "It ran the suite and everything passed."
        var replies: [String] = []
        var fails = false
        var holds = false
        var requests: [(system: String, user: String)] { lock.withLock { _requests } }
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            lock.withLock { _requests.append((system, user)) }
            if holds { await withCheckedContinuation { continuation in lock.withLock { held = continuation } } }
            if fails { throw URLError(.notConnectedToInternet) }
            return lock.withLock { replies.isEmpty ? reply : replies.removeFirst() }
        }
        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let pending = held
                held = nil
                return pending
            }
            continuation?.resume()
        }
    }

    final class FakeSpeech: SpeechSynthesizing {
        var onStarted: (() -> Void)?
        var onFinished: (() -> Void)?
        var isSpeaking = false
        var spoken: [(text: String, voice: String?)] = []
        var stops = 0
        func speak(_ text: String, voice: String?) {
            spoken.append((text, voice))
            isSpeaking = true
        }
        func stop() {
            stops += 1
            guard isSpeaking else { return }
            isSpeaking = false
            onFinished?()
        }
        func start() { onStarted?() }
        func finish() {
            isSpeaking = false
            onFinished?()
        }
    }

    @MainActor final class FrontGate {
        private var waiting: [CheckedContinuation<Bool, Never>] = []
        func wait() async -> Bool { await withCheckedContinuation { waiting.append($0) } }
        func open() {
            let all = waiting
            waiting = []
            for continuation in all { continuation.resume(returning: false) }
        }
    }

    final class SettingsBox {
        var value: SpokenResultSettings
        init(_ value: SpokenResultSettings) { self.value = value }
    }

    private let connection = Connection(id: "omlx", name: "Local", provider: .openaiCompatible, model: "qwen", keyRef: "k")

    private func make(
        settings: SpokenResultSettings = SpokenResultSettings(connection: "omlx"), llm: FakeLLM = FakeLLM(), permits: Bool = true,
        silencer: SpeechSilencer = SpeechSilencer(), deadlineSeconds: Double = 30, describeDeadlineSeconds: Double = 30,
        inFront: @escaping @MainActor (String) async -> Bool = { _ in false }
    ) -> (SpokenResultOutput, FakeSpeech, FakeLLM) {
        let speech = FakeSpeech()
        let connection = connection
        let output = SpokenResultOutput(
            client: llm, permits: { _ in permits }, speech: speech, silencer: silencer, settings: { settings },
            connection: { $0 == connection.id ? connection : nil }, deadlineSeconds: deadlineSeconds,
            describeDeadlineSeconds: describeDeadlineSeconds, inFront: inFront)
        return (output, speech, llm)
    }

    private func settled() async {
        for _ in 0..<200 { await Task.yield() }
    }

    @Test func aShortReplyIsSpokenAtOnceInTheChosenVoiceWithoutAskingTheModel() async {
        let (output, speech, llm) = make(settings: SpokenResultSettings(connection: "omlx", voice: "voice.one"))
        output.finished(conversation: "pi:s1", handle: "api", answer: "Done. `make test` passes.")
        await settled()
        #expect(speech.spoken.map { "\($0.text)|\($0.voice ?? "-")" } == ["api: Done. make test passes.|voice.one"])
        #expect(llm.requests.isEmpty)
    }

    @Test func aLongReplyIsSummarizedWithTheInstructionAndRedactedFirst() async {
        let (output, speech, llm) = make(settings: SpokenResultSettings(connection: "omlx", prompt: "Two sentences."))
        let long = "I set the token to sk-abcdefghijklmnopqrstuvwxyz1234 in the config. " + Array(repeating: "Then more words.", count: 20).joined(separator: " ")
        llm.reply = "It set the token to ⟦SN:REDACT:1⟧ and went on."
        output.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        #expect(llm.requests.count == 1)
        #expect(llm.requests[0].system.hasPrefix("Two sentences."))
        #expect(!llm.requests[0].user.contains("sk-abcdef"))
        #expect(speech.spoken.map(\.text) == ["api: It set the token to a hidden value and went on."])
    }

    @Test func aConversationInFrontWhenItFinishesIsNeitherSpokenNorSentForASummary() async {
        let (output, speech, llm) = make(inFront: { $0 == "pi:s1" })
        output.finished(conversation: "pi:s1", handle: "api", answer: "Done.")
        output.finished(conversation: "pi:s1", handle: "api", answer: long)
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Docs done.")
        await settled()
        #expect(speech.spoken.map(\.text) == ["docs: Docs done."])
        #expect(llm.requests.isEmpty)
        #expect(output.pendingSummaries == 0)
    }

    @Test func aResultStillCheckingWhatIsInFrontIsReplacedByANewerOneAndDroppedByStop() async {
        let gate = FrontGate()
        let (output, speech, llm) = make(inFront: { _ in await gate.wait() })
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        output.finished(conversation: "pi:s1", handle: "api", answer: "Second.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: long)
        await settled()
        output.stop()
        gate.open()
        await settled()
        #expect(speech.spoken.isEmpty)
        #expect(llm.requests.isEmpty)
        output.finished(conversation: "pi:s1", handle: "api", answer: "Third.")
        output.finished(conversation: "pi:s1", handle: "api", answer: "Fourth.")
        await settled()
        gate.open()
        await settled()
        #expect(speech.spoken.map(\.text) == ["api: Fourth."])
    }

    @Test func repeatReplaysTheLastSummaryHeardAheadOfThoseWaiting() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        #expect(output.repeatLast() == .nothingHeard)
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        #expect(output.repeatLast() == .nothingHeard)
        speech.start()
        output.stop()
        silencer.recordingStarted()
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Docs done.")
        await settled()
        #expect(output.repeatLast() == .repeating("api"))
        silencer.recordingEnded()
        speech.start()
        speech.finish()
        speech.start()
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["api: First.", "api: First.", "docs: Docs done."])
        #expect(output.repeatLast() == .repeating("docs"))
    }

    @Test func aReplayWaitingForTheDictationHUDIsNotReplacedByANewerResultForThatConversation() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        speech.start()
        speech.finish()
        silencer.dictationHUD(visible: true)
        #expect(output.repeatLast() == .repeating("api"))
        output.finished(conversation: "pi:s1", handle: "api", answer: "Second.")
        await settled()
        silencer.dictationHUD(visible: false)
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["api: First.", "api: First.", "api: Second."])
    }

    @Test func aReplayedUnavailableNoticeIsReadExactlyAsHeardAndLeavesOthersWaiting() async {
        let silencer = SpeechSilencer()
        let failing = FakeLLM()
        failing.fails = true
        let (output, speech, _) = make(llm: failing, silencer: silencer)
        silencer.recordingStarted()
        output.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        output.finished(conversation: "pi:s2", handle: "docs", answer: long)
        await settled()
        silencer.recordingEnded()
        speech.start()
        speech.finish()
        silencer.recordingStarted()
        output.finished(conversation: "pi:s3", handle: "web", answer: long)
        await settled()
        #expect(output.repeatLast() == .repeating("api and docs"))
        silencer.recordingEnded()
        speech.finish()
        #expect(speech.spoken.map(\.text) == [
            "api and docs: The spoken summaries are unavailable.", "api and docs: The spoken summaries are unavailable.",
            "web: The spoken summary is unavailable.",
        ])
    }

    @Test func repeatSaysSummariesAreOffAndPlaysNothingWhileTheyAre() async {
        let box = SettingsBox(SpokenResultSettings(connection: "omlx"))
        let speech = FakeSpeech()
        let output = SpokenResultOutput(
            client: FakeLLM(), permits: { _ in true }, speech: speech, silencer: SpeechSilencer(), settings: { box.value },
            connection: { $0 == "omlx" ? Connection(id: "omlx", name: "Local", provider: .openaiCompatible, model: "qwen", keyRef: "k") : nil })
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        speech.start()
        speech.finish()
        box.value.enabled = false
        output.settingsChanged()
        #expect(output.repeatLast() == .off)
        #expect(speech.spoken.count == 1)
    }

    @Test func aNoticeIsSpokenWithTheSwitchAloneAndNeverAsksTheService() async {
        let (output, speech, llm) = make(settings: SpokenResultSettings(enabled: true))
        output.attention(conversation: "pi:s1", handle: "api", .approval)
        await settled()
        #expect(speech.spoken.map(\.text) == ["api: Waiting for approval."])
        #expect(llm.requests.isEmpty)
        let (off, offSpeech, _) = make(settings: SpokenResultSettings(enabled: false, connection: "omlx"))
        off.attention(conversation: "pi:s1", handle: "api", .question)
        await settled()
        #expect(offSpeech.spoken.isEmpty)
    }

    @Test func aPromptTheAgentWaitsOnIsDescribedByTheServiceAfterRedaction() async {
        let llm = FakeLLM()
        llm.reply = "Asks to allow deleting the build folder."
        let (output, speech, _) = make(llm: llm)
        let prompt = AgentPrompt(
            kind: "select", title: "Allow?", tool: "bash", detail: "rm -rf build sk-abcdefghijklmnopqrstuvwxyz1234",
            said: "Clearing it with ghp_abcdefghijklmnopqrstuvwxyz0123456789.")
        output.attention(conversation: "pi:s1", handle: "api", .waiting(prompt))
        await settled()
        #expect(speech.spoken.map(\.text) == ["api: Asks to allow deleting the build folder."])
        #expect(llm.requests.count == 1)
        #expect(llm.requests.first?.system.hasPrefix(SpokenResult.waitingPrompt) == true)
        #expect(llm.requests.first?.user.contains("rm -rf build") == true)
        #expect(llm.requests.first?.user.contains("sk-abcdef") == false)
        #expect(llm.requests.first?.user.contains("Clearing it with") == true)
        #expect(llm.requests.first?.user.contains("ghp_abcdef") == false)
    }

    @Test func aPromptIsReadAsWaitingForYouWithoutAServiceOrWhenItsDescriptionFails() async {
        let (bare, bareSpeech, bareLLM) = make(settings: SpokenResultSettings(enabled: true))
        bare.attention(conversation: "pi:s1", handle: "api", .waiting(AgentPrompt(title: "Allow?")))
        await settled()
        #expect(bareSpeech.spoken.map(\.text) == ["api: Waiting for you."])
        #expect(bareLLM.requests.isEmpty)
        let failing = FakeLLM()
        failing.fails = true
        let (output, speech, _) = make(llm: failing)
        output.attention(conversation: "pi:s1", handle: "api", .waiting(AgentPrompt(title: "Allow?")))
        await settled()
        #expect(speech.spoken.map(\.text) == ["api: Waiting for you."])
        let (untitled, untitledSpeech, untitledLLM) = make()
        untitled.attention(conversation: "pi:s1", handle: "api", .waiting(AgentPrompt()))
        await settled()
        #expect(untitledSpeech.spoken.map(\.text) == ["api: Waiting for you."])
        #expect(untitledLLM.requests.isEmpty)
    }

    @Test func aSlowServiceGetsAShortBudgetBeforeThePromptIsReadAsWaitingForYou() async {
        let slow = FakeLLM()
        slow.holds = true
        let (output, speech, _) = make(llm: slow, describeDeadlineSeconds: 0.05)
        output.attention(conversation: "pi:s1", handle: "api", .waiting(AgentPrompt(title: "Allow?")))
        for _ in 0..<100 where speech.spoken.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(speech.spoken.map(\.text) == ["api: Waiting for you."])
        slow.release()
    }

    @Test func aPromptAnsweredWhileItIsBeingDescribedIsNeverRead() async {
        let slow = FakeLLM()
        slow.holds = true
        let (output, speech, _) = make(llm: slow)
        output.attention(conversation: "pi:s1", handle: "api", .waiting(AgentPrompt(title: "Allow?")))
        await settled()
        output.attention(conversation: "pi:s1", handle: "api", nil)
        slow.release()
        await settled()
        #expect(speech.spoken.isEmpty)
    }

    @Test func aNoticeForAConversationInFrontIsSkipped() async {
        let (output, speech, _) = make(inFront: { $0 == "pi:s1" })
        output.attention(conversation: "pi:s1", handle: "api", .approval)
        output.attention(conversation: "pi:s2", handle: "docs", .disconnected)
        await settled()
        #expect(speech.spoken.map(\.text) == ["docs: Disconnected before it finished."])
    }

    @Test func aNoticeThatClearsBeforeItPlaysIsWithdrawnAndASummaryWaitingStays() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        silencer.recordingStarted()
        output.attention(conversation: "pi:s1", handle: "api", .approval)
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Docs done.")
        output.attention(conversation: "pi:s3", handle: "web", .question)
        await settled()
        output.attention(conversation: "pi:s1", handle: "api", nil)
        output.attention(conversation: "pi:s2", handle: "docs", nil)
        silencer.recordingEnded()
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["docs: Docs done.", "web: Waiting for an answer."])
    }

    @Test func aNoticeHandedToTheVoiceButNotYetAudibleIsStoppedWhenItClears() async {
        let (output, speech, _) = make()
        var shown: [SpokenResultOutput.Speaking?] = []
        output.onSpeaking = { shown.append($0) }
        output.attention(conversation: "pi:s1", handle: "api", .approval)
        await settled()
        #expect(speech.isSpeaking)
        output.attention(conversation: "pi:s1", handle: "api", nil)
        #expect(!speech.isSpeaking)
        speech.start()
        #expect(shown.isEmpty)
    }

    @Test func aRequestedReplayOfANoticeStillPlaysWhenTheNoticeClears() async {
        let (output, speech, _) = make()
        output.attention(conversation: "pi:s1", handle: "api", .approval)
        await settled()
        speech.start()
        speech.finish()
        #expect(output.repeatLast() == .repeating("api"))
        output.attention(conversation: "pi:s1", handle: "api", nil)
        #expect(speech.isSpeaking)
        speech.start()
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["api: Waiting for approval.", "api: Waiting for approval."])
    }

    @Test func aNewerNoticeSupersedesAnOlderSummaryStillBeingMade() async {
        let silencer = SpeechSilencer()
        let slow = FakeLLM()
        slow.holds = true
        let (output, speech, _) = make(llm: slow, silencer: silencer)
        silencer.recordingStarted()
        output.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        output.attention(conversation: "pi:s1", handle: "api", .approval)
        await settled()
        slow.release()
        await settled()
        silencer.recordingEnded()
        #expect(speech.spoken.map(\.text) == ["api: Waiting for approval."])
    }

    @Test func aNoticeStillBeingCheckedIsDroppedWhenItClears() async {
        let gate = FrontGate()
        let (output, speech, _) = make(inFront: { _ in await gate.wait() })
        output.attention(conversation: "pi:s1", handle: "api", .approval)
        await settled()
        output.attention(conversation: "pi:s1", handle: "api", nil)
        gate.open()
        await settled()
        #expect(speech.spoken.isEmpty)
    }

    @Test func nothingIsSpokenWhenOff() async {
        let off = make(settings: SpokenResultSettings(enabled: false, connection: "omlx"))
        off.0.finished(conversation: "pi:s1", handle: "api", answer: "Done.")
        await settled()
        #expect(off.1.spoken.isEmpty && off.2.requests.isEmpty)
    }

    @Test func withoutAServiceAShortReplyIsReadAsItIsAndALongerOneIsAnnouncedAsFinished() async {
        let short = make(settings: SpokenResultSettings(enabled: true))
        short.0.finished(conversation: "pi:s1", handle: "api", answer: "Done.")
        await settled()
        let longer = make(settings: SpokenResultSettings(enabled: true))
        longer.0.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        #expect(short.1.spoken.map(\.text) == ["api: Done."])
        #expect(longer.1.spoken.map(\.text) == ["api: Finished."])
        #expect(short.2.requests.isEmpty && longer.2.requests.isEmpty)
    }

    @Test func aChosenServiceThatIsGoneOrRefusedStillReadsAShortReplyAndSaysTheSummaryIsUnavailable() async {
        for (settings, permits) in [(SpokenResultSettings(connection: "gone"), true), (SpokenResultSettings(connection: "omlx"), false)] {
            let short = make(settings: settings, permits: permits)
            short.0.finished(conversation: "pi:s1", handle: "api", answer: "Done.")
            await settled()
            let longer = make(settings: settings, permits: permits)
            longer.0.finished(conversation: "pi:s1", handle: "api", answer: long)
            await settled()
            #expect(short.1.spoken.map(\.text) == ["api: Done."])
            #expect(longer.1.spoken.map(\.text) == ["api: The spoken summary is unavailable."])
            #expect(short.2.requests.isEmpty && longer.2.requests.isEmpty)
        }
    }

    private var long: String { Array(repeating: "word", count: 60).joined(separator: " ") }

    @Test func aSummaryThatFailsTimesOutOrComesBackEmptySaysItIsUnavailable() async {
        let failing = FakeLLM()
        failing.fails = true
        let broken = make(llm: failing)
        broken.0.finished(conversation: "pi:s1", handle: "keyscribe blue", answer: long)
        await settled()
        let empty = FakeLLM()
        empty.reply = "  "
        let blank = make(llm: empty)
        blank.0.finished(conversation: "pi:s1", handle: "keyscribe blue", answer: long)
        await settled()
        let slow = FakeLLM()
        slow.holds = true
        let late = make(llm: slow, deadlineSeconds: 0.05)
        late.0.finished(conversation: "pi:s1", handle: "keyscribe blue", answer: long)
        await settled()
        try? await Task.sleep(for: .milliseconds(300))
        await settled()
        slow.release()
        for speech in [broken.1, blank.1, late.1] {
            #expect(speech.spoken.map(\.text) == ["keyscribe blue: The spoken summary is unavailable."])
        }
    }

    @Test func unavailableNoticesWaitingTogetherAreReadAsOneNamingEachConversation() async {
        let silencer = SpeechSilencer()
        let failing = FakeLLM()
        failing.fails = true
        let (output, speech, _) = make(llm: failing, silencer: silencer)
        var shown: [SpokenResultOutput.Speaking?] = []
        output.onSpeaking = { shown.append($0) }
        silencer.recordingStarted()
        output.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Docs done.")
        output.finished(conversation: "pi:s3", handle: "web", answer: long)
        await settled()
        output.finished(conversation: "pi:s4", handle: "cli", answer: long)
        await settled()
        output.finished(conversation: "pi:s4", handle: "cli", answer: "Cli done.")
        await settled()
        silencer.recordingEnded()
        speech.start()
        #expect(shown == [SpokenResultOutput.Speaking(name: "api and web", text: "The spoken summaries are unavailable.")])
        speech.finish()
        speech.finish()
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["api and web: The spoken summaries are unavailable.", "docs: Docs done.", "cli: Cli done."])
    }

    @Test func resultsWaitWhileRecordingAndANewerOneForTheSameConversationReplacesTheOlder() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        silencer.recordingStarted()
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Docs done.")
        output.finished(conversation: "pi:s1", handle: "api", answer: "Second.")
        await settled()
        #expect(speech.spoken.isEmpty)
        #expect(output.queued.map(\.text) == ["docs: Docs done.", "api: Second."])
        silencer.recordingEnded()
        #expect(speech.spoken.map(\.text) == ["docs: Docs done."])
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["docs: Docs done.", "api: Second."])
        speech.finish()
        #expect(output.queued.isEmpty)
    }

    @Test func aTriggerPressStopsPlaybackAndTheInterruptedResultDoesNotResume() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        #expect(speech.isSpeaking)
        silencer.recordingStarted()
        #expect(speech.stops == 1)
        silencer.recordingEnded()
        #expect(speech.spoken.map(\.text) == ["api: First."])
    }

    @Test func turningItOffStopsPlaybackDropsWhatWaitsAndWhatIsBeingSummarized() async {
        let box = SettingsBox(SpokenResultSettings(connection: "omlx"))
        let llm = FakeLLM()
        let speech = FakeSpeech()
        let connection = connection
        let output = SpokenResultOutput(
            client: llm, permits: { _ in true }, speech: speech, silencer: SpeechSilencer(), settings: { box.value },
            connection: { $0 == connection.id ? connection : nil })
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        output.finished(conversation: "pi:s3", handle: "web", answer: Array(repeating: "word", count: 60).joined(separator: " "))
        await settled()
        #expect(speech.isSpeaking)
        box.value = SpokenResultSettings()
        output.settingsChanged()
        #expect(speech.stops == 1)
        #expect(output.queued.isEmpty)
        await settled()
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["api: First."])
    }

    @Test func aRecordingStopsEveryRegisteredVoiceAndKeepsThePreviewQuietUntilItEnds() {
        let silencer = SpeechSilencer()
        let preview = FakeSpeech()
        let result = FakeSpeech()
        silencer.register(preview)
        silencer.register(result)
        silencer.speak("sample", voice: nil, with: preview)
        #expect(preview.spoken.count == 1)
        silencer.recordingStarted()
        #expect(preview.stops == 1 && result.stops == 2)
        silencer.speak("sample", voice: nil, with: preview)
        #expect(preview.spoken.count == 1)
        silencer.recordingEnded()
        silencer.speak("sample", voice: nil, with: preview)
        #expect(preview.spoken.count == 2)
    }

    @Test func aNewerReplyBeingSummarizedReplacesAnOlderResultStillWaiting() async {
        let silencer = SpeechSilencer()
        let llm = FakeLLM()
        llm.holds = true
        llm.reply = "The newer result."
        let (output, speech, _) = make(llm: llm, silencer: silencer)
        silencer.recordingStarted()
        output.finished(conversation: "pi:s1", handle: "api", answer: "Old result.")
        output.finished(conversation: "pi:s1", handle: "api", answer: Array(repeating: "word", count: 60).joined(separator: " "))
        await settled()
        #expect(output.queued.isEmpty)
        silencer.recordingEnded()
        #expect(speech.spoken.isEmpty)
        llm.release()
        await settled()
        #expect(speech.spoken.map(\.text) == ["api: The newer result."])
    }

    @Test func anOverlongSummaryIsAskedForOnceMoreAndASecondOneSaysItIsUnavailable() async {
        let rambling = Array(repeating: "and then it changed another thing", count: 10).joined(separator: " ")
        let recovering = FakeLLM()
        recovering.replies = [rambling, "The suite passed; one question is waiting."]
        let fixed = make(llm: recovering)
        fixed.0.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        let stubborn = FakeLLM()
        stubborn.reply = rambling
        let failed = make(llm: stubborn)
        failed.0.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        #expect(recovering.requests.count == 2)
        #expect(recovering.requests[1].system.contains("\(SpokenResult.summaryWordLimit) words"))
        #expect(fixed.1.spoken.map(\.text) == ["api: The suite passed; one question is waiting."])
        #expect(stubborn.requests.count == 2)
        #expect(failed.1.spoken.map(\.text) == ["api: The spoken summary is unavailable."])
    }

    @Test func anOverlongSummaryArrivingAfterStopOrTimeoutIsNotAskedForAgain() async {
        let rambling = Array(repeating: "and then it changed another thing", count: 10).joined(separator: " ")
        let stopped = FakeLLM()
        stopped.holds = true
        stopped.reply = rambling
        let interrupted = make(llm: stopped)
        interrupted.0.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        let slow = FakeLLM()
        slow.holds = true
        slow.reply = rambling
        let expired = make(llm: slow, deadlineSeconds: 0.05)
        expired.0.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        interrupted.0.stop()
        try? await Task.sleep(for: .milliseconds(300))
        await settled()
        stopped.release()
        slow.release()
        await settled()
        #expect(stopped.requests.count == 1)
        #expect(slow.requests.count == 1)
        stopped.release()
        slow.release()
    }

    @Test func aWaitingSummaryStartsOnlyOnceTheDictationHUDHasGone() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        silencer.recordingStarted()
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        silencer.dictationHUD(visible: true)
        silencer.recordingEnded()
        #expect(speech.spoken.isEmpty)
        silencer.dictationHUD(visible: false)
        #expect(speech.spoken.map(\.text) == ["api: First."])
    }

    @Test func theDictationHUDAppearingSilencesTheSummaryAndTheRestWait() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        var shown: [String?] = []
        output.onSpeaking = { shown.append($0?.name) }
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        speech.start()
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        await settled()
        silencer.dictationHUD(visible: true)
        #expect(!speech.isSpeaking)
        #expect(shown == ["api", nil])
        #expect(output.queued.map(\.text) == ["docs: Second."])
        silencer.dictationHUD(visible: false)
        #expect(speech.spoken.map(\.text) == ["api: First.", "docs: Second."])
    }

    @Test func aResultArrivingWhileTheDictationHUDShowsWaitsForIt() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        silencer.dictationHUD(visible: true)
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        #expect(speech.spoken.isEmpty)
        silencer.dictationHUD(visible: false)
        #expect(speech.spoken.count == 1)
    }

    @Test func theVoiceIsWarmedWhenSummariesTurnOnAndNotAgainWhileTheyStayOn() async {
        let box = SettingsBox(SpokenResultSettings(enabled: false, connection: "omlx"))
        var warmed = 0
        let connection = connection
        let output = SpokenResultOutput(
            client: FakeLLM(), permits: { _ in true }, speech: FakeSpeech(), silencer: SpeechSilencer(), settings: { box.value },
            connection: { $0 == connection.id ? connection : nil }, warm: { warmed += 1 })
        #expect(warmed == 0)
        box.value.enabled = true
        output.settingsChanged()
        output.settingsChanged()
        #expect(warmed == 1)
        box.value.enabled = false
        output.settingsChanged()
        box.value.enabled = true
        output.settingsChanged()
        #expect(warmed == 2)
    }

    @Test func summariesAlreadyOnAreWarmedAtStart() {
        var warmed = 0
        let connection = connection
        _ = SpokenResultOutput(
            client: FakeLLM(), permits: { _ in true }, speech: FakeSpeech(), silencer: SpeechSilencer(),
            settings: { SpokenResultSettings(connection: "omlx") }, connection: { $0 == connection.id ? connection : nil },
            warm: { warmed += 1 })
        #expect(warmed == 1)
    }

    @Test func aPreviewReplacedWhileItsMacOSVoiceSpeaksKeepsWaitingResultsWaiting() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        let synth = NaturalSpeechTests.Synth()
        synth.fails = true
        let fallback = FakeSpeech()
        let preview = NaturalSpeech(
            ready: { true }, synthesize: { try await synth.run($0, $1) }, player: NaturalSpeechTests.FakePlayer(), fallback: fallback)
        silencer.register(preview)
        preview.onFinished = { [weak preview] in if let preview { silencer.released(preview) } }
        silencer.speak("sample", voice: nil, with: preview)
        await settled()
        #expect(fallback.isSpeaking)
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        #expect(speech.spoken.isEmpty)
        synth.fails = false
        synth.holds = true
        silencer.speak("sample", voice: nil, with: preview)
        fallback.finish()
        await settled()
        #expect(speech.spoken.isEmpty)
        synth.release()
    }

    @Test func everyResultStartsWithTheConversationThatProducedIt() async {
        let (output, speech, _) = make()
        output.finished(conversation: "pi:s1", handle: "keyscribe blue", answer: "First.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        await settled()
        #expect(speech.spoken.map(\.text) == ["keyscribe blue: First."])
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["keyscribe blue: First.", "docs: Second."])
    }

    @Test func aSummaryThatFailsIsNotLeftPending() async {
        let failing = FakeLLM()
        failing.fails = true
        let (output, _, _) = make(llm: failing)
        output.finished(conversation: "pi:s1", handle: "api", answer: long)
        await settled()
        #expect(output.pendingSummaries == 0)
    }

    @Test func theSpeakingTextIsExactlyWhatIsSpokenWithoutItsNamePrefix() async {
        let llm = FakeLLM()
        llm.reply = "It set the token to ⟦SN:REDACT:1⟧ and **went on**."
        let (output, speech, _) = make(llm: llm)
        var shown: [SpokenResultOutput.Speaking?] = []
        output.onSpeaking = { shown.append($0) }
        output.finished(conversation: "pi:s1", handle: "keyscribe blue", answer: long)
        await settled()
        speech.start()
        #expect(speech.spoken.map(\.text) == ["keyscribe blue: It set the token to a hidden value and went on."])
        #expect(shown == [SpokenResultOutput.Speaking(name: "keyscribe blue", text: "It set the token to a hidden value and went on.")])
    }

    @Test func eachSummaryShowsItsOwnText() async {
        let (output, speech, _) = make()
        var shown: [String?] = []
        output.onSpeaking = { shown.append($0?.text) }
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        await settled()
        speech.start()
        speech.finish()
        speech.start()
        #expect(shown == ["First.", nil, "Second."])
    }

    @Test func theSpeakingNameAppearsOnlyOnceAudioStartsAndClearsWhenItEnds() async {
        let (output, speech, _) = make()
        var shown: [String?] = []
        output.onSpeaking = { shown.append($0?.name) }
        output.finished(conversation: "pi:s1", handle: "keyscribe blue", answer: "First.")
        await settled()
        #expect(shown.isEmpty)
        speech.start()
        #expect(shown == ["keyscribe blue"])
        speech.finish()
        #expect(shown == ["keyscribe blue", nil])
    }

    @Test func stopEndsPlaybackDropsWhatWaitsAndWhatIsBeingSummarizedAndStaysOn() async {
        let llm = FakeLLM()
        llm.holds = true
        let (output, speech, _) = make(llm: llm)
        var shown: [String?] = []
        output.onSpeaking = { shown.append($0?.name) }
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        speech.start()
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        output.finished(conversation: "pi:s3", handle: "web", answer: long)
        await settled()
        output.stop()
        #expect(!speech.isSpeaking)
        #expect(output.queued.isEmpty)
        #expect(output.pendingSummaries == 0)
        #expect(shown == ["api", nil])
        llm.release()
        await settled()
        #expect(speech.spoken.map(\.text) == ["api: First."])
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Later.")
        await settled()
        #expect(speech.spoken.map(\.text) == ["api: First.", "docs: Later."])
    }

    @Test func aPlaybackCallbackArrivingAfterStopStartsNothing() async {
        let (output, speech, _) = make()
        var shown: [String?] = []
        output.onSpeaking = { shown.append($0?.name) }
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        await settled()
        output.stop()
        speech.start()
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["api: First."])
        #expect(shown.isEmpty)
    }

    @Test func turningItBackOnDoesNotReplayEarlierResults() async {
        let box = SettingsBox(SpokenResultSettings(connection: "omlx"))
        let speech = FakeSpeech()
        let connection = connection
        let output = SpokenResultOutput(
            client: FakeLLM(), permits: { _ in true }, speech: speech, silencer: SpeechSilencer(), settings: { box.value },
            connection: { $0 == connection.id ? connection : nil })
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        await settled()
        box.value.enabled = false
        output.settingsChanged()
        box.value.enabled = true
        output.settingsChanged()
        speech.finish()
        #expect(speech.spoken.map(\.text) == ["api: First."])
        #expect(box.value.connection == "omlx")
    }

    @Test func aRecordingEndsTheSpeakingStateAndWhatWasBeingPreparedIsNotResumed() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        var shown: [String?] = []
        output.onSpeaking = { shown.append($0?.name) }
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        speech.start()
        silencer.recordingStarted()
        #expect(shown == ["api", nil])
        silencer.recordingEnded()
        #expect(speech.spoken.count == 1)
    }

    @Test func aPreviewInterruptsAResultAndTheRestWaitUntilThePreviewEnds() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        let preview = FakeSpeech()
        silencer.register(preview)
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        output.finished(conversation: "pi:s2", handle: "docs", answer: "Second.")
        await settled()
        silencer.speak("sample", voice: nil, with: preview)
        #expect(!speech.isSpeaking)
        #expect(preview.isSpeaking)
        #expect(speech.spoken.map(\.text) == ["api: First."])
        preview.finish()
        silencer.released(preview)
        #expect(speech.spoken.map(\.text) == ["api: First.", "docs: Second."])
    }

    @Test func aResultWaitsWhileAPreviewPlays() async {
        let silencer = SpeechSilencer()
        let (output, speech, _) = make(silencer: silencer)
        let preview = FakeSpeech()
        silencer.register(preview)
        silencer.speak("sample", voice: nil, with: preview)
        output.finished(conversation: "pi:s1", handle: "api", answer: "First.")
        await settled()
        #expect(speech.spoken.isEmpty)
        preview.finish()
        silencer.released(preview)
        #expect(speech.spoken.map(\.text) == ["api: First."])
    }
}

@MainActor
struct SpokenResultSettingsWiringTests {
    @Test func aChangeInTheSpokenResultSectionIsSavedAndALoadedValueIsNotSavedBack() {
        var saved: [SpokenResultSettings] = []
        let model = SettingsModel(settings: .defaults, onChange: { saved.append($0.codingAgents.spokenResult) }, onReload: {}, onResetHUDPosition: {})
        let agents = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: FileManager.default.temporaryDirectory, connectors: [])
        agents.onSpokenResultChange = { model.setSpokenResult($0) }
        agents.load(spokenResult: SpokenResultSettings(connection: "omlx"))
        #expect(saved.isEmpty)
        agents.spokenResult.voice = "voice.one"
        agents.spokenResult.enabled = false
        #expect(saved == [
            SpokenResultSettings(connection: "omlx", voice: "voice.one"),
            SpokenResultSettings(enabled: false, connection: "omlx", voice: "voice.one"),
        ])
    }
}
