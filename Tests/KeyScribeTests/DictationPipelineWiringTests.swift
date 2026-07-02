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
        let supportsRecognitionBias: Bool
        private let text: String
        private let lock = NSLock()
        private var _lastBiasTerms: [String] = []
        var lastBiasTerms: [String] { lock.withLock { _lastBiasTerms } }
        init(text: String, supportsRecognitionBias: Bool = false) {
            self.text = text
            self.supportsRecognitionBias = supportsRecognitionBias
        }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            lock.withLock { _lastBiasTerms = biasTerms }
            return text
        }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
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

    private struct BoundaryTrimmingLLM: LLMClient {
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            "Hello."
        }
    }

    // Captures the real insertion call (method + the exact string, which includes the trailing suffix).
    private actor InsertSpy {
        private(set) var method: Mode.Insertion?
        private(set) var modifier: Mode.ClipboardModifier?
        private(set) var text: String?
        func record(_ m: Mode.Insertion, _ mod: Mode.ClipboardModifier, _ t: String) { method = m; modifier = mod; text = t }
    }

    // Captures every post-insert submit keystroke the controller fires.
    private actor SubmitSpy {
        private(set) var keys: [Mode.Submit] = []
        func record(_ s: Mode.Submit) { keys.append(s) }
    }

    private actor ModifierSpy {
        private(set) var value: Mode.ClipboardModifier?
        func set(_ m: Mode.ClipboardModifier) { value = m }
    }

    @MainActor
    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    // Returns the captured target's bundle for the first two snapshot() reads (handleStart capture +
    // finishInsertion entry), then a different bundle for the pre-submit re-snapshot — simulating the
    // user switching apps during the paste-settle window.
    @MainActor private final class FocusSequence {
        private var calls = 0
        func next() -> TargetSnapshot {
            defer { calls += 1 }
            return TargetSnapshot(bundleId: calls < 2 ? "test.bundle" : "other.bundle")
        }
    }

    // Same app throughout, but the focused window changes for the pre-submit snapshot — a same-app
    // window switch during the paste-settle window that a bundle-only check would miss.
    @MainActor private final class WindowSwitchSequence {
        private var calls = 0
        func next() -> TargetSnapshot {
            defer { calls += 1 }
            return TargetSnapshot(bundleId: "test.bundle", focusedWindowId: calls < 2 ? "w1" : "w2")
        }
    }

    // Counts how many times the host read the clipboard seam (all on the main actor).
    @MainActor private final class ClipboardReads { var count = 0 }

    private struct Result {
        let lastResult: String?
        let clipboardReadCount: Int
        let outcome: HistoryEntry.Outcome?
        let insertedText: String?
        let insertionMethod: Mode.Insertion?
        let insertedModifier: Mode.ClipboardModifier?
        let submits: [Mode.Submit]
        let llm: any LLMClient
        let historyEntry: HistoryEntry?
        let lastHUD: HUDState?
        let recordedBiasTerms: [String]
    }

    private func run(
        transcript: String, mode: Mode, connection: Connection? = nil,
        llm: any LLMClient = DropTokenLLM(), accessibility: Bool = true,
        captureSelection: @escaping (Mode.ClipboardModifier) async -> String? = { _ in nil },
        clipboard: String? = nil,
        dictionaryRecoveryEnabled: Bool? = nil,
        recognitionBiasEnabled: Bool? = nil,
        engineSupportsRecognitionBias: Bool = false,
        updateSettingsAfterStart: ((inout Settings) -> Void)? = nil
    ) async -> Result {
        await run(transcript: transcript, modes: [mode], defaultModeId: mode.id,
                  connection: connection, llm: llm, accessibility: accessibility,
                  captureSelection: captureSelection, clipboard: clipboard,
                  dictionaryRecoveryEnabled: dictionaryRecoveryEnabled,
                  recognitionBiasEnabled: recognitionBiasEnabled,
                  engineSupportsRecognitionBias: engineSupportsRecognitionBias,
                  updateSettingsAfterStart: updateSettingsAfterStart)
    }

    private func run(
        transcript: String, modes: [Mode], defaultModeId: String, connection: Connection? = nil,
        llm: any LLMClient = DropTokenLLM(), accessibility: Bool = true,
        captureSelection: @escaping (Mode.ClipboardModifier) async -> String? = { _ in nil },
        clipboard: String? = nil,
        dictionaryRecoveryEnabled: Bool? = nil,
        recognitionBiasEnabled: Bool? = nil,
        engineSupportsRecognitionBias: Bool = false,
        insertSucceeds: Bool = true,
        snapshotProvider: (@MainActor () -> TargetSnapshot)? = nil,
        updateSettingsAfterStart: ((inout Settings) -> Void)? = nil
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
        if let dictionaryRecoveryEnabled {
            if dictionaryRecoveryEnabled {
                settings.stt.dictionaryRecoveryEnabledEngines = ["fixed"]
                settings.stt.dictionaryRecoveryDisabledEngines = []
            } else {
                settings.stt.dictionaryRecoveryEnabledEngines = []
                settings.stt.dictionaryRecoveryDisabledEngines = ["fixed"]
            }
        }
        if let recognitionBiasEnabled {
            settings.stt.recognitionBiasDisabledEngines = recognitionBiasEnabled ? [] : ["fixed"]
        }
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let engine = FixedEngine(text: transcript, supportsRecognitionBias: engineSupportsRecognitionBias)
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "fixed")
        let history = HistoryStore(supportDir: supportDir)
        let insertSpy = InsertSpy()
        let submitSpy = SubmitSpy()
        let hudSpy = HUDSpy()
        let clipboardReads = ClipboardReads()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: hudSpy,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, method, modifier, text in await insertSpy.record(method, modifier, text); return insertSucceeds },
            submitKey: { await submitSpy.record($0) },
            captureSelection: captureSelection,
            clipboard: { clipboardReads.count += 1; return clipboard },
            snapshot: snapshotProvider ?? { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { accessibility },
            llmClient: llm)

        controller.setNextModeOverride(id: defaultModeId)   // select the mode under test
        controller.handleStart()
        if let updateSettingsAfterStart {
            updateSettingsAfterStart(&settings)
            controller.updateSettings(settings)
        }
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        let entry = await firstHistoryEntry(in: history)
        return Result(
            lastResult: controller.lastResult, clipboardReadCount: clipboardReads.count, outcome: entry?.outcome,
            insertedText: await insertSpy.text, insertionMethod: await insertSpy.method,
            insertedModifier: await insertSpy.modifier,
            submits: await submitSpy.keys, llm: llm, historyEntry: entry,
            lastHUD: hudSpy.states.last, recordedBiasTerms: engine.lastBiasTerms)
    }

    private func firstHistoryEntry(in history: HistoryStore) async -> HistoryEntry? {
        for _ in 0..<20 {
            if let entry = history.entries().first { return entry }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
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

    // The local pipeline runs on EVERY dictation, so history records the on-device intermediate even
    // when local processing changed nothing. Otherwise a no-op leaves no artifact, and the JSONL (or
    // anything mining it) reads "the local pipeline was skipped" — the exact misread that prompted this.
    // `transformed` is the local output recorded unconditionally; it equals `heard` when nothing changed.
    @Test func transformedRecordsLocalOutputEvenWhenLocalIsANoOp() async {
        let out = await run(transcript: "hello world", mode: mode(id: "plain"))
        #expect(out.lastResult == "hello world")
        #expect(out.historyEntry?.heard == "hello world")
        #expect(out.historyEntry?.transformed == "hello world")
    }

    @Test func transformedRecordsLocalOutputWhenLocalChangedIt() async {
        let m = mode(id: "code", replacements: [ReplacementsSet.Rule(heard: "cat", replace: "dog", regex: false)])
        let out = await run(transcript: "a cat", mode: m)
        #expect(out.lastResult == "a dog")
        #expect(out.historyEntry?.transformed == "a dog")
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

    // Regression for the reported bug: pausing around the verbatim markers made the STT insert commas
    // that leaked into and around the protected span ("the , new line,, change"). They are now absorbed
    // as pause artifacts, end to end through the real controller and an LLM rewrite.
    @Test func pauseCommasAroundVerbatimAreCleanedEndToEnd() async {
        let m = mode(id: "polish", liveEdits: true, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "make sure the begin verbatim, new line, end verbatim, change is in place",
            mode: m, connection: conn, llm: EchoLLM())

        #expect(out.lastResult == "make sure the new line change is in place")
        let sent = await (out.llm as! EchoLLM).lastUser
        #expect(sent.contains("⟦SN:VERB:1⟧"))
        #expect(!sent.contains("new line"))
    }

    // "insert clipboard contents" pastes the clipboard as a distinct CLIP token: the LLM sees only the
    // token (the pasted content never crosses the cloud boundary) and the original is restored after.
    @Test func clipboardContentsAreTokenizedBeforeTheLLMThenRestored() async {
        let m = mode(id: "polish", liveEdits: true, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "the token is insert clipboard contents thanks",
            mode: m, connection: conn, llm: EchoLLM(), clipboard: "sk-secret-123")

        #expect(out.lastResult == "the token is sk-secret-123 thanks")
        #expect(out.outcome == .inserted)
        let sent = await (out.llm as! EchoLLM).lastUser
        #expect(sent.contains("⟦SN:CLIP:1⟧"))
        #expect(!sent.contains("sk-secret-123"))
        #expect(out.clipboardReadCount == 1)
    }

    // Privacy: an ordinary live-edits dictation never reads the clipboard — only when the command is
    // actually spoken. Guards against silently capturing clipboard text on every dictation.
    @Test func clipboardNotReadWhenCommandAbsent() async {
        let out = await run(
            transcript: "just some ordinary dictated words",
            mode: mode(id: "plain", liveEdits: true), clipboard: "SECRET")
        #expect(out.clipboardReadCount == 0)
        #expect(out.lastResult == "just some ordinary dictated words")
    }

    // A clipboard phrase deliberately wrapped in a verbatim span is literal, so it must not read the
    // clipboard either (the read gate runs after verbatim tokenization).
    @Test func clipboardNotReadWhenPhraseIsInsideVerbatim() async {
        let out = await run(
            transcript: "begin verbatim insert clipboard contents end verbatim",
            mode: mode(id: "plain", liveEdits: true), clipboard: "SECRET")
        #expect(out.clipboardReadCount == 0)
        #expect(out.lastResult == "insert clipboard contents")
    }

    // Regression for the Whisper-Small report: it puts a spurious period before the paste
    // ("directory. <paste>"), which the bracketed-fold removes end-to-end.
    @Test func whisperPeriodBeforePasteIsFoldedEndToEnd() async {
        let out = await run(
            transcript: "Read through the directory. insert clipboard contents. Decide whether this makes any sense.",
            mode: mode(id: "plain", liveEdits: true), clipboard: "agent_notes/foo/")
        #expect(out.lastResult == "Read through the directory agent_notes/foo/. Decide whether this makes any sense.")
    }

    // Two clipboard pastes in one AI-rewrite dictation get DISTINCT tokens, so a faithful rewrite is
    // accepted by the exactly-once gate instead of being rejected into a local fallback.
    @Test func twoClipboardCommandsSurviveTheGateInARewrite() async {
        let m = mode(id: "polish", liveEdits: true, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "first insert clipboard contents then insert clipboard contents",
            mode: m, connection: conn, llm: EchoLLM(), clipboard: "PASTE")
        #expect(out.outcome == .inserted)
        #expect(out.lastResult == "first PASTE then PASTE")
    }

    @Test func liveEditsModeRepairsLLMTrimmedBoundaryNewlinesAndTabs() async {
        let m = mode(id: "polish", liveEdits: true, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "\n\thello\n", mode: m, connection: conn, llm: BoundaryTrimmingLLM())
        #expect(out.lastResult == "\n\tHello.\n")
        #expect(out.insertedText == "\n\tHello.\n")
    }

    @Test func nonLiveEditsModeLeavesLLMBoundaryWhitespaceAlone() async {
        let m = mode(id: "polish", liveEdits: false, connectionId: "c")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let out = await run(
            transcript: "\n\thello\n", mode: m, connection: conn, llm: BoundaryTrimmingLLM())
        #expect(out.lastResult == "Hello.")
        #expect(out.insertedText == "Hello.")
    }

    // No-LLM mode: the paste is literal, no rewrite involved.
    @Test func clipboardContentsInsertLiterallyOnTheNoLLMPath() async {
        let m = mode(id: "plain", liveEdits: true)
        let out = await run(
            transcript: "paste it insert clipboard contents done", mode: m, clipboard: "https://ex.com/a?b=c")
        #expect(out.lastResult == "paste it https://ex.com/a?b=c done")
    }

    // Empty clipboard leaves the spoken phrase as literal text rather than silently deleting it.
    @Test func emptyClipboardLeavesThePhraseLiteral() async {
        let m = mode(id: "plain", liveEdits: true)
        let out = await run(transcript: "insert clipboard contents", mode: m, clipboard: nil)
        #expect(out.lastResult == "insert clipboard contents")
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

    @Test func dictionaryRecoveryCorrectsBiaslessEngineWhenEnabled() async {
        var m = mode(id: "plain")
        m.dictionary = .init(includeGlobal: false, words: ["ChargeBee"])
        let out = await run(
            transcript: "charge bee", mode: m,
            dictionaryRecoveryEnabled: true)
        #expect(out.lastResult == "ChargeBee")
    }

    @Test func dictionaryRecoveryUsesRecordStartSettings() async {
        var m = mode(id: "plain")
        m.dictionary = .init(includeGlobal: false, words: ["ChargeBee"])
        let out = await run(
            transcript: "charge bee", mode: m,
            dictionaryRecoveryEnabled: true,
            updateSettingsAfterStart: { settings in
                settings.stt.dictionaryRecoveryEnabledEngines = []
                settings.stt.dictionaryRecoveryDisabledEngines = ["fixed"]
            })
        #expect(out.lastResult == "ChargeBee")
    }

    @Test func recognitionBiasReachesBiasCapableEngineByDefault() async {
        var m = mode(id: "plain")
        m.dictionary = .init(includeGlobal: false, words: ["ChargeBee"])
        let out = await run(
            transcript: "hello", mode: m,
            engineSupportsRecognitionBias: true)
        #expect(out.recordedBiasTerms == ["ChargeBee"])
    }

    @Test func disablingRecognitionBiasSuppressesBiasTermsForBiasCapableEngine() async {
        var m = mode(id: "plain")
        m.dictionary = .init(includeGlobal: false, words: ["ChargeBee"])
        let out = await run(
            transcript: "hello", mode: m,
            recognitionBiasEnabled: false,
            engineSupportsRecognitionBias: true)
        #expect(out.recordedBiasTerms.isEmpty)
    }

    @Test func biaslessEngineNeverReceivesBiasTerms() async {
        var m = mode(id: "plain")
        m.dictionary = .init(includeGlobal: false, words: ["ChargeBee"])
        let out = await run(
            transcript: "hello", mode: m,
            engineSupportsRecognitionBias: false)
        #expect(out.recordedBiasTerms.isEmpty)
    }

    @Test func dictionaryRecoveryDefaultsOffForBiasCapableEngine() async {
        var m = mode(id: "plain")
        m.dictionary = .init(includeGlobal: false, words: ["ChargeBee"])
        let out = await run(
            transcript: "charge bee", mode: m,
            engineSupportsRecognitionBias: true)
        #expect(out.lastResult == "charge bee")
    }

    @Test func dictionaryRecoveryCanRunForBiasCapableEngine() async {
        var m = mode(id: "plain")
        m.dictionary = .init(includeGlobal: false, words: ["ChargeBee"])
        let out = await run(
            transcript: "charge bee", mode: m,
            dictionaryRecoveryEnabled: true,
            engineSupportsRecognitionBias: true)
        #expect(out.lastResult == "ChargeBee")
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
            captureSelection: { _ in "reach me at bob@example.com" })

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
            captureSelection: { _ in "the original text" })

        #expect(out.lastResult == "the original text")
        #expect(out.insertedText == "the original text")
        #expect(out.outcome == .inserted)
    }

    // ── clipboard_modifier: the mode's modifier must reach BOTH clipboard keystrokes ───────────────

    @Test func defaultModeInsertsWithCommandModifier() async {
        let out = await run(transcript: "hello", mode: mode(id: "plain"))
        #expect(out.insertedModifier == .command)
    }

    @Test func clipboardModifierReachesTheInsertKeystroke() async {
        var m = mode(id: "vm")
        m.clipboardModifier = .control
        let out = await run(transcript: "hello", mode: m)
        #expect(out.insertedModifier == .control)
    }

    @Test func clipboardModifierReachesTheSelectionCaptureKeystroke() async {
        var m = mode(id: "vm-edit", connectionId: "c", source: .selection)
        m.clipboardModifier = .control
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let seen = ModifierSpy()
        _ = await run(
            transcript: "make it formal", mode: m, connection: conn, llm: EchoLLM(),
            captureSelection: { mod in await seen.set(mod); return "the original text" })
        #expect(await seen.value == .control)
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

    // W5/H1: the paste silently failed (writeScratchVerified false) — the outcome must NOT claim
    // "inserted" and the submit Return must not fire (it would send a stale draft in a chat app).
    @Test func silentPasteFailureReportsFailedAndSkipsSubmit() async {
        let out = await run(
            transcript: "send it", modes: [mode(id: "s", submit: .return)], defaultModeId: "s",
            insertSucceeds: false)
        #expect(out.outcome == .failed)
        #expect(out.submits.isEmpty)
        #expect(out.lastResult == "send it")   // still recoverable via "Paste last dictation"
    }

    // W5/H4: focus moved between the paste-settle window and the submit — the frontmost app at submit
    // time differs from the captured target, so the Return is skipped (it would fire into the wrong app).
    @Test func submitSkippedWhenFocusMovesBeforeReturn() async {
        let focus = FocusSequence()   // "test.bundle" for capture + finishInsertion, then "other.bundle"
        let out = await run(
            transcript: "send it", modes: [mode(id: "s", submit: .return)], defaultModeId: "s",
            snapshotProvider: { focus.next() })
        #expect(out.outcome == .inserted)   // the text DID land; only the submit is suppressed
        #expect(out.submits.isEmpty)
    }

    // W5/H4, same-app window switch: bundle id is unchanged but the focused window moved, so the submit
    // must still be suppressed (the insertion focus guard, reused here, compares window id too).
    @Test func submitSkippedWhenWindowSwitchesWithinSameApp() async {
        let focus = WindowSwitchSequence()
        let out = await run(
            transcript: "send it", modes: [mode(id: "s", submit: .return)], defaultModeId: "s",
            snapshotProvider: { focus.next() })
        #expect(out.outcome == .inserted)
        #expect(out.submits.isEmpty)
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

struct WarmupBiasTermsTests {
    private struct Engine: SpeechEngine {
        let id: String
        let supportsRecognitionBias: Bool
        var displayName: String { id }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "" }
        func evict() async {}
    }

    @MainActor
    @Test func warmupBiasRespectsDisabledEngineGate() {
        var settings = Settings.defaults
        settings.stt.recognitionBiasDisabledEngines = ["fixed"]
        let config = ResolvedConfig(
            modes: [],
            dictionary: DictionarySet(words: ["Global"]),
            replacements: ReplacementsSet(),
            connections: ConnectionSet(),
            fragments: [:])

        let terms = DictationController.warmupBiasTerms(
            settings: settings,
            engine: Engine(id: "fixed", supportsRecognitionBias: true),
            plan: config)

        #expect(terms == [])
    }

    @MainActor
    @Test func warmupBiasUsesGlobalDictionaryWhenEnabled() {
        let config = ResolvedConfig(
            modes: [],
            dictionary: DictionarySet(words: ["Global"]),
            replacements: ReplacementsSet(),
            connections: ConnectionSet(),
            fragments: [:])

        let terms = DictationController.warmupBiasTerms(
            settings: .defaults,
            engine: Engine(id: "fixed", supportsRecognitionBias: true),
            plan: config)

        #expect(terms == ["Global"])
    }
}
