import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// End-to-end wiring of the post-STT pipeline + insertion through the REAL DictationController
// (design.md §4.2.1): verbatim tokenizes before the text stages, the optional LLM runs on the
// tokenized text, restore is the reverse pass, then insertion applies trailing + submit. Only the OS
// edges are mocked (audio, STT text, insertion sink, submit keystroke) — except the opt-in oMLX test,
// which drives the real HTTP client against a local model. No microphone required.
@MainActor
struct DictationPipelineWiringTests {
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
    // records what it was sent so the test can prove protected spans were tokenized before the call.
    private actor EchoLLM: LLMClient {
        private(set) var lastUser = ""
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            lastUser = user
            guard let start = user.range(of: "<content>\n"),
                  let end = user.range(of: "\n</content>") else { return user }
            return String(user[start.upperBound..<end.lowerBound])
        }
    }

    // Ignores the preserve-tokens rule — the gate must reject it and fall back to local.
    private struct DropTokenLLM: LLMClient {
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            "completely rewritten with no tokens"
        }
    }

    // Captures the real insertion call (method + the exact string, which includes the trailing suffix).
    private actor InsertSpy {
        private(set) var method: Mode.Insertion?
        private(set) var text: String?
        func record(_ m: Mode.Insertion, _ t: String) { method = m; text = t }
    }

    // Captures every post-insert submit keystroke the controller fires.
    private actor SubmitSpy {
        private(set) var keys: [Mode.Submit] = []
        func record(_ s: Mode.Submit) { keys.append(s) }
    }

    private struct Result {
        let lastResult: String?
        let outcome: HistoryEntry.Outcome?
        let insertedText: String?
        let insertionMethod: Mode.Insertion?
        let submits: [Mode.Submit]
        let llm: any LLMClient
    }

    private func run(
        transcript: String, mode: Mode, connection: Connection? = nil,
        llm: any LLMClient = DropTokenLLM(), accessibility: Bool = true
    ) async -> Result {
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
        let insertSpy = InsertSpy()
        let submitSpy = SubmitSpy()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, method, text in await insertSpy.record(method, text) },
            submitKey: { await submitSpy.record($0) },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { accessibility },
            llmClient: llm)

        controller.handleStart()
        controller.handleCommit()
        await controller.dictationTask?.value
        return Result(
            lastResult: controller.lastResult, outcome: history.entries().first?.outcome,
            insertedText: await insertSpy.text, insertionMethod: await insertSpy.method,
            submits: await submitSpy.keys, llm: llm)
    }

    private func mode(
        id: String, liveEdits: Bool = false, privacy: Bool = false,
        replacements: [ReplacementsSet.Rule] = [], connectionId: String? = nil,
        insertion: Mode.Insertion = .paste, trailing: Mode.Trailing = .none, submit: Mode.Submit = .none,
        prompt: String = "Rewrite it."
    ) -> Mode {
        var m = Mode(id: id, name: id)
        m.commands = .init(liveEdits: liveEdits, privacy: privacy)
        m.replacements = .init(includeGlobal: false, rules: replacements)
        m.insertion = insertion
        m.trailing = trailing
        m.submit = submit
        if let connectionId { m.aiRewrite = .init(connection: connectionId, prompt: prompt) }
        return m
    }

    // ── Pipeline wiring (verbatim-first / redaction / restore) ────────────────────────────────────

    @Test func verbatimSurvivesTheTextStagesOnTheNoLLMPath() async {
        let m = mode(id: "code", liveEdits: true,
                     replacements: [ReplacementsSet.Rule(heard: "cat", replace: "dog", regex: false)])
        let out = await run(transcript: "a cat begin verbatim a cat end verbatim", mode: m)
        #expect(out.lastResult == "a dog a cat")
    }

    @Test func verbatimAndRedactionAreTokenizedBeforeTheLLMThenRestored() async {
        let m = mode(id: "polish", liveEdits: true, privacy: true, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "begin verbatim Mr Smith end verbatim email alice@example.com",
            mode: m, connection: conn, llm: EchoLLM())

        #expect(out.lastResult == "Mr Smith email alice@example.com")
        #expect(out.outcome == .inserted)
        let sent = await (out.llm as! EchoLLM).lastUser
        #expect(sent.contains("⟦SN:VERB:1⟧"))
        #expect(sent.contains("⟦SN:REDACT:1⟧"))
        #expect(!sent.contains("Mr Smith"))
        #expect(!sent.contains("alice@example.com"))
    }

    @Test func droppedTokensFallBackToRestoredLocalText() async {
        let m = mode(id: "polish", liveEdits: true, privacy: true, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "begin verbatim Mr Smith end verbatim email alice@example.com",
            mode: m, connection: conn, llm: DropTokenLLM())

        #expect(out.lastResult == "Mr Smith email alice@example.com")
        #expect(out.outcome == .localFallback)
    }

    // ── Insertion-end features: trailing + submit (the just-added work) ────────────────────────────

    @Test func trailingSpaceRidesInsideTheInsert() async {
        let out = await run(transcript: "hello", mode: mode(id: "t", trailing: .space))
        #expect(out.insertedText == "hello ")
        #expect(out.lastResult == "hello")          // lastResult is the transcript; suffix is insert-only
    }

    @Test func trailingNewlineRidesInsideTheInsert() async {
        let out = await run(transcript: "hello", mode: mode(id: "t", trailing: .newline))
        #expect(out.insertedText == "hello\n")
    }

    @Test func submitKeystrokeFiresOnAVerifiedInsert() async {
        let out = await run(transcript: "send it", mode: mode(id: "s", submit: .cmdReturn))
        #expect(out.outcome == .inserted)
        #expect(out.submits == [.cmdReturn])
    }

    // The load-bearing guarantee: a submit keystroke must NEVER fire on a clipboard fallback (the text
    // did not reach the target, so a synthesized Return would hit whatever is now focused).
    @Test func submitNeverFiresOnClipboardFallback() async {
        let out = await run(transcript: "send it", mode: mode(id: "s", submit: .return), accessibility: false)
        #expect(out.outcome == .copied)
        #expect(out.submits.isEmpty)
        #expect(out.insertedText == "send it")       // trailing/insert still happens; only submit is gated
    }

    @Test func insertionMethodIsHonoredAndTrailingAndSubmitCompose() async {
        let out = await run(transcript: "done", mode: mode(id: "m", insertion: .type, trailing: .space, submit: .return))
        #expect(out.insertionMethod == .type)
        #expect(out.insertedText == "done ")
        #expect(out.submits == [.return])
    }

    // Modes round-trip through TOML on disk (the harness writes via ModeStore + reads via ConfigCache),
    // so this also proves trailing/submit decode/encode.
    @Test func trailingAndSubmitRoundTripThroughTOML() async {
        let out = await run(transcript: "x", mode: mode(id: "rt", trailing: .newline, submit: .shiftReturn))
        #expect(out.insertedText == "x\n")
        #expect(out.submits == [.shiftReturn])
    }

    // ── Real local LLM (oMLX). Opt-in: RUN_OMLX_TEST=1 OMLX_KEY=… [OMLX_MODEL=…] OMLX_BASE=… ────────
    // Exercises the REAL HTTPLLMClient → local model → validation gate → restore → insert path.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_OMLX_TEST"] == "1"))
    func realLocalModelRewriteCompletesThroughTheGate() async {
        let env = ProcessInfo.processInfo.environment
        let key = env["OMLX_KEY"] ?? ""
        let model = env["OMLX_MODEL"] ?? "Qwen3-Coder-30B-A3B-Instruct-4bit"
        let base = env["OMLX_BASE"] ?? "http://127.0.0.1:11234/v1"

        var conn = Connection(id: "omlx", name: "oMLX", provider: .openaiCompatible, model: model, keyRef: "omlx")
        conn.baseUrl = base
        let client = HTTPLLMClient(keyProvider: { _ in key })

        let m = mode(id: "formal", connectionId: "omlx",
                     prompt: "Rewrite the text to be more formal and grammatical. Return ONLY the rewritten text.")
        let out = await run(
            transcript: "hey whats up i wanna know the status of the thing",
            mode: m, connection: conn, llm: client)

        #expect(out.lastResult?.isEmpty == false)
        #expect(out.outcome == .inserted)            // gate passed → a real rewrite was inserted (not fallback)
    }
}
