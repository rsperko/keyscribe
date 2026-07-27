import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Screen-term recovery: identifiers harvested from the already-captured preceding text snap the local
// transcript (exact-normalized only), riding the mode's preceding-text opt-in — no separate flag,
// mirroring dictionary recovery. Runs on the no-rewrite path too — the snap is local, not an LLM behavior.
@MainActor
struct ScreenTermRecoveryWiringTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        private let text: String
        init(text: String = "call usestate now") { self.text = text }
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

    @MainActor private final class InsertSpy {
        private(set) var texts: [String] = []
        private(set) var probeFinishedAtInsert: [Bool] = []
        var probeFinished = false
        func record(_ text: String) {
            texts.append(text)
            probeFinishedAtInsert.append(probeFinished)
        }
    }

    private func makeController(
        contextOn: Bool = true, privacy: Bool = false, connectionId: String = "missing", spy: InsertSpy,
        transcript: String? = nil, rules: [ReplacementsSet.Rule] = [], probeDelay: Duration? = nil
    ) -> DictationController {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-screenterms-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        var mode = Mode(id: "m", name: "M")
        mode.aiRewrite = .init(
            connection: connectionId, prompt: "Rewrite it.", context: .init(precedingText: contextOn))
        mode.commands.privacy = privacy
        if !rules.isEmpty { mode.replacements = Mode.ModeReplacements(includeGlobal: false, rules: rules) }
        try? ModeStore.write(mode, to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let engine = transcript.map { FixedEngine(text: $0) } ?? FixedEngine()
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "fixed")
        return DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, text, _ in await MainActor.run { spy.record(text) }; return true },
            submitKey: { _ in },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 4242, focusedWindowId: "cg:99") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            precedingTextProbe: { _, _ in
                if let probeDelay { try? await Task.sleep(for: probeDelay) }
                spy.probeFinished = true
                return "let value = useState(initialCount)"
            })
    }

    private func dictate(_ controller: DictationController) async {
        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
    }

    @Test func harvestedTermSnapsTheLocalTranscriptWithoutARewrite() async {
        let spy = InsertSpy()
        let controller = makeController(spy: spy)
        await dictate(controller)
        #expect(spy.texts == ["call useState now "])
    }

    @Test func aModeWithoutPrecedingContextLeavesTheTranscriptUntouched() async {
        let spy = InsertSpy()
        let controller = makeController(contextOn: false, spy: spy)
        await dictate(controller)
        #expect(spy.texts == ["call usestate now "])
    }

    // Privacy empties effectiveContext, so the probe never runs and nothing is harvested — the
    // recovery must not create a new way for field text to be read.
    @Test func privacyModeHarvestsNothing() async {
        let spy = InsertSpy()
        let controller = makeController(privacy: true, spy: spy)
        await dictate(controller)
        #expect(spy.texts == ["call usestate now "])
    }

    @MainActor private final class PromptCapturingLLM: LLMClient, @unchecked Sendable {
        var system = ""
        var user = ""
        nonisolated func complete(system: String, user: String, connection: Connection) async throws -> String {
            await MainActor.run { self.system = system; self.user = user }
            return "call useState now"
        }
    }

    // The local harvest never awaits — it reads whatever the probe has published — so a probe still in
    // flight at commit yields no local snap. The rewrite prompt no longer carries harvested terms at all
    // (that channel was measured and rejected), so a slow read simply means no snap and no hint, while
    // <context> itself is unaffected: the builder still awaits the probe in full for the context block.
    @Test func aSlowProbeStillSuppliesContextButNoTermHint() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-latehint-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var mode = Mode(id: "m", name: "M")
        mode.aiRewrite = .init(
            connection: "c", prompt: "Clean up.", context: .init(precedingText: true))
        try? ModeStore.write(mode, to: modesDir)
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        try? ConnectionStore.write(ConnectionSet(connections: [conn]), to: supportDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let llm = PromptCapturingLLM()
        let spy = InsertSpy()
        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, text, _ in await MainActor.run { spy.record(text) }; return true },
            submitKey: { _ in },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 4242, focusedWindowId: "cg:99") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            precedingTextProbe: { _, _ in
                // Comfortably past the 250 ms local budget, so the local snap gives up.
                try? await Task.sleep(for: .milliseconds(800))
                spy.probeFinished = true
                return "const [count, setCount] = useState(0)"
            },
            llmClient: llm)

        await dictate(controller)
        // Local snap missed it (the transcript reached the model unsnapped)…
        #expect(spy.probeFinishedAtInsert == [true])
        // …and no harvested term hint is present anywhere in the system rules…
        #expect(!llm.system.contains("useState"))
        #expect(!llm.system.contains("not misspellings"))
        #expect(!llm.system.contains("may have misheard"))
        // …while the opted-in context block still received the field text in full.
        #expect(llm.user.contains("useState"))
    }

    // A whole-utterance replacement is decided by ReplacementsStage (StageOrder.replacements = 10),
    // strictly before the screen-terms stage (40) — so a harvest provably cannot change that output and
    // must not delay it. Clock-free on purpose: asserting elapsed time flaked under full-suite
    // contention back when the harvest was deadline-bounded, because the deadline's own timer must be
    // scheduled. The spy instead records whether the field read had finished at the moment insertion
    // fired — false proves insertion did not wait on it, whatever the scheduler was doing.
    @Test func aSlowFieldReadDoesNotDelayAWholeUtteranceReplacement() async {
        let spy = InsertSpy()
        let controller = makeController(
            spy: spy, transcript: "slash resume",
            rules: [ReplacementsSet.Rule(heard: "slash resume", replace: "/resume", regex: false)],
            probeDelay: .seconds(5))
        await dictate(controller)
        #expect(spy.texts == ["/resume"])
        #expect(spy.probeFinishedAtInsert == [false])
    }
}
