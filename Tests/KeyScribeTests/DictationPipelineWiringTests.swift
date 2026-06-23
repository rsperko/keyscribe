import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// End-to-end wiring of the post-STT pipeline through the REAL DictationController (design.md §4.2.1):
// verbatim tokenizes before the text stages, the optional LLM runs on the tokenized text, restore is
// the reverse pass — on every path. Only the OS edges are mocked (audio, STT text, LLM, insertion).
// Covers the bug class the B refactor fixed (verbatim absent on the no-LLM path; text stages mutating
// a verbatim span) without a microphone or a cloud call.
@MainActor
struct DictationPipelineWiringTests {
    // STT that returns a fixed transcript immediately.
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
        func start(levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL { url }
        func stop() -> URL? { url }
    }

    // Faithful rewrite: echoes the <content> block verbatim (so issued tokens survive the gate), and
    // records what it was sent so the test can prove the protected spans were tokenized before the call.
    private actor EchoLLM: LLMClient {
        private(set) var lastUser = ""
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            lastUser = user
            guard let start = user.range(of: "<content>\n"),
                  let end = user.range(of: "\n</content>") else { return user }
            return String(user[start.upperBound..<end.lowerBound])
        }
    }

    // A model that ignores the preserve-tokens rule — the gate must reject it and fall back to local.
    private struct DropTokenLLM: LLMClient {
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            "completely rewritten with no tokens"
        }
    }

    private func run(
        transcript: String, mode: Mode, connection: Connection? = nil, llm: any LLMClient
    ) async -> (result: String?, outcome: HistoryEntry.Outcome?, llm: any LLMClient) {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-wiring-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        try? ModeStore.write(mode, to: modesDir)
        if let connection {
            try? ConnectionStore.write(ConnectionSet(connections: [connection]), to: supportDir)
        }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        settings.defaultModeId = mode.id

        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let history = HistoryStore(supportDir: supportDir)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _ in },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: llm)

        controller.handleStart()
        controller.handleCommit()
        await controller.dictationTask?.value
        return (controller.lastResult, history.entries().first?.outcome, llm)
    }

    private func mode(
        id: String, liveEdits: Bool = false, privacy: Bool = false,
        replacements: [ReplacementsSet.Rule] = [], connectionId: String? = nil
    ) -> Mode {
        var m = Mode(id: id, name: id)
        m.commands = .init(liveEdits: liveEdits, privacy: privacy)
        m.replacements = .init(includeGlobal: false, rules: replacements)
        if let connectionId { m.aiRewrite = .init(connection: connectionId, prompt: "Rewrite it.") }
        return m
    }

    // The no-LLM path: verbatim must strip its markers AND shield its span from the text stages, while
    // a loose word outside the span is still replaced. (Pre-fix: markers leaked and the span was mutated.)
    @Test func verbatimSurvivesTheTextStagesOnTheNoLLMPath() async {
        let m = mode(id: "code", liveEdits: true,
                     replacements: [ReplacementsSet.Rule(heard: "cat", replace: "dog", regex: false)])
        let out = await run(transcript: "a cat begin verbatim a cat end verbatim", mode: m, llm: DropTokenLLM())
        #expect(out.result == "a dog a cat")
    }

    // The LLM path: verbatim + redaction spans reach the model as opaque tokens (never the originals),
    // and the reverse pass restores both after a faithful rewrite.
    @Test func verbatimAndRedactionAreTokenizedBeforeTheLLMThenRestored() async {
        let m = mode(id: "polish", liveEdits: true, privacy: true, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "begin verbatim Mr Smith end verbatim email alice@example.com",
            mode: m, connection: conn, llm: EchoLLM())

        #expect(out.result == "Mr Smith email alice@example.com")
        #expect(out.outcome == .inserted)
        let sent = await (out.llm as! EchoLLM).lastUser
        #expect(sent.contains("⟦SN:VERB:1⟧"))
        #expect(sent.contains("⟦SN:REDACT:1⟧"))
        #expect(!sent.contains("Mr Smith"))
        #expect(!sent.contains("alice@example.com"))
    }

    // A model that drops the tokens fails the gate → local fallback restores the un-rewritten text
    // (the protected spans never leak even when the model misbehaves).
    @Test func droppedTokensFallBackToRestoredLocalText() async {
        let m = mode(id: "polish", liveEdits: true, privacy: true, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "begin verbatim Mr Smith end verbatim email alice@example.com",
            mode: m, connection: conn, llm: DropTokenLLM())

        #expect(out.result == "Mr Smith email alice@example.com")
        #expect(out.outcome == .localFallback)
    }
}
