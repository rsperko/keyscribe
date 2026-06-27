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
        func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL { url }
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

    @MainActor
    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private struct Result {
        let lastResult: String?
        let outcome: HistoryEntry.Outcome?
        let insertedText: String?
        let insertionMethod: Mode.Insertion?
        let submits: [Mode.Submit]
        let llm: any LLMClient
        let historyEntry: HistoryEntry?
        let lastHUD: HUDState?
    }

    private func run(
        transcript: String, mode: Mode, connection: Connection? = nil,
        llm: any LLMClient = DropTokenLLM(), accessibility: Bool = true,
        captureSelection: @escaping () async -> String? = { nil }
    ) async -> Result {
        await run(transcript: transcript, modes: [mode], defaultModeId: mode.id,
                  connection: connection, llm: llm, accessibility: accessibility,
                  captureSelection: captureSelection)
    }

    private func run(
        transcript: String, modes: [Mode], defaultModeId: String, connection: Connection? = nil,
        llm: any LLMClient = DropTokenLLM(), accessibility: Bool = true,
        captureSelection: @escaping () async -> String? = { nil }
    ) async -> Result {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-wiring-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        for mode in modes { try? ModeStore.write(mode, to: modesDir) }
        if let connection {
            try? ConnectionStore.write(ConnectionSet(connections: [connection]), to: supportDir)
        }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        settings.defaultModeId = defaultModeId

        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let history = HistoryStore(supportDir: supportDir)
        let insertSpy = InsertSpy()
        let submitSpy = SubmitSpy()
        let hudSpy = HUDSpy()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: hudSpy,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, method, text in await insertSpy.record(method, text) },
            submitKey: { await submitSpy.record($0) },
            captureSelection: captureSelection,
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { accessibility },
            llmClient: llm)

        controller.handleStart()
        controller.handleCommit()
        await controller.captureBringUpTask?.value   // mic bring-up is async; commit is deferred until it lands
        await controller.dictationTask?.value
        let entry = history.entries().first
        return Result(
            lastResult: controller.lastResult, outcome: entry?.outcome,
            insertedText: await insertSpy.text, insertionMethod: await insertSpy.method,
            submits: await submitSpy.keys, llm: llm, historyEntry: entry,
            lastHUD: hudSpy.states.last)
    }

    private func mode(
        id: String, liveEdits: Bool = false, privacy: Bool = false,
        replacements: [ReplacementsSet.Rule] = [], connectionId: String? = nil,
        insertion: Mode.Insertion = .paste, trailing: Mode.Trailing = .none, submit: Mode.Submit = .none,
        prompt: String = "Rewrite it.", triggerPhrases: [String] = [],
        context: Mode.ContextOptIn = .init(), source: Mode.Source = .dictation
    ) -> Mode {
        var m = Mode(id: id, name: id)
        m.source = source
        m.commands = .init(liveEdits: liveEdits, privacy: privacy)
        m.replacements = .init(includeGlobal: false, rules: replacements)
        m.insertion = insertion
        m.trailing = trailing
        m.submit = submit
        m.triggerPhrases = triggerPhrases
        if let connectionId { m.aiRewrite = .init(connection: connectionId, prompt: prompt, context: context) }
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

    // Privacy mode forces every context channel off, even when the mode explicitly opts into all of
    // them (design.md §4.4 — the redacted transcript is the only user content that may leave). The
    // controller must consult effectiveContext, not the raw opt-in: if it used the raw flags the app
    // child would render (appName falls back to the bundle id) and the categories would be recorded.
    @Test func privacyModeForcesAllContextOffEvenWhenTheModeRequestsIt() async {
        let m = mode(id: "secure", privacy: true, connectionId: "c",
                     context: .init(app: true, precedingText: true))
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(transcript: "draft the memo", mode: m, connection: conn, llm: EchoLLM())

        let sent = await (out.llm as! EchoLLM).lastUser
        #expect(!sent.contains("<context>"))
        #expect(!sent.contains("test.bundle"))
        #expect(out.historyEntry?.contextCategories == [])
        #expect(out.historyEntry?.redaction == true)
    }

    // The persisted history prompt mirrors the cloud payload: it carries the ⟦SN:…⟧ tokens, never the
    // original redacted span (design.md §4.7). The wiring test proves the LIVE payload is tokenized;
    // this proves the DURABLE record on disk is too — a regression here writes plaintext secrets to
    // history.
    @Test func historyPromptStoresTokensNotTheOriginalRedactedSpan() async {
        let m = mode(id: "secure", privacy: true, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(transcript: "email alice@example.com", mode: m, connection: conn, llm: EchoLLM())

        #expect(out.lastResult == "email alice@example.com")
        #expect(out.historyEntry?.redaction == true)
        let prompt = out.historyEntry?.prompt ?? ""
        #expect(prompt.contains("⟦SN:REDACT:1⟧"))
        #expect(!prompt.contains("alice@example.com"))
    }

    // Phase B (design.md §4.3): a trailing trigger phrase re-routes to that mode's pipeline AND is
    // stripped from the transcript. Proven through the real controller: only the routed mode carries a
    // replacement, so the rule firing proves the route, and the absent phrase proves the strip.
    @Test func phaseBTriggerPhraseRoutesToThatModeAndStripsThePhrase() async {
        let plain = mode(id: "plain")
        let coder = mode(id: "coder",
                         replacements: [ReplacementsSet.Rule(heard: "function", replace: "func", regex: false)],
                         triggerPhrases: ["in code mode"])
        let out = await run(transcript: "define a function in code mode",
                            modes: [plain, coder], defaultModeId: plain.id)
        #expect(out.lastResult == "define a func")
    }

    // ── Edit-in-place (selection mode) ─────────────────────────────────────────────────────────────

    // A selection rewrite that fails the gate (dropped tokens → local fallback) must ABORT and leave the
    // selection untouched — a destructive op never clobbers the user's text on failure (design.md §4.3).
    // The redactable span in the selection forces a token to be issued, which DropTokenLLM drops.
    @Test func selectionRewriteFailureAbortsWithoutTouchingTheSelection() async {
        let m = mode(id: "edit", privacy: true, connectionId: "c", source: .selection)
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "make it formal", mode: m, connection: conn, llm: DropTokenLLM(),
            captureSelection: { "reach me at bob@example.com" })

        #expect(out.insertedText == nil)
        #expect(out.lastResult == nil)
        #expect(out.historyEntry == nil)
        #expect(out.lastHUD == .error(message: "Rewrite failed — selection unchanged", action: nil))
    }

    // Edit-in-place happy path: the selection is the content, the spoken words are the instruction, and
    // the rewritten selection is what gets inserted.
    @Test func selectionRewriteInsertsTheRewrittenSelection() async {
        let m = mode(id: "edit", connectionId: "c", source: .selection)
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "make it formal", mode: m, connection: conn, llm: EchoLLM(),
            captureSelection: { "the original text" })

        #expect(out.lastResult == "the original text")
        #expect(out.insertedText == "the original text")
        #expect(out.outcome == .inserted)
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
