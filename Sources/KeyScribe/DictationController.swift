import AVFoundation
import Foundation
import KeyScribeKit
import os

@MainActor
final class DictationController {
    static let fallbackModeName = "Plain Dictation"
    private let log = Logger(subsystem: "com.keyscribe.app", category: "dictation")

    // Visible-text context caps (prompt_design.md §Context & token budget — measured defaults vs
    // the Gemini 2.5 Flash floor). Visible text is the lowest-priority block, capped aggressively;
    // the budget bounds the mandatory content (instructions + transcript/selection).
    private static let visibleTextCap = 4000
    private static let contextBudgetChars = 24000

    private(set) var settings: Settings
    private let provider: SpeechEngineProvider
    private let config: ConfigCache
    private let history: HistoryStore?
    private let audio: AudioCapturing
    private let insert: (InsertionDecision, Mode.Insertion, String) async -> Void
    private let snapshot: @MainActor () -> TargetSnapshot
    private let micStatus: @MainActor () -> PermissionStatus
    private let accessibilityGranted: @MainActor () -> Bool
    private let llmClient: any LLMClient
    private let effects = DuringDictationEffects()
    private weak var hud: HUDPresenting?

    private var machine = DictationMachine()
    private var capturedSnapshot: TargetSnapshot?
    private var activeMode: Mode?
    private var eligibleModes: [Mode] = []
    private var routingContext = RoutingContext()
    private var hideTask: Task<Void, Never>?
    private var idleEvictionTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private(set) var dictationTask: Task<Void, Never>?
    private var lastUsedAt: Double = 0
    private(set) var lastResult: String?
    private var nextModeOverrideID: String?
    private var pendingLocalTranscript: String?
    private var pendingHeardTranscript: String?
    private var rewriteEscapeTask: Task<Void, Never>?

    // Per-(mode, config generation) derived artifacts, so a dictation reuses them instead of
    // re-merging the dictionary three times and rebuilding the pipeline stages every commit. Both are
    // dropped wholesale whenever the config generation advances (see refreshDerivedCachesIfNeeded).
    private var derivedGeneration = -1
    private var pipelineCache: [String: Pipeline] = [:]
    private var mergedDictionaryCache: [String: [String]] = [:]
    private static let nilModeKey = "\u{0}nil"

    // Last HUD level rendered while recording (quantized). The mic level callback fires per audio
    // buffer; forwarding only on a meaningful change keeps the HUD from re-rendering its whole tree at
    // buffer rate (the indicator animates between steps anyway). Reset at the start of each recording.
    private var lastRenderedLevel: Float = -1

    // The mic level callback fires per audio buffer on a background thread. Rather than hop to the main
    // actor for each one (which can pile up unbounded if the main actor is busy), the coalescer keeps a
    // single pending level and at most one in-flight update — late buffers overwrite the pending value.
    // A `let` (not a lazy var) so the Sendable callback can reach it off the main actor; its render
    // closure is wired in init once self is available.
    private let levelCoalescer = LevelCoalescer()

    private func renderLevel(_ level: Float) {
        guard case .recording = machine.state else { return }
        let quantized = (level * 20).rounded() / 20
        guard quantized != lastRenderedLevel else { return }
        lastRenderedLevel = quantized
        hud?.render(.recording(mode: currentModeName, level: quantized))
    }

    // Fired after every terminal insertion outcome. First run uses it to require one real successful
    // dictation before completing onboarding (ui_design.md §2).
    var onDictationCompleted: ((DictationOutcome) -> Void)?

    // Fired true when capture starts, false when it ends (commit or a start failure). The menu-bar
    // glyph tints red while true (ui_design.md §Dynamic status).
    var onRecordingChanged: ((Bool) -> Void)?

    var hasResult: Bool { lastResult != nil }
    var nextModeOverrideName: String? {
        nextModeOverrideID.flatMap { id in config.modes.first { $0.id == id }?.name }
    }
    private var currentModeName: String { activeMode?.name ?? Self.fallbackModeName }

    init(
        settings: Settings, provider: SpeechEngineProvider,
        config: ConfigCache, history: HistoryStore?, hud: HUDPresenting?,
        audio: AudioCapturing = AudioCapture(),
        insert: @escaping (InsertionDecision, Mode.Insertion, String) async -> Void = TextInserter.perform,
        snapshot: @escaping @MainActor () -> TargetSnapshot = ContextProbe.snapshot,
        micStatus: @escaping @MainActor () -> PermissionStatus = { Permissions.microphoneStatus() },
        accessibilityGranted: @escaping @MainActor () -> Bool = { Permissions.accessibilityStatus() == .granted },
        llmClient: any LLMClient = HTTPLLMClient()
    ) {
        self.settings = settings
        self.provider = provider
        self.config = config
        self.history = history
        self.hud = hud
        self.audio = audio
        self.insert = insert
        self.snapshot = snapshot
        self.micStatus = micStatus
        self.accessibilityGranted = accessibilityGranted
        self.llmClient = llmClient
        levelCoalescer.onLevel = { [weak self] level in self?.renderLevel(level) }
        installMemoryPressureHandler()
    }

    // Free the resident STT model (27–38MB up to the larger Qwen3 tiers) when the OS reports critical
    // memory pressure — but only when idle. An in-flight dictation keeps its engine (evicting mid-flight
    // would lose the transcription); the next idle check or the post-dictation eviction policy reclaims
    // it later. Local reaction to a local signal — never reported anywhere (no telemetry).
    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.machine.isBusy else { return }
                let active = self.provider.active
                self.log.notice("memory pressure (critical): evicting \(active.id, privacy: .public)")
                Task { await active.evict() }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func updateSettings(_ settings: Settings) { self.settings = settings }

    // Warm the active STT engine the instant a press begins, overlapping model load (CoreML/MLX
    // compile, ANE warmup) with the user's speech instead of paying it after key-release. Idempotent
    // — a no-op once loaded — and never blocks recording: failures surface later at transcribe time.
    private func warmActiveEngine() {
        let active = provider.active
        Task { try? await active.loadIfNeeded() }
    }

    // Launch-time preload for the Fastest eviction profile, so the first dictation isn't a cold load
    // (design: EvictionPolicy.preloadAtLaunch). Other profiles stay lazy.
    func preloadActiveEngineIfNeeded() {
        guard EvictionPolicy.preloadAtLaunch(mode: settings.stt.eviction) else { return }
        warmActiveEngine()
    }

    func setNextModeOverride(id: String?) {
        nextModeOverrideID = id.flatMap { candidate in
            config.modes.first { $0.id == candidate && $0.enabled }?.id
        }
    }

    // ui_design.md §6: a one-shot mode picked from the menu is acknowledged in the HUD before the
    // next dictation. Only when idle — never stomp an in-flight dictation's state.
    func acknowledgeNextMode() {
        guard !machine.isBusy, let name = nextModeOverrideName else { return }
        hud?.render(.ready(mode: name))
        scheduleHide()
    }

    func handleStart(triggerKey: String? = nil) {
        guard machine.beginRecording() else { return }
        hideTask?.cancel()
        idleEvictionTask?.cancel()
        // A denied mic does NOT make AVAudioEngine throw — it starts and captures silence, which would
        // surface as a misleading "No speech detected". Catch the real cause up front and point the user
        // at the fix instead of recording nothing.
        if micStatus() == .denied {
            finishError("Microphone access is off", action: .openMicrophoneSettings)
            return
        }
        capturedSnapshot = snapshot()
        resolveMode(triggerKey: triggerKey)
        warmActiveEngine()
        effects.begin(settings.duringDictation)
        lastRenderedLevel = 0
        hud?.render(.recording(mode: currentModeName, level: 0))
        do {
            _ = try audio.start { [weak self] level in
                self?.levelCoalescer.submit(level)
            }
            onRecordingChanged?(true)
        } catch {
            finishError("Could not start the microphone", action: .openMicrophoneSettings)
        }
    }

    func handleCommit() {
        guard machine.state == .recording else { return }
        onRecordingChanged?(false)
        machine.beginTranscribing()
        guard let url = audio.stop() else {
            machine.cancel()
            effects.end(settings.duringDictation)
            hud?.render(.hidden)
            return
        }
        if let f = try? AVAudioFile(forReading: url) {
            log.debug("wav \(f.length) frames @ \(f.fileFormat.sampleRate, privacy: .public)Hz ch=\(f.fileFormat.channelCount, privacy: .public)")
        } else {
            log.error("wav unreadable at \(url.path, privacy: .public)")
        }
        hud?.render(.transcribing(mode: currentModeName))
        dictationTask = Task { await transcribeAndInsert(url: url) }
    }

    // Phase A (design.md §4.3): resolve the mode from app/URL context before recording. A non-nil
    // triggerKey (from a mode's own HotkeyMonitor binding) forces that mode, overriding context.
    private func resolveMode(triggerKey: String?) {
        let modes = config.modes
        let bundleId = capturedSnapshot?.bundleId
        let url = (ModeResolver.requiresURLContext(modes) ? bundleId : nil)
            .flatMap { ContextProbe.browserURL(forBundleId: $0) }
        let context = RoutingContext(bundleId: bundleId, url: url)
        routingContext = context
        eligibleModes = ModeResolver.eligibleModes(modes, context: context)
        let automaticMode = ModeResolver.resolvePhaseA(
            modes: modes, defaultModeId: settings.defaultModeId, context: context, triggerKey: triggerKey)
        let override = nextModeOverrideID.flatMap { id in modes.first { $0.id == id && $0.enabled } }
        nextModeOverrideID = nil
        activeMode = override ?? automaticMode
    }

    // Dictionary terms fed to the engine's recognition bias before STT. Only the Phase-A mode's
    // dictionary (⊕ global) is known here — a Phase-B voice route resolves post-STT and so cannot
    // bias recognition (design.md §4.3). Normalized once here (VocabularyMerge already dedups in
    // stable order; this trims and drops blanks) so engines consume clean terms. Engines without
    // bias ignore these.
    private func recognitionBiasTerms() -> [String] {
        guard provider.active.supportsRecognitionBias else { return [] }
        return mergedDictionaryWords(for: activeMode)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // Global ⊕ mode dictionary, merged once per (mode, config generation). Three call sites need it
    // each dictation (recognition bias, the rewrite "valid term" hint, fuzzy correction); the merge
    // (VocabularyMerge dedups in stable order) is pure config, so it is cached, not recomputed.
    private func mergedDictionaryWords(for mode: Mode?) -> [String] {
        refreshDerivedCachesIfNeeded()
        let key = mode?.id ?? Self.nilModeKey
        if let cached = mergedDictionaryCache[key] { return cached }
        let words = mode.map { m in
            VocabularyMerge.words(
                global: config.dictionary.words,
                local: m.dictionary.words, includeGlobal: m.dictionary.includeGlobal)
        } ?? config.dictionary.words
        mergedDictionaryCache[key] = words
        return words
    }

    private func refreshDerivedCachesIfNeeded() {
        guard config.generation != derivedGeneration else { return }
        derivedGeneration = config.generation
        pipelineCache.removeAll(keepingCapacity: true)
        mergedDictionaryCache.removeAll(keepingCapacity: true)
    }

    struct TranscribeTimeout: Error {}

    // Bound the STT call so a wedged CoreML/MLX transcribe can't leave the HUD spinning forever.
    // Batch dictation can't salvage a partial, so this is robustness, not speed — the cap scales with
    // the recording length (20× real-time, ≥30s floor), generous enough to never trip on a legitimately
    // long or slow transcription while still abandoning a true hang. The losing engine task is
    // cancelled; if the engine ignores cancellation it finishes in the background, harmlessly discarded.
    private func transcribeBounded(url: URL, biasTerms: [String]) async throws -> String {
        let engine = provider.active
        let audioSeconds = (try? AVAudioFile(forReading: url))
            .map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        let timeout = max(30, audioSeconds * 20)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await engine.transcribe(wavURL: url, biasTerms: biasTerms) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TranscribeTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TranscribeTimeout() }
            return first
        }
    }

    private func transcribeAndInsert(url: URL) async {
        let raw: String
        do {
            raw = try await transcribeBounded(url: url, biasTerms: recognitionBiasTerms())
        } catch is TranscribeTimeout {
            log.error("transcribe timed out (\(self.provider.active.id, privacy: .public))")
            try? FileManager.default.removeItem(at: url)
            finishError("Transcription timed out")
            return
        } catch {
            log.error("transcribe failed (\(self.provider.active.id, privacy: .public)): \(error, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            finishError("Transcription failed")
            return
        }
        try? FileManager.default.removeItem(at: url)

        // Cancelled during STT: bail before routing, rewrite, insertion, or history. cancel() already
        // ended effects and hid the HUD — a stale task must not run the cloud rewrite, touch the
        // target, or mutate routing state a newer dictation may now own.
        if Task.isCancelled { return }

        // Phase B (design.md §4.3): a trigger-phrase suffix re-routes to that mode's pipeline
        // and is stripped from the transcript; otherwise the Phase-A mode stands.
        let routed = ModeResolver.resolvePhaseB(eligibleModes: eligibleModes, transcript: raw, context: routingContext)
        let finalMode = routed.routedModeId.flatMap { id in eligibleModes.first { $0.id == id } } ?? activeMode
        if let finalMode { activeMode = finalMode }
        pendingHeardTranscript = raw
        let (final, rewrite, transformed) = await produceFinalText(routed: routed, mode: finalMode)

        // Cancelled during the rewrite: bail before any insert or history write.
        if Task.isCancelled { return }

        switch final {
        case .abort(let message, let action):
            // A selection rewrite that failed (or had nothing to do) leaves the target untouched —
            // a destructive op must never overwrite the user's text on failure.
            log.info("aborted: \(message, privacy: .public)")
            finishError(message, action: action)
            clearRewriteEscapeHatch()
            applyEvictionAfterDictation()

        case .insert(let transcript):
            await finishInsertion(transcript: transcript, heard: raw, transformed: transformed, rewrite: rewrite)
        }
    }

    private func finishInsertion(
        transcript: String, heard: String, transformed: String? = nil, rewrite: RewriteDetails?
    ) async {
        clearRewriteEscapeHatch()
        machine.beginInserting()
        let current = snapshot()
        let targetDecision = decideInsertion(
            captured: capturedSnapshot ?? TargetSnapshot(bundleId: nil), current: current)
        // Without Accessibility every synthetic insertion path is silently dropped by the OS (the M0
        // false-`.success` data-loss footgun). Divert to the clipboard so the text survives and the
        // outcome reports "copied" truthfully instead of a phantom "inserted".
        let decision = accessibilityGranted() ? targetDecision : .clipboardFallback(reason: .accessibilityDenied)
        let outcome = DictationMachine.outcomeForTranscript(transcript, decision: decision)
        switch outcome {
        case .noSpeech:
            machine.finish(.noSpeech)
        case .inserted, .copied:
            lastResult = transcript
            await insert(decision, activeMode?.insertion ?? .paste, transcript)
            machine.finish(outcome)
        case .failed:
            machine.finish(outcome)
        }
        recordHistory(heard: heard, transformed: transformed, result: transcript, insertion: outcome, rewrite: rewrite)
        effects.end(settings.duringDictation)
        hud?.render(rewrite?.fellBack == true
            ? .localFallback(outcome: outcome, mode: currentModeName)
            : .complete(outcome: outcome, mode: currentModeName))
        scheduleHide()
        applyEvictionAfterDictation()
        onDictationCompleted?(outcome)
    }

    // Local history (design.md §4.7): one append per dictation that produced text, unless history is
    // off or the mode opts out. noSpeech is not recorded (nothing was said). Audio and the redaction
    // map are never written; the stored prompt carries tokens, not their originals.
    private func recordHistory(
        heard: String, transformed: String?, result: String, insertion: DictationOutcome,
        rewrite: RewriteDetails?
    ) {
        guard settings.history.enabled, !(activeMode?.excludeFromHistory ?? false) else { return }
        let outcome: HistoryEntry.Outcome
        switch insertion {
        case .noSpeech: return
        case .inserted: outcome = rewrite?.fellBack == true ? .localFallback : .inserted
        case .copied: outcome = rewrite?.fellBack == true ? .localFallback : .copied
        case .failed: outcome = .failed
        }
        let entry = HistoryEntry(
            timestamp: Date(), modeName: currentModeName, heard: heard, transformed: transformed,
            result: result, outcome: outcome,
            cloudInvolved: rewrite != nil, redaction: rewrite?.redaction ?? false,
            contextCategories: rewrite?.contextCategories ?? [],
            connection: rewrite?.connection, model: rewrite?.model, prompt: rewrite?.prompt)
        do { try history?.append(entry) }
        catch { log.error("history append failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func applyEvictionAfterDictation() {
        lastUsedAt = ProcessInfo.processInfo.systemUptime
        let idle = settings.stt.evictionIdleSeconds.map(Double.init)
        switch EvictionPolicy.afterDictation(mode: settings.stt.eviction, idleSeconds: idle) {
        case .keepLoaded: break
        case .evictNow:
            let active = provider.active
            Task { await active.evict() }
        case .scheduleIdleCheck(let after): scheduleIdleEviction(after: after)
        }
    }

    private func scheduleIdleEviction(after: Double) {
        idleEvictionTask?.cancel()
        let mode = settings.stt.eviction
        let idle = settings.stt.evictionIdleSeconds.map(Double.init)
        let usedAt = lastUsedAt
        let active = provider.active
        idleEvictionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard let self, !Task.isCancelled, !self.machine.isBusy else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch EvictionPolicy.onIdleCheck(mode: mode, lastUsedAt: usedAt, now: now, idleSeconds: idle) {
            case .evictNow: await active.evict()
            case .scheduleIdleCheck(let again): self.scheduleIdleEviction(after: again)
            case .keepLoaded: break
            }
        }
    }

    private enum FinalText {
        case insert(String)
        // leave the target untouched; surface this message, optionally with a repair action
        case abort(String, HUDErrorAction?)
    }

    // What a cloud rewrite involved, captured for the History detail view. Built only when a rewrite
    // actually ran; the prompt carries the ⟦SN:…⟧ tokens, never their originals.
    private struct RewriteDetails {
        let connection: String
        let model: String
        let redaction: Bool
        let contextCategories: [String]
        let prompt: String
        let fellBack: Bool
    }

    // Dictation mode → the spoken text is the content (pipeline + optional rewrite); we always
    // insert something. Selection mode (edit-in-place) → the selection is the content and speech is
    // the instruction; on any failure we abort rather than touch the selection.
    private func produceFinalText(routed: PhaseBResult, mode: Mode?) async -> (FinalText, RewriteDetails?, String?) {
        if mode?.source == .selection {
            let (final, details) = await rewriteSelection(instruction: routed.transcript, mode: mode)
            return (final, details, nil)
        }
        let processed = processTranscript(routed.transcript, mode: mode)
        let (text, details) = await maybeRewrite(processed, mode: mode)
        // Only record the middle stage when the local pipeline actually changed the transcript;
        // otherwise Heard already equals it (ui_design.md §8).
        let transformed = processed != routed.transcript ? processed : nil
        return (.insert(text), details, transformed)
    }

    // Dictation rewrite: on failure we still insert the local (un-rewritten) transcript — you want
    // your words. Returns the text to insert and (when a rewrite ran) its details for history.
    private func maybeRewrite(_ text: String, mode: Mode?) async -> (String, RewriteDetails?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mode, let connection = connection(for: mode) else { return (text, nil) }
        let result = await tokenizeRewriteRestore(content: text, instruction: "", mode: mode, connection: connection)
        return (result.text, result.details)
    }

    // Edit-in-place: capture the selection, transform it per the spoken instruction. Any failure —
    // no selection, no connection, or a rewrite that fell back — aborts and leaves the selection
    // untouched. A destructive operation must never clobber the user's text on failure.
    private func rewriteSelection(instruction: String, mode: Mode?) async -> (FinalText, RewriteDetails?) {
        guard let mode else { return (.abort("No mode resolved", nil), nil) }
        // Capturing the selection fires a synthetic ⌘C, which the OS drops without Accessibility — so
        // the read silently fails and the abort below would misreport it as "no selection". Name the
        // real cause and offer the fix instead.
        guard accessibilityGranted() else {
            return (.abort("Accessibility is off — KeyScribe can't read the selected text.", .openAccessibilitySettings), nil)
        }
        guard let selection = await TextInserter.captureSelection(), !selection.isEmpty else {
            return (.abort("Select some text first", nil), nil)
        }
        guard let connection = connection(for: mode) else {
            return (.abort("Work on Selection needs an AI connection", nil), nil)
        }
        let result = await tokenizeRewriteRestore(
            content: selection, instruction: instruction, mode: mode, connection: connection)
        let final: FinalText = result.ok ? .insert(result.text) : .abort("Rewrite failed — selection unchanged", nil)
        return (final, result.details)
    }

    private func connection(for mode: Mode) -> Connection? {
        guard let rewrite = mode.aiRewrite, !rewrite.connection.isEmpty else { return nil }
        guard let connection = config.connections.connection(id: rewrite.connection) else {
            log.error("rewrite connection '\(rewrite.connection, privacy: .public)' not found in connections.toml")
            return nil
        }
        return connection
    }

    // Tokenize verbatim (if live edits) + redaction (if privacy) BEFORE the LLM so protected spans
    // never leave, then restore after. Returns (text, ok): ok=false means the model failed and we
    // restored the local content — dictation inserts it anyway; selection aborts on !ok.
    private func tokenizeRewriteRestore(
        content rawContent: String, instruction: String, mode: Mode, connection: Connection
    ) async -> (text: String, ok: Bool, details: RewriteDetails) {
        let tokenizer = Tokenizer()
        var content = rawContent
        if mode.commands.liveEdits { content = VerbatimTokenizer.apply(content, into: tokenizer) }
        if mode.commands.privacy { content = RedactionTokenizer.apply(content, into: tokenizer) }

        if mode.commands.privacy {
            log.debug("redaction: \(tokenizer.issuedTokens.count, privacy: .public) span(s) tokenized before cloud rewrite")
        }
        // Edit-in-place must leave the selection untouched on abandon, so the local-transcript
        // escape hatch is dictation-only — never offer to paste the captured selection back.
        if mode.source != .selection {
            pendingLocalTranscript = rawContent
            scheduleRewriteEscapeHatch(connection: connection, mode: mode)
        }
        hud?.render(.rewriting(
            connection: connection.name, redacted: mode.commands.privacy,
            contextCategories: mode.effectiveContextCategories, offerLocalTranscript: false))

        // Give the model output room at least as large as the input (prompt_design.md budget).
        var sized = connection
        sized.params.maxTokens = ContextBudget.maxTokens(
            forSelectionChars: content.count, floor: connection.params.maxTokens)

        // Mode prompt + shared fragments (appended in order).
        let modePrompt = ([mode.aiRewrite?.prompt ?? ""]
            + config.fragmentBodies(ids: mode.aiRewrite?.fragments ?? []))
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        // Dictionary terms present in the content → hinted as valid/not-misspelled (design.md §4.2).
        let effectiveDict = mergedDictionaryWords(for: mode)
        let validTerms = effectiveDict.filter { content.range(of: $0, options: .caseInsensitive) != nil }

        // Context opt-in (mode.effectiveContext — privacy mode forces it all off). App identity and
        // visible-window text are the only context channels; the browser URL is a local routing
        // key only (design.md §4.3/§4.4) and never goes to the LLM.
        let ctx = mode.effectiveContext
        let bundleId = ctx.app ? capturedSnapshot?.bundleId : nil
        let appName = bundleId.map { ContextProbe.appName(forBundleId: $0) ?? $0 }
        var contextCategories: [String] = []
        if ctx.app { contextCategories.append("app") }

        var precedingText: String?
        if ctx.precedingText {
            contextCategories.append("preceding text")
            precedingText = await ContextProbe.precedingText()
            Log.context.notice("preceding-text: \(precedingText?.count ?? 0, privacy: .public) chars")
        }

        var visibleWindowText: String?
        if ctx.visibleText {
            contextCategories.append("visible text")
            var captured: String?
            if let visibleBundleId = capturedSnapshot?.bundleId {
                captured = await ContextProbe.visibleText(forBundleId: visibleBundleId, maxChars: Self.visibleTextCap * 2)
            }
            let mandatoryChars = modePrompt.count + instruction.count + content.count
            switch ContextBudget.fit(mandatoryChars: mandatoryChars, visibleText: captured,
                                     budgetChars: Self.contextBudgetChars, visibleCap: Self.visibleTextCap) {
            case .ok(let fit):
                visibleWindowText = fit.visibleText
                Log.context.notice("visible-text: \(String(describing: fit.visibleDisposition), privacy: .public), \(fit.visibleText?.count ?? 0, privacy: .public) chars")
            case .refuse:
                Log.context.notice("visible-text dropped: mandatory content over budget")
            }
        }

        let inputs = PromptInputs(
            modePrompt: modePrompt, dictatedInstructions: instruction, content: content,
            tokens: tokenizer.issuedTokens, validTerms: validTerms, language: "English",
            modeSystemInstructions: "",
            appName: appName, bundleId: bundleId, fieldRole: nil,
            visibleWindowText: visibleWindowText, selectedText: nil, precedingText: precedingText)

        // The exact prompt stored in history (design.md §4.7) — tokens, not their originals.
        let assembled = PromptAssembler.assemble(inputs)
        let promptForHistory = "[system]\n\(assembled.system)\n\n[user]\n\(assembled.user)"

        let outcome = await RewriteService(client: llmClient).rewrite(
            localText: content, inputs: inputs, connection: sized, issuedTokens: tokenizer.issuedTokens)
        let fellBack: Bool
        let text: String
        switch outcome {
        case .rewritten(let out): text = tokenizer.restore(out); fellBack = false
        case .localFallback(let local): text = tokenizer.restore(local); fellBack = true
        }
        let details = RewriteDetails(
            connection: connection.name, model: connection.model, redaction: mode.commands.privacy,
            contextCategories: contextCategories, prompt: promptForHistory, fellBack: fellBack)
        return (text, !fellBack, details)
    }

    // Post-STT pipeline for the resolved mode: live edits (per-mode opt-in) then replacements
    // (mode-local merged with global per include_global). Redaction/verbatim tokenization is M6;
    // AI rewrite is M5.
    private func processTranscript(_ raw: String, mode: Mode?) -> String {
        compiledPipeline(for: mode).run(raw)
    }

    // The post-STT pipeline is pure config (mode flags + global/mode replacements & dictionary), so it
    // is compiled once per (mode, config generation) and reused. Stages precompute their own derived
    // data in init (prepared symbol/fuzzy tables, compiled replacement rules), so caching the pipeline
    // also keeps that work out of the per-dictation path.
    private func compiledPipeline(for mode: Mode?) -> Pipeline {
        refreshDerivedCachesIfNeeded()
        let key = mode?.id ?? Self.nilModeKey
        if let cached = pipelineCache[key] { return cached }
        let pipeline = Pipeline(buildStages(for: mode))
        pipelineCache[key] = pipeline
        return pipeline
    }

    private func buildStages(for mode: Mode?) -> [any PipelineStage] {
        var stages: [any PipelineStage] = []
        if mode?.commands.liveEdits ?? true { stages.append(LiveEditsStage()) }
        if mode?.commands.symbols ?? false { stages.append(SymbolsStage()) }
        let rules = VocabularyMerge.rules(
            global: config.replacements.toRules(),
            local: mode?.replacements.toRules() ?? [],
            includeGlobal: mode?.replacements.includeGlobal ?? true)
        stages.append(ReplacementsStage(rules: rules))
        if mode?.commands.numbers ?? false { stages.append(NumbersStage()) }
        if mode?.commands.fuzzyCorrection ?? false {
            stages.append(FuzzyStage(terms: mergedDictionaryWords(for: mode)))
        }
        return stages
    }

    func pasteLast() {
        guard let lastResult else { return }
        Task { await TextInserter.insertViaPaste(lastResult) }
    }

    func cancel() {
        guard machine.isBusy else { return }
        onRecordingChanged?(false)
        dictationTask?.cancel()
        dictationTask = nil
        _ = audio.stop()
        machine.cancel()
        effects.end(settings.duringDictation)
        hud?.render(.hidden)
        clearRewriteEscapeHatch()
    }

    func insertLocalTranscriptNow() {
        guard let transcript = pendingLocalTranscript, let heard = pendingHeardTranscript,
              machine.state == .transcribing else { return }
        dictationTask?.cancel()
        clearRewriteEscapeHatch()
        Task { await self.finishInsertion(transcript: transcript, heard: heard, rewrite: nil) }
    }

    private func scheduleRewriteEscapeHatch(connection: Connection, mode: Mode) {
        rewriteEscapeTask?.cancel()
        rewriteEscapeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.pendingLocalTranscript != nil,
                  self.machine.state == .transcribing else { return }
            self.hud?.render(.rewriting(
                connection: connection.name, redacted: mode.commands.privacy,
                contextCategories: mode.effectiveContextCategories, offerLocalTranscript: true))
        }
    }

    private func clearRewriteEscapeHatch() {
        rewriteEscapeTask?.cancel()
        rewriteEscapeTask = nil
        pendingLocalTranscript = nil
        pendingHeardTranscript = nil
    }

    private func finishError(_ message: String, action: HUDErrorAction? = nil) {
        machine.finish(.failed(message))
        effects.end(settings.duringDictation)
        hud?.render(.error(message: message, action: action))
        scheduleHide(after: action == nil ? 2 : 8)
    }

    private func scheduleHide(after seconds: Double = 2) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, !machine.isBusy else { return }
            hud?.render(.hidden)
        }
    }
}
