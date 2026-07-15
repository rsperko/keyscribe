import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if fired { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }
    }
    func fire() {
        lock.lock()
        fired = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

// End-to-end wiring of streaming transcription through the real DictationController: the writer→driver
// feed, the deferred-start session, the finalize-at-commit, and the fall-back-to-batch on every
// short/failed path. Only the OS edges are faked (audio + engine + insertion). No microphone.
@MainActor
struct DictationStreamingWiringTests {
    // One dictation's fake streaming session: records what it was fed and how it was closed. Optional gates
    // let a test wedge append or finalize (block until fired) to exercise the finalize deadline.
    private final class StreamSession: StreamingSpeechSession, @unchecked Sendable {
        private let lock = NSLock()
        private var _frames = 0
        private var _finalized = false          // finalize was entered
        private var _finalizeReturned = false   // finalize ran to completion (past any gate)
        private var _cancelled = false
        private let text: String
        private let finalizeThrows: Bool
        private let appendGate: Signal?
        private let finalizeGate: Signal?
        init(text: String, finalizeThrows: Bool, appendGate: Signal? = nil, finalizeGate: Signal? = nil) {
            self.text = text; self.finalizeThrows = finalizeThrows
            self.appendGate = appendGate; self.finalizeGate = finalizeGate
        }
        var frames: Int { lock.withLock { _frames } }
        var finalized: Bool { lock.withLock { _finalized } }
        var finalizeReturned: Bool { lock.withLock { _finalizeReturned } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        func append(samples: [Float]) async throws {
            if let appendGate { await appendGate.wait() }
            lock.withLock { _frames += samples.count }
        }
        func finalizeTranscript() async throws -> String {
            lock.withLock { _finalized = true }
            if let finalizeGate { await finalizeGate.wait() }
            if finalizeThrows { throw StreamError() }
            lock.withLock { _finalizeReturned = true }
            return text
        }
        func cancel() async { lock.withLock { _cancelled = true } }
    }

    private struct StreamError: Error {}

    private final class StreamEngine: SpeechEngine, @unchecked Sendable {
        let id = "streamer"
        let displayName = "Streamer"
        let supportsRecognitionBias = false
        let supportsStreaming = true
        private let batchText: String
        private let streamText: String
        private let finalizeThrows: Bool
        private let appendGates: [Signal?]      // per makeStreamingSession call (by index)
        private let finalizeGates: [Signal?]
        private let lock = NSLock()
        private var _batchCalls = 0
        private var _sessions: [StreamSession] = []
        private var _callCount = 0
        var batchCalls: Int { lock.withLock { _batchCalls } }
        var session: StreamSession? { lock.withLock { _sessions.last } }
        var sessions: [StreamSession] { lock.withLock { _sessions } }
        init(batchText: String, streamText: String, finalizeThrows: Bool = false,
             appendGates: [Signal?] = [], finalizeGates: [Signal?] = []) {
            self.batchText = batchText
            self.streamText = streamText
            self.finalizeThrows = finalizeThrows
            self.appendGates = appendGates
            self.finalizeGates = finalizeGates
        }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            lock.withLock { _batchCalls += 1 }
            return batchText
        }
        func makeStreamingSession(sampleRate: Int, biasTerms: [String]) async throws -> any StreamingSpeechSession {
            let i = lock.withLock { let c = _callCount; _callCount += 1; return c }
            let s = StreamSession(text: streamText, finalizeThrows: finalizeThrows,
                                  appendGate: i < appendGates.count ? appendGates[i] : nil,
                                  finalizeGate: i < finalizeGates.count ? finalizeGates[i] : nil)
            lock.withLock { _sessions.append(s) }
            return s
        }
        func evict() async {}
    }

    // Emits `chunk` through the streaming sink at start() so the deferred-start crossing happens during the
    // recording, then serves the WAV/PCM the batch fallback would use. A gated finishDraining (drainGate)
    // lets a cancel test fire while a session is live.
    private final class StreamAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let chunk: [Float]
        private let drainGate: Signal?
        private let lock = NSLock()
        private var sink: (@Sendable ([Float]) -> Void)?
        init(url: URL, chunk: [Float], drainGate: Signal? = nil) {
            self.url = url
            self.chunk = chunk
            self.drainGate = drainGate
        }
        func start(sampleRate: Int) async throws -> URL { url }
        func start(sampleRate: Int, onSamples: (@Sendable ([Float]) -> Void)?) async throws -> URL {
            lock.withLock { sink = onSamples }
            if let onSamples { onSamples(chunk) }
            return url
        }
        func stop() -> URL? { url }
        func finishDraining() async -> URL? {
            if let drainGate { await drainGate.wait() }
            return url
        }
        func takeDrainedSamples() -> [Float]? { nil }   // batch fallback re-reads via transcribe(wavURL:)
    }

    private final class InsertSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _text: String?
        var text: String? { lock.withLock { _text } }
        func record(_ t: String) { lock.withLock { _text = t } }
    }

    private struct Harness {
        let controller: DictationController
        let engine: StreamEngine
        let insertSpy: InsertSpy
        let supportDir: URL
    }

    private func makeHarness(
        chunk: [Float], streamingEnabled: Bool = true, finalizeThrows: Bool = false,
        drainGate: Signal? = nil, appendGates: [Signal?] = [], finalizeGates: [Signal?] = [],
        finalizeTimeout: Double? = nil, streamText: String = "STREAMED_TEXT",
        rules: [ReplacementsSet.Rule] = []
    ) -> Harness {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-stream-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        var mode = Mode(id: "local", name: "Local")
        mode.enabled = true
        if !rules.isEmpty { mode.replacements = Mode.ModeReplacements(includeGlobal: false, rules: rules) }
        try? ModeStore.write(mode, to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "streamer", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        if streamingEnabled { settings.features.setEnabled(true, for: .streamingTranscription) }

        let engine = StreamEngine(batchText: "BATCH_TEXT", streamText: streamText,
                                  finalizeThrows: finalizeThrows, appendGates: appendGates, finalizeGates: finalizeGates)
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "streamer")
        let insertSpy = InsertSpy()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil,
            audio: StreamAudio(url: supportDir.appendingPathComponent("capture.wav"), chunk: chunk, drainGate: drainGate),
            insert: { _, _, _, text, _ in insertSpy.record(text); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true },
            activeEngineUsable: { _ in true })
        controller.setNextModeOverride(id: "local")
        if let finalizeTimeout { controller.streamingFinalizeTimeoutOverride = finalizeTimeout }
        return Harness(controller: controller, engine: engine, insertSpy: insertSpy, supportDir: supportDir)
    }

    // 16 kHz: >64000 frames crosses the 4 s deferred-start threshold; a short chunk stays under it.
    private static let longChunk = [Float](repeating: 0.1, count: 80000)
    private static let shortChunk = [Float](repeating: 0.1, count: 16000)

    private func drive(_ h: Harness) async {
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        await h.controller.dictationTask?.value
    }

    @Test func longRecordingStreamsAndSkipsBatch() async {
        let h = makeHarness(chunk: Self.longChunk)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        await drive(h)
        #expect(h.insertSpy.text?.contains("STREAMED_TEXT") == true)
        #expect(h.engine.batchCalls == 0)                 // streaming owned the transcript
        #expect(h.engine.session?.finalized == true)
        #expect((h.engine.session?.frames ?? 0) == Self.longChunk.count)   // every frame reached the session
    }

    @Test func shortRecordingFallsBackToBatch() async {
        let h = makeHarness(chunk: Self.shortChunk)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        await drive(h)
        #expect(h.insertSpy.text?.contains("BATCH_TEXT") == true)
        #expect(h.engine.batchCalls == 1)                 // deferred start never opened a session
        #expect(h.engine.session == nil)
    }

    @Test func finalizeFailureFallsBackToBatch() async {
        let h = makeHarness(chunk: Self.longChunk, finalizeThrows: true)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        await drive(h)
        #expect(h.engine.session?.finalized == true)      // finalize was attempted
        #expect(h.insertSpy.text?.contains("BATCH_TEXT") == true)   // and its failure degraded to batch
        #expect(h.engine.batchCalls == 1)
    }

    @Test func flagOffUsesBatchEvenForAStreamingEngine() async {
        let h = makeHarness(chunk: Self.longChunk, streamingEnabled: false)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        await drive(h)
        #expect(h.insertSpy.text?.contains("BATCH_TEXT") == true)
        #expect(h.engine.batchCalls == 1)
        #expect(h.engine.session == nil)                  // no session ever opened
    }

    // ESC mid-stream: releaseCapturedPlan must cancel the live session so the engine lock is released.
    @Test func cancelClosesTheLiveStreamingSession() async {
        let drainGate = Signal()
        let h = makeHarness(chunk: Self.longChunk, drainGate: drainGate)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        // Wait for the feed task to cross the threshold and open the session.
        for _ in 0..<200 where h.engine.session == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(h.engine.session != nil)
        h.controller.handleCommit()                       // finishDraining now blocks on the gate
        h.controller.cancel()                             // ESC while the session is live
        await h.controller.streamingCancelTask?.value     // deterministic: the teardown cancel completed
        #expect(h.engine.session?.cancelled == true)
        #expect(h.engine.session?.finalized == false)     // cancel, not finalize
        drainGate.fire()
        await h.controller.dictationTask?.value
    }

    // A wedged append hangs at the feed-drain await BEFORE finalize is reached; the finalize deadline
    // abandons it as terminal — never a same-engine batch fallback (the abandoned session holds the gate).
    @Test func wedgedAppendHitsTheFinalizeDeadline() async {
        let appendGate = Signal()   // never fired during the run → append blocks forever
        let h = makeHarness(chunk: Self.longChunk, appendGates: [appendGate], finalizeTimeout: 0.05)
        defer { appendGate.fire(); try? FileManager.default.removeItem(at: h.supportDir) }
        await drive(h)
        #expect(h.engine.session != nil)                 // a session opened during capture
        #expect(h.engine.session?.finalized == false)    // the wedge is in append — finalize never reached
        #expect(h.insertSpy.text == nil)                 // terminal timeout — nothing inserted
        #expect(h.engine.batchCalls == 0)                // and NO same-engine batch fallback
        #expect(await h.controller.transcribeGateBusy()) // the abandoned session still holds the gate
    }

    // A wedged finalize (feed drained, but the SDK finalize hangs) hits the same deadline and is terminal.
    @Test func wedgedFinalizeHitsTheDeadline() async {
        let finalizeGate = Signal()
        let h = makeHarness(chunk: Self.longChunk, finalizeGates: [finalizeGate], finalizeTimeout: 0.05)
        defer { finalizeGate.fire(); try? FileManager.default.removeItem(at: h.supportDir) }
        await drive(h)
        #expect(h.engine.session?.finalized == true)          // finalize was entered...
        #expect(h.engine.session?.finalizeReturned == false)  // ...but wedged before returning
        #expect(h.insertSpy.text == nil)                      // terminal timeout
        #expect(h.engine.batchCalls == 0)
        #expect(await h.controller.transcribeGateBusy())
    }

    // The abandoned wedged finalize keeps the gate busy (so the next press reports "Still finishing"), and
    // once it truly settles the gate frees and a later dictation proceeds — mirroring the batch deadline.
    @Test func abandonedFinalizeReleasesTheGateOnceItSettlesThenNextDictationProceeds() async {
        let gate1 = Signal()   // wedges ONLY dictation 1's finalize (finalizeGates has one entry)
        let h = makeHarness(chunk: Self.longChunk, finalizeGates: [gate1], finalizeTimeout: 0.05)
        defer { gate1.fire(); try? FileManager.default.removeItem(at: h.supportDir) }

        await drive(h)                                    // dictation 1: finalize wedges → deadline
        #expect(h.insertSpy.text == nil)
        #expect(await h.controller.transcribeGateBusy())  // the abandoned finalize holds the gate

        await drive(h)                                    // dictation 2: gate still busy → rejected
        #expect(h.insertSpy.text == nil)                  // nothing inserted — "Still finishing"
        #expect(h.engine.batchCalls == 0)

        gate1.fire()                                      // let dictation 1's finalize settle → gate releases
        for _ in 0..<400 where await h.controller.transcribeGateBusy() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!(await h.controller.transcribeGateBusy()))

        await drive(h)                                    // dictation 3: proceeds — streaming owns the transcript
        #expect(h.insertSpy.text?.contains("STREAMED_TEXT") == true)
    }

    // The deferred-start threshold must sit at/above the streaming floor, so a session never opens while
    // press-time prepare/prewarm still hold the engine lock.
    @Test func startThresholdSitsAtOrAboveTheStreamingFloor() {
        #expect(DictationController.streamingStartThresholdSeconds >= StreamingStartPolicy.minimumThresholdSeconds)
    }

    // A STREAMED transcript flows through the exact same post-transcript pipeline as batch: a whole-utterance
    // replacement (exact-match sensitive, and it bypasses the LLM/trailing/trim) fires on the streamed text
    // and is inserted bare — proving streaming does not divert around ReplacementsStage.
    @Test func streamedTranscriptFlowsThroughWholeUtteranceReplacement() async {
        let rules = [ReplacementsSet.Rule(heard: "slash replace", replace: "/replace", regex: false)]
        let h = makeHarness(chunk: Self.longChunk, streamText: "slash replace", rules: rules)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        await drive(h)
        #expect(h.engine.session?.finalized == true)   // streaming owned the transcript...
        #expect(h.engine.batchCalls == 0)
        #expect(h.insertSpy.text == "/replace")         // ...and the whole-utterance rule applied to it, bare
    }
}
