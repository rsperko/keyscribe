import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct RecordingLimitTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        private let text: String
        init(text: String) { self.text = text }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { text }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private struct StubPresence: SpeechPresenceDetecting {
        func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading {
            SpeechPresenceReading(presence: .speech, peak: 0.5, latencyMs: 1, modelUsed: true, speechStart: nil)
        }
    }

    private actor SpyLLM: LLMClient {
        private(set) var called = false
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            called = true
            return "rewritten"
        }
    }

    private actor SubmitSpy {
        private(set) var keys: [Mode.Submit] = []
        func record(_ key: Mode.Submit) { keys.append(key) }
    }

    private actor InsertSpy {
        private(set) var texts: [String] = []
        func record(_ text: String) { texts.append(text) }
    }

    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private struct Harness {
        let controller: DictationController
        let hud: HUDSpy
        let inserts: InsertSpy
        let llm: SpyLLM
        let submits: SubmitSpy
        let history: HistoryStore
        let supportDir: URL
    }

    private let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
    private let limitPhrase = "1-second"

    private func makeHarness(
        mode: Mode, connection: Connection? = nil, transcript: String = "hello world",
        maxRecordingSeconds: Double = 0.05, limitWarningSeconds: Double = 0.02, selection: String? = nil,
        historyUnwritable: Bool = false
    ) -> Harness {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-limit-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try? ModeStore.write(mode, to: modesDir)
        if let connection { try? ConnectionStore.write(ConnectionSet(connections: [connection]), to: supportDir) }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)

        let hud = HUDSpy()
        let inserts = InsertSpy()
        let llm = SpyLLM()
        let submits = SubmitSpy()
        let historyDir = supportDir.appendingPathComponent("history-root")
        if historyUnwritable { FileManager.default.createFile(atPath: historyDir.path, contents: Data()) }
        let history = HistoryStore(supportDir: historyUnwritable ? historyDir : supportDir)
        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: hud, permits: { _ in true },
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            presenceDetector: StubPresence(),
            insert: { _, _, _, text, _ in await inserts.record(text); return true },
            submitKey: { await submits.record($0) },
            captureSelection: { _ in selection },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true },
            llmClient: llm,
            maxRecordingSeconds: maxRecordingSeconds,
            limitWarningSeconds: limitWarningSeconds,
            warmupClip: nil)
        controller.setNextModeOverride(id: mode.id)
        return Harness(
            controller: controller, hud: hud, inserts: inserts, llm: llm, submits: submits,
            history: history, supportDir: supportDir)
    }

    private func plainMode() -> Mode {
        var mode = Mode(id: "plain", name: "Plain")
        mode.trailing = .none
        return mode
    }

    private func rewriteMode(source: Mode.Source = .dictation) -> Mode {
        var mode = Mode(id: "polish", name: "Polish")
        mode.trailing = .none
        mode.source = source
        mode.aiRewrite = .init(connection: "c", prompt: "Rewrite it.", context: .init())
        return mode
    }

    private func runUntilIdle(_ h: Harness) async {
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        for _ in 0..<400 where h.controller.isBusy || h.controller.lastRecord == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await h.controller.dictationTask?.value
    }

    private func historyEntry(_ h: Harness) async -> HistoryEntry? {
        for _ in 0..<40 {
            if let entry = h.history.entries().first { return entry }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func stoppedStates(_ hud: HUDSpy) -> [HUDState] {
        hud.states.filter { if case .stoppedAtLimit = $0 { true } else { false } }
    }

    private func countdowns(_ hud: HUDSpy) -> [RecordingCountdown?] {
        hud.states.compactMap { state -> RecordingCountdown?? in
            if case .recording(_, _, _, let countdown) = state { return countdown } else { return nil }
        }
    }

    @Test func aTakeThatReachesTheLimitIsTranscribedAndInsertedInsteadOfDiscarded() async {
        let h = makeHarness(mode: plainMode())
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        var idleCount = 0
        h.controller.onBecameIdle = { idleCount += 1 }

        await runUntilIdle(h)

        #expect(await h.inserts.texts == ["hello world"])
        #expect(h.controller.lastResult == "hello world")
        #expect(h.controller.lastRecord?.outcome == .inserted)
        #expect(h.controller.lastRecord?.stoppedAtLimit == true)
        #expect(h.controller.isBusy == false)
        #expect(idleCount == 1)
        #expect(stoppedStates(h.hud) == [.stoppedAtLimit(outcome: .inserted, limit: limitPhrase, rewriteSkipped: false)])
        #expect(!h.hud.states.contains { if case .error = $0 { true } else { false } })
    }

    @Test func historyMarksATakeTheLimitStopped() async {
        let h = makeHarness(mode: plainMode())
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runUntilIdle(h)

        let entry = await historyEntry(h)
        #expect(entry?.outcome == .inserted)
        #expect(entry?.stoppedAtLimit == true)
    }

    @Test func aRewriteModeInsertsTheLocalTextWithoutCallingTheModelWhenTheLimitStopsTheTake() async {
        let h = makeHarness(mode: rewriteMode(), connection: conn)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runUntilIdle(h)

        #expect(await h.llm.called == false)
        #expect(await h.inserts.texts == ["hello world"])
        #expect(stoppedStates(h.hud) == [.stoppedAtLimit(outcome: .inserted, limit: limitPhrase, rewriteSkipped: true)])
        #expect(!h.hud.states.contains { if case .rewriting = $0 { true } else { false } })
    }

    @Test func aRewriteSkippedAtTheLimitIsRecordedAsKeepingTheLocalText() async {
        let h = makeHarness(mode: rewriteMode(), connection: conn)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runUntilIdle(h)

        let entry = await historyEntry(h)
        #expect(entry?.outcome == .localFallback)
        #expect(entry?.stoppedAtLimit == true)
        #expect(entry?.fallbackReason == DictationController.rewriteSkippedAtLimitReason)
        #expect(h.controller.lastRecord?.outcome == .localFallback)
    }

    @Test func aTakeStoppedByTheLimitIsNeverSubmitted() async {
        var mode = plainMode()
        mode.submit = .return
        let h = makeHarness(mode: mode)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runUntilIdle(h)

        #expect(await h.inserts.texts == ["hello world"])
        #expect(await h.submits.keys.isEmpty)
    }

    @Test func aReturnOnlyCommandStoppedByTheLimitIsNotPressed() async {
        var mode = plainMode()
        mode.replacements = .init(
            includeGlobal: false, rules: [ReplacementsSet.Rule(heard: "press enter", replace: "<CR>", regex: true)])
        let h = makeHarness(mode: mode, transcript: "press enter")
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runUntilIdle(h)

        #expect(await h.submits.keys.isEmpty)
        #expect(h.hud.states.contains(.error(message: "Stopped at the \(limitPhrase) limit — Return not pressed", action: nil)))
    }

    @Test func aTakeReleasedBeforeTheLimitStillRewrites() async {
        let h = makeHarness(mode: rewriteMode(), connection: conn, maxRecordingSeconds: 300, limitWarningSeconds: 30)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        await h.controller.dictationTask?.value

        #expect(await h.llm.called)
        #expect(await h.inserts.texts == ["rewritten"])
        #expect(stoppedStates(h.hud).isEmpty)
        #expect(h.controller.lastRecord?.stoppedAtLimit == false)
    }

    @Test func editInPlaceStoppedByTheLimitLeavesTheSelectionUntouchedAndKeepsWhatWasSaid() async {
        let h = makeHarness(mode: rewriteMode(source: .selection), connection: conn, selection: "original text")
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runUntilIdle(h)

        #expect(await h.llm.called == false)
        #expect(await h.inserts.texts.isEmpty)
        #expect(h.hud.states.contains(.error(
            message: "Stopped at the \(limitPhrase) limit — selection unchanged. What you said is in History.",
            action: nil)))
        let entry = await historyEntry(h)
        #expect(entry?.heard == "hello world")
        #expect(entry?.result == "")
        #expect(entry?.outcome == .failed)
        #expect(entry?.stoppedAtLimit == true)
    }

    @Test func editInPlaceStoppedByTheLimitDoesNotPointAtHistoryWhenSavingFailed() async {
        let h = makeHarness(
            mode: rewriteMode(source: .selection), connection: conn, selection: "original text",
            historyUnwritable: true)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runUntilIdle(h)

        #expect(await h.inserts.texts.isEmpty)
        #expect(h.hud.states.contains(.error(message: "Stopped at the \(limitPhrase) limit — selection unchanged", action: nil)))
    }

    @Test func theCountdownShowsFromTheFirstRenderInsideTheWarningWindow() async {
        let h = makeHarness(mode: plainMode(), maxRecordingSeconds: 0.05, limitWarningSeconds: 300)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runUntilIdle(h)

        let shown = countdowns(h.hud)
        #expect(!shown.isEmpty)
        #expect(shown.allSatisfy { $0?.totalSeconds == 300 && ($0?.secondsLeft ?? 99) <= 1 })
    }

    @Test func noCountdownShowsBeforeTheWarningWindow() async {
        let h = makeHarness(mode: plainMode(), maxRecordingSeconds: 300, limitWarningSeconds: 30)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        await h.controller.dictationTask?.value

        let shown = countdowns(h.hud)
        #expect(!shown.isEmpty)
        #expect(shown.allSatisfy { $0 == nil })
    }

    @Test func countdownIsAbsentUntilTheWarningWindowAndRoundsUpInsideIt() {
        #expect(RecordingCountdown(remaining: 45, warningSeconds: 30) == nil)
        #expect(RecordingCountdown(remaining: 30, warningSeconds: 30) == RecordingCountdown(secondsLeft: 30, totalSeconds: 30))
        #expect(RecordingCountdown(remaining: 12.2, warningSeconds: 30) == RecordingCountdown(secondsLeft: 13, totalSeconds: 30))
        #expect(RecordingCountdown(remaining: -1, warningSeconds: 30) == RecordingCountdown(secondsLeft: 0, totalSeconds: 30))
    }
}
