import FluidAudio
import Foundation
import Testing

@testable import KeyScribe
@testable import KeyScribeKit

// The recovery for an engine that returns no text on a take the VAD heard speech in — the Parakeet TDT v3
// silent-collapse shape (agent_notes/parakeet_silent_bug_recovery), guarded generically.
@MainActor
struct EmptyTranscriptRecoveryTests {
    private struct ScriptedFailure: Error {}

    // What the engine does on one call: answer, throw, or take `seconds` first (to outlast a deadline).
    // `.slow` deliberately IGNORES cancellation — like the real CoreML/MLX engines whose indifference to it is
    // why the deadline abandons rather than stops them. So an abandoned call still returns its text, which is
    // what makes the deadline race reachable in a test.
    private enum Reply {
        case text(String)
        case failure
        case slow(seconds: Double, then: String)
    }

    // Answers each transcribe call from `replies` in order, recording every input it was handed.
    private final class ScriptedEngine: SpeechEngine, @unchecked Sendable {
        let id = "scripted"
        let displayName = "Scripted Model"
        let supportsRecognitionBias = false
        private let replies: [Reply]
        private let acceptsSamples: Bool
        private let lock = NSLock()
        private var _sampleCalls: [(samples: [Float], sampleRate: Int, biasTerms: [String])] = []
        private var _wavCalls = 0
        private var _completedCalls = 0
        private var next = 0
        // Fires with the 0-based index of a call as it begins — the seam a cancel-mid-retry test needs.
        var onCall: (@Sendable (Int) -> Void)?

        init(replies: [Reply], acceptsSamples: Bool = true) {
            self.replies = replies
            self.acceptsSamples = acceptsSamples
        }

        convenience init(responses: [String], acceptsSamples: Bool = true) {
            self.init(replies: responses.map { .text($0) }, acceptsSamples: acceptsSamples)
        }

        var callCount: Int { lock.withLock { next } }
        // Calls that RETURNED a transcript, as opposed to merely started — the difference between "the retry
        // began" and "the retry handed text back after the deadline had already decided the outcome".
        var completedCalls: Int { lock.withLock { _completedCalls } }
        var sampleCalls: [(samples: [Float], sampleRate: Int, biasTerms: [String])] { lock.withLock { _sampleCalls } }
        var wavCalls: Int { lock.withLock { _wavCalls } }
        nonisolated var supportsSampleInput: Bool { acceptsSamples }
        func loadIfNeeded() async throws {}
        func evict() async {}

        private func take() -> (index: Int, reply: Reply) {
            lock.withLock {
                let i = next
                next += 1
                return (i, i < replies.count ? replies[i] : .text(""))
            }
        }

        private func answer(_ index: Int, _ reply: Reply) async throws -> String {
            onCall?(index)
            let text: String
            switch reply {
            case .text(let t):
                text = t
            case .failure:
                throw ScriptedFailure()
            case .slow(let seconds, let then):
                // `try?`: a cancelled sleep still answers, modelling an engine that never observes cancellation.
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                text = then
            }
            lock.withLock { _completedCalls += 1 }
            return text
        }

        func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
            let (index, reply) = take()
            lock.withLock { _sampleCalls.append((samples, sampleRate, biasTerms)) }
            return try await answer(index, reply)
        }

        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            let (index, reply) = take()
            lock.withLock { _wavCalls += 1 }
            return try await answer(index, reply)
        }
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let samples: [Float]?
        init(url: URL, samples: [Float]?) {
            self.url = url
            self.samples = samples
        }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
        func takeDrainedSamples() -> [Float]? { samples }
    }

    private struct StubPresence: SpeechPresenceDetecting {
        var presence: SpeechPresence = .speech
        var modelUsed = true
        var speechStart: TimeInterval?
        func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading {
            SpeechPresenceReading(
                presence: presence, maxProbability: 1, peak: 0.5, latencyMs: 1,
                modelUsed: modelUsed, speechStart: speechStart)
        }
    }

    private final class DecisionSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.withLock { _lines } }
        func record(_ line: String) { lock.withLock { _lines.append(line) } }
    }

    private final class InsertSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _text: String?
        var text: String? { lock.withLock { _text } }
        func record(_ t: String) { lock.withLock { _text = t } }
    }

    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private final class LateBoundCancel: @unchecked Sendable {
        var run: (@MainActor () -> Void)?
    }

    private func run(
        engine: ScriptedEngine, detector: SpeechPresenceDetecting, samples: [Float]?,
        transcribeTimeout: Double? = nil,
        // Wait past a deadline-abandoned engine call's own return before snapshotting, so a late result has
        // every chance to (wrongly) land.
        settleSeconds: Double = 0,
        decisions: DecisionSpy? = nil,
        onController: (@MainActor (DictationController) -> Void)? = nil,
        insert: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> (DictationRecord?, [HUDState]) {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-recovery-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var m = Mode(id: "plain", name: "plain")
        m.commands = .init(liveEdits: false, privacy: false)
        try? ModeStore.write(m, to: modesDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "scripted", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let hud = HUDSpy()
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "scripted")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav"), samples: samples),
            presenceDetector: detector,
            insert: { _, _, _, text, _ in insert(text); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
        controller.transcribeTimeoutOverride = transcribeTimeout
        if let decisions { controller.recoveryDecisionObserver = { decisions.record($0) } }
        onController?(controller)
        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        if settleSeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1e9)) }
        return (controller.lastRecord, hud.states)
    }

    // 1 s of PCM at 16 kHz, marked at the sample the 0.512 s trim boundary should land on.
    private func markedSamples() -> [Float] {
        var samples = [Float](repeating: 0.1, count: 16000)
        samples[4096] = 0.9
        return samples
    }

    private func terminalMessage(_ states: [HUDState]) -> String? {
        if case .error(let message, _) = states.last { return message }
        return nil
    }

    @Test func anEmptyFirstPassRetriesOnceOnThePcmWithTheLeadingSilenceRemoved() async {
        let inserted = InsertSpy()
        let engine = ScriptedEngine(responses: ["", "recovered text"])
        let (record, _) = await run(
            engine: engine,
            detector: StubPresence(speechStart: 0.512),
            samples: markedSamples(),
            insert: { inserted.record($0) })
        #expect(engine.callCount == 2)
        #expect(engine.sampleCalls.count == 2)
        // 0.512 − 0.256 s of pre-roll = 4,096 samples removed, and the retry starts exactly at the mark.
        #expect(engine.sampleCalls[1].samples.count == 16000 - 4096)
        #expect(engine.sampleCalls[1].samples.first == 0.9)
        #expect(engine.sampleCalls[1].sampleRate == 16000)
        #expect(engine.sampleCalls[1].biasTerms == engine.sampleCalls[0].biasTerms)
        #expect(record?.outcome == .inserted)
        #expect(inserted.text?.trimmingCharacters(in: .whitespaces) == "recovered text")
    }

    @Test func aRetryThatIsAlsoEmptyNamesTheModelAndRecordsNoSpeech() async {
        let engine = ScriptedEngine(responses: ["", ""])
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples())
        #expect(engine.callCount == 2)
        #expect(record?.outcome == .noSpeech)
        #expect(terminalMessage(states) == "Heard speech, but Scripted Model returned no text")
    }

    @Test func speechInChunkZeroIsNotRetriedAndGetsTheNamedModelError() async {
        let engine = ScriptedEngine(responses: [""])
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: nil), samples: markedSamples())
        #expect(engine.callCount == 1)
        #expect(record?.outcome == .noSpeech)
        #expect(terminalMessage(states) == "Heard speech, but Scripted Model returned no text")
    }

    @Test func aFirstAttemptThatSpentTheBudgetSkipsTheRetryRatherThanRiskATimeout() async {
        // A first attempt past 4/9 of the deadline leaves under 1.25× of itself — no room for a retry that
        // could cost as much again, so the retry is skipped rather than risking a spurious timeout.
        let engine = ScriptedEngine(replies: [.slow(seconds: 0.5, then: ""), .text("would have recovered")])
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples(),
            transcribeTimeout: 1)
        #expect(engine.callCount == 1)
        #expect(record?.outcome == .noSpeech)
        #expect(terminalMessage(states) == "Heard speech, but Scripted Model returned no text")
    }

    // A repair that fails does not change what happened: the engine still returned nothing on a take with
    // speech in it. Reporting the generic "Transcription failed" would blame the retry for the first
    // attempt's silent failure.
    @Test func aRetryThatThrowsNamesTheModelRatherThanAGenericFailure() async {
        let engine = ScriptedEngine(replies: [.text(""), .failure])
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples())
        #expect(engine.callCount == 2)
        #expect(record?.outcome == .noSpeech)
        #expect(terminalMessage(states) == "Heard speech, but Scripted Model returned no text")
    }

    // The shared deadline is never extended, so it can expire mid-retry. That is still the engine failing to
    // produce text on speech — not a timeout the user should be told to blame.
    //
    // The deadline ABANDONS the retry without stopping it, so the engine can hand back text after the terminal
    // was decided. The gate's verdict is the authoritative one: that late success must not insert, must not
    // change the terminal, and (structurally — the decision is logged only after the gate ACCEPTS a result)
    // must not report `recovered` for a dictation the user saw fail. Settling past the engine's own return
    // proves the late result is discarded rather than merely not-yet-arrived.
    @Test func aDeadlineDuringTheRetryNamesTheModelAndDiscardsTheLateResult() async {
        let inserted = InsertSpy()
        let decisions = DecisionSpy()
        let engine = ScriptedEngine(replies: [.text(""), .slow(seconds: 0.3, then: "too late")])
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples(),
            transcribeTimeout: 0.15, settleSeconds: 0.4, decisions: decisions, insert: { inserted.record($0) })
        #expect(engine.completedCalls == 2)     // the retry really did hand back text, post-deadline
        #expect(inserted.text == nil)           // ...which never reached the target
        #expect(record?.outcome == .noSpeech)
        #expect(terminalMessage(states) == "Heard speech, but Scripted Model returned no text")
        // The decision recorded is the one the user actually got. The abandoned retry's late `recovered` must
        // not appear at all — neither as a second line nor, worse, as the only one.
        #expect(decisions.lines.count == 1)
        #expect(decisions.lines.first?.contains("outcome=retry-deadline") == true)
        #expect(decisions.lines.contains { $0.contains("outcome=recovered") } == false)
    }

    // Each skip reason and retry outcome is named in the one decision line, so a silent-engine report can be
    // diagnosed from a log rather than guessed at.
    @Test func theRecoveryDecisionNamesWhyItSkippedOrHowItEnded() async {
        func decisionFor(
            _ engine: ScriptedEngine, speechStart: TimeInterval?, modelUsed: Bool = true, samples: [Float]?
        ) async -> String {
            let decisions = DecisionSpy()
            _ = await run(
                engine: engine,
                detector: StubPresence(modelUsed: modelUsed, speechStart: speechStart),
                samples: samples, decisions: decisions)
            #expect(decisions.lines.count == 1)
            return decisions.lines.first ?? ""
        }

        let recovered = await decisionFor(
            ScriptedEngine(responses: ["", "recovered text"]), speechStart: 0.512, samples: markedSamples())
        #expect(recovered.contains("outcome=recovered"))
        #expect(recovered.contains("engine=scripted"))
        #expect(recovered.contains("audio=1.00s"))
        #expect(recovered.contains("vad-model=true"))
        #expect(recovered.contains("speechStart=0.512s"))
        #expect(recovered.contains("attempted=true"))
        #expect(recovered.contains("trimmed=0.256s"))

        let stillEmpty = await decisionFor(
            ScriptedEngine(responses: ["", ""]), speechStart: 0.512, samples: markedSamples())
        #expect(stillEmpty.contains("outcome=retry-still-empty"))

        let threw = await decisionFor(
            ScriptedEngine(replies: [.text(""), .failure]), speechStart: 0.512, samples: markedSamples())
        #expect(threw.contains("outcome=retry-error"))

        let chunkZero = await decisionFor(
            ScriptedEngine(responses: [""]), speechStart: nil, samples: markedSamples())
        #expect(chunkZero.contains("outcome=skipped-speech-in-first-chunk"))
        #expect(chunkZero.contains("attempted=false"))

        let failOpen = await decisionFor(
            ScriptedEngine(responses: [""]), speechStart: nil, modelUsed: false, samples: markedSamples())
        #expect(failOpen.contains("outcome=skipped-vad-fail-open"))
        #expect(failOpen.contains("vad-model=false"))

        let unchangedTrim = await decisionFor(
            ScriptedEngine(responses: [""]), speechStart: 0.256, samples: markedSamples())
        #expect(unchangedTrim.contains("outcome=skipped-trim-removed-nothing"))

        let wavOnly = await decisionFor(
            ScriptedEngine(responses: [""], acceptsSamples: false), speechStart: 0.512, samples: markedSamples())
        #expect(wavOnly.contains("outcome=skipped-wav-only-engine"))

        let noPcm = await decisionFor(
            ScriptedEngine(responses: [""]), speechStart: 0.512, samples: nil)
        #expect(noPcm.contains("outcome=skipped-no-pcm"))
    }

    @Test func aBudgetSkipIsNamedInTheDecision() async {
        let decisions = DecisionSpy()
        let engine = ScriptedEngine(replies: [.slow(seconds: 0.5, then: ""), .text("would have recovered")])
        _ = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples(),
            transcribeTimeout: 1, decisions: decisions)
        #expect(decisions.lines.count == 1)
        #expect(decisions.lines.first?.contains("outcome=skipped-deadline-budget") == true)
    }

    // A first-attempt deadline never reached a recovery decision, so it must not claim one.
    @Test func anInitialDeadlineLogsNoRecoveryDecision() async {
        let decisions = DecisionSpy()
        let engine = ScriptedEngine(replies: [.slow(seconds: 5, then: "")])
        let (_, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples(),
            transcribeTimeout: 0.15, settleSeconds: 0.3, decisions: decisions)
        #expect(decisions.lines.isEmpty)
        #expect(terminalMessage(states) == "Transcription timed out")
    }

    // The recovery only reinterprets a failure that FOLLOWS a successful empty first pass. A first attempt
    // that throws or times out never reached that point and keeps the existing generic terminals.
    @Test func aFirstAttemptErrorKeepsTheGenericFailureTerminal() async {
        let engine = ScriptedEngine(replies: [.failure])
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples())
        #expect(engine.callCount == 1)
        #expect(record?.outcome == .failed)
        #expect(terminalMessage(states) == "Transcription failed")
    }

    @Test func aFirstAttemptDeadlineKeepsTheGenericTimeoutTerminal() async {
        let engine = ScriptedEngine(replies: [.slow(seconds: 5, then: "")])
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples(),
            transcribeTimeout: 0.4)
        #expect(record?.outcome == .failed)
        #expect(terminalMessage(states) == "Transcription timed out")
    }

    // A user cancel during the retry is a cancel, not an engine failure: it keeps the silent cancel terminal.
    @Test func cancellationDuringTheRetryIsNotConvertedIntoAHeardSpeechError() async {
        let engine = ScriptedEngine(replies: [.text(""), .slow(seconds: 5, then: "too late")])
        let cancel = LateBoundCancel()
        engine.onCall = { index in
            guard index == 1 else { return }
            Task { @MainActor in cancel.run?() }
        }
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples(),
            transcribeTimeout: 5, onController: { controller in
                cancel.run = { controller.dictationTask?.cancel() }
            })
        #expect(record == nil)
        #expect(terminalMessage(states) != "Heard speech, but Scripted Model returned no text")
    }

    // speechStart at exactly one chunk means the 256 ms pre-roll reaches back to the take's start: the "trim"
    // is the original PCM. Re-running the engine on byte-identical input cannot produce a different answer.
    @Test func aTrimThatRemovesNothingIsNotRetried() async {
        let inserted = InsertSpy()
        let engine = ScriptedEngine(responses: ["", "unreachable"])
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.256), samples: markedSamples(),
            insert: { inserted.record($0) })
        #expect(engine.callCount == 1)
        #expect(inserted.text == nil)
        #expect(record?.outcome == .noSpeech)
        #expect(terminalMessage(states) == "Heard speech, but Scripted Model returned no text")
    }

    @Test func aFailOpenReadingNeitherRetriesNorClaimsSpeechWasHeard() async {
        let engine = ScriptedEngine(responses: [""])
        let (record, states) = await run(
            engine: engine,
            detector: StubPresence(modelUsed: false, speechStart: nil),
            samples: markedSamples())
        #expect(engine.callCount == 1)
        #expect(record?.outcome == .noSpeech)
        #expect(terminalMessage(states) != "Heard speech, but Scripted Model returned no text")
    }

    @Test func aNonemptyFirstPassNeverRetries() async {
        let engine = ScriptedEngine(responses: ["hello world", "unreachable"])
        let (record, _) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples())
        #expect(engine.callCount == 1)
        #expect(record?.outcome == .inserted)
    }

    // The engine asserting blank audio, not failing silently: nonempty raw, so ineligible — and the cleanup
    // blanks the marker, so it keeps the ordinary no-speech terminal rather than the named-model one.
    @Test func anAnnotationResultNeverRetriesAndKeepsNoSpeech() async {
        let engine = ScriptedEngine(responses: ["[BLANK_AUDIO]", "unreachable"])
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples())
        #expect(engine.callCount == 1)
        #expect(record?.outcome == .noSpeech)
        #expect(terminalMessage(states) != "Heard speech, but Scripted Model returned no text")
    }

    @Test func aWavOnlyEngineNeverRetriesAndGetsTheNamedModelError() async {
        let engine = ScriptedEngine(responses: ["", "unreachable"], acceptsSamples: false)
        let (record, states) = await run(
            engine: engine, detector: StubPresence(speechStart: 0.512), samples: markedSamples())
        #expect(engine.wavCalls == 1)
        #expect(engine.callCount == 1)
        #expect(record?.outcome == .noSpeech)
        #expect(terminalMessage(states) == "Heard speech, but Scripted Model returned no text")
    }

    private final class EmptyStreamSession: StreamingSpeechSession, @unchecked Sendable {
        func append(samples: [Float]) async throws {}
        func finalizeTranscript() async throws -> String { "" }
        func cancel() async {}
    }

    // A streaming engine that also accepts PCM — so the streamed arm is what excludes the retry here, not the
    // sample capability.
    private final class EmptyStreamEngine: SpeechEngine, @unchecked Sendable {
        let id = "streamer"
        let displayName = "Streamer"
        let supportsRecognitionBias = false
        let supportsStreaming = true
        nonisolated var supportsSampleInput: Bool { true }
        private let lock = NSLock()
        private var _transcribeCalls = 0
        var transcribeCalls: Int { lock.withLock { _transcribeCalls } }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            lock.withLock { _transcribeCalls += 1 }
            return ""
        }
        func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
            lock.withLock { _transcribeCalls += 1 }
            return ""
        }
        func makeStreamingSession(sampleRate: Int, biasTerms: [String]) async throws -> any StreamingSpeechSession {
            EmptyStreamSession()
        }
        func evict() async {}
    }

    private final class StreamAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let chunk: [Float]
        init(url: URL, chunk: [Float]) {
            self.url = url
            self.chunk = chunk
        }
        func start(sampleRate: Int) async throws -> URL { url }
        func start(sampleRate: Int, onSamples: (@Sendable ([Float]) -> Void)?) async throws -> URL {
            onSamples?(chunk)
            return url
        }
        func stop() -> URL? { url }
        func takeDrainedSamples() -> [Float]? { chunk }
    }

    // A spent session cannot be re-fed and the streamed arm deliberately drops the PCM, so a streamed empty
    // transcript is never retried — it goes straight to the named-model terminal.
    @Test func aStreamedEmptyTranscriptNeverRetries() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-recovery-stream-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var mode = Mode(id: "plain", name: "plain")
        mode.commands = .init(liveEdits: false, privacy: false)
        try? ModeStore.write(mode, to: modesDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "streamer", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        settings.features.setEnabled(true, for: .streamingTranscription)
        let hud = HUDSpy()
        let engine = EmptyStreamEngine()
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "streamer")
        // >4 s at 16 kHz, so the deferred-start threshold is crossed and a session really opens.
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud,
            audio: StreamAudio(
                url: supportDir.appendingPathComponent("capture.wav"),
                chunk: [Float](repeating: 0.1, count: 80000)),
            presenceDetector: StubPresence(speechStart: 0.512),
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true },
            activeEngineUsable: { _ in true })
        let decisions = DecisionSpy()
        controller.recoveryDecisionObserver = { decisions.record($0) }
        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        #expect(engine.transcribeCalls == 0)
        #expect(controller.lastRecord?.outcome == .noSpeech)
        #expect(terminalMessage(hud.states) == "Heard speech, but Streamer returned no text")
        #expect(decisions.lines.count == 1)
        #expect(decisions.lines.first?.contains("outcome=skipped-streamed") == true)
    }

    // A deadline that lands mid-retry must report the engine's silent failure, while an initial-attempt
    // deadline stays a plain timeout. That distinction cannot come from a return value — the gate abandons its
    // closure — so it is the one fact this carries.
    @Test func recoveryProgressDistinguishesAnInitialDeadlineFromARetryDeadline() {
        let recovery = DictationController.RecoveryProgress()
        #expect(recovery.retryTrimmedSeconds == nil)
        recovery.noteRetryStarted(trimmedSeconds: 0.256)
        #expect(recovery.retryTrimmedSeconds == 0.256)
    }

    // The chunk geometry the speech-start math converts with is the SDK's, not a guess. It is
    // version-dependent, so a FluidAudio bump that changes it must fail here rather than silently mistime
    // every trim.
    @Test func theChunkGeometryMatchesTheVadSdk() {
        #expect(SpeechPresenceGate.chunkSamples == VadManager.chunkSize)
        #expect(SpeechPresenceGate.chunkSampleRate == VadManager.sampleRate)
    }
}
