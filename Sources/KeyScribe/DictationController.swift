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
    private let submitKey: (Mode.Submit) async -> Void
    private let captureSelection: () async -> String?
    private let snapshot: @MainActor () -> TargetSnapshot
    private let micStatus: @MainActor () -> PermissionStatus
    private let accessibilityGranted: @MainActor () -> Bool
    private let llmClient: any LLMClient
    private let effects = DuringDictationEffects()
    // Serialises the STT call: a deadline only abandons a wedged transcribe, so this keeps a second
    // dictation from starting a concurrent transcribe on the same engine until the first truly settles.
    private let transcribeGate = SingleFlightDeadline()
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
    private var recordingLimitTask: Task<Void, Never>?
    // Phase-A mode resolution runs async only when a URL probe is needed; transcribeAndInsert awaits it
    // before reading the mode. captureStartTask defers capture+HUD past the start cue (Option A gating);
    // captureStarted gates the async mode re-render so it never shows the HUD before the mic is live.
    private var modeResolveTask: Task<Void, Never>?
    private var captureStartTask: Task<Void, Never>?
    // Engine bring-up now runs async (off the main thread, watchdogged) so a wedging device can never
    // freeze the app. captureStarted flips true only once the mic is actually live; pendingCommit holds a
    // release that arrived during bring-up (or the cue-gap) so it is honored the instant capture comes up
    // rather than transcribing an empty file.
    private(set) var captureBringUpTask: Task<Void, Never>?
    private var captureStarted = false
    private var pendingCommit = false

    // Safety bound on a runaway hold (stuck key, walked away): a recording grows an unbounded WAV plus
    // an in-memory PCM buffer at transcribe time (~3.7 MiB/min @16k). Drop it with a HUD notice rather
    // than spike memory. Far longer than any real hold-to-talk dictation.
    private static let maxRecordingSeconds: Double = 300

    // The frozen config snapshot for the in-flight dictation, captured at record-start. A config
    // reload mid-dictation produces a new ResolvedConfig in ConfigCache without mutating this one, so
    // a single dictation always observes one coherent config. All config-derived reads during a
    // dictation (modes, merged dictionary, compiled stages, connection, fragments) go through it; the
    // ResolvedConfig itself owns the cross-dictation memoization that used to live here.
    private var capturedPlan: ResolvedConfig?
    private var plan: ResolvedConfig { capturedPlan ?? config.resolved }

    // The STT engine frozen for the in-flight dictation, captured at record-start alongside the plan.
    // Reading `provider.active` afresh at transcribe/bias/evict time would let a mid-dictation engine
    // switch (AppDelegate.applySettings) transcribe the WAV with a different engine, or evict the model
    // out from under the active call. One capture, used everywhere for this dictation.
    private var capturedEngine: (any SpeechEngine)?
    private var activeEngine: any SpeechEngine { capturedEngine ?? provider.active }

    // An engine the user switched away from while a dictation was in flight. Evicting it immediately
    // would race the in-flight transcribe (the non-actor engines close their transcriber under it), so
    // we hold it until the dictation reaches a terminal state and evict it then.
    private var deferredEvictionEngine: (any SpeechEngine)?

    // Settings model delete/reinstall must evict an engine and then delete its files; doing either while
    // a dictation is using that engine is a use-after-free (engines tear their model down synchronously,
    // or across an actor await). These callers suspend here until the dictation reaches its terminal
    // state, drained in releaseCapturedPlan, so the eviction AND the caller's subsequent file delete run
    // while idle. See evictEngineForSettings.
    private var idleEvictionWaiters: [(engine: any SpeechEngine, resume: @Sendable () -> Void)] = []

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
        hud?.render(.recording(mode: activeMode?.name, level: quantized))
    }

    // Fired after every terminal insertion outcome. First run uses it to require one real successful
    // dictation before completing onboarding (ui_design.md §2).
    var onDictationCompleted: ((DictationOutcome) -> Void)?

    // Fired true when capture starts, false when it ends (commit or a start failure). The menu-bar
    // glyph tints red while true (ui_design.md §Dynamic status).
    var onRecordingChanged: ((Bool) -> Void)?

    // Fired whenever the dictation reaches a terminal state (idle). Lets the app apply work that must
    // wait for a quiet moment — e.g. rebinding hotkeys deferred during a hold so a held key isn't
    // stranded by a mid-dictation config reload.
    var onBecameIdle: (() -> Void)?

    var isBusy: Bool { machine.isBusy }
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
        submitKey: @escaping (Mode.Submit) async -> Void = TextInserter.submit,
        captureSelection: @escaping () async -> String? = TextInserter.captureSelection,
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
        self.submitKey = submitKey
        self.captureSelection = captureSelection
        self.snapshot = snapshot
        self.micStatus = micStatus
        self.accessibilityGranted = accessibilityGranted
        self.llmClient = llmClient
        levelCoalescer.onLevel = { [weak self] level in self?.renderLevel(level) }
        audio.setPreferredInputUID(settings.audio.inputDeviceUID)
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

    func updateSettings(_ settings: Settings) {
        self.settings = settings
        audio.setPreferredInputUID(settings.audio.inputDeviceUID)
    }

    // The active engine changed (Settings). Evict the one we switched away from — but never while a
    // dictation is mid-flight on it: the non-actor engines close their transcriber synchronously, so
    // evicting under a live transcribe is a use-after-close. Defer to the terminal state instead.
    func evictSwitchedAwayEngine(_ engine: any SpeechEngine) {
        if machine.isBusy {
            deferredEvictionEngine = engine
        } else {
            Task { await engine.evict() }
        }
    }

    // Evict an engine on behalf of a Settings delete/reinstall, then return so the caller can delete its
    // files. Only the in-flight dictation's own engine is unsafe to tear down — any other engine, or
    // when idle, evicts immediately. When it is the captured engine, suspend until the dictation is done
    // (drained in releaseCapturedPlan) so neither the evict nor the caller's file delete races the live
    // transcribe.
    func evictEngineForSettings(_ engine: any SpeechEngine) async {
        if !machine.isBusy || capturedEngine?.id != engine.id {
            await engine.evict()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            idleEvictionWaiters.append((engine, { continuation.resume() }))
        }
    }

    // Warm the active STT engine the instant a press begins, overlapping model load (CoreML/MLX
    // compile, ANE warmup) with the user's speech instead of paying it after key-release. Idempotent
    // — a no-op once loaded — and never blocks recording: failures surface later at transcribe time.
    private func warmActiveEngine() {
        let active = activeEngine
        Task { try? await active.loadIfNeeded() }
    }

    // Launch-time warm so the first dictation isn't a cold model load — independent of the eviction
    // profile, which only governs post-dictation residency (readiness ≠ residency). Only when the model
    // is already on disk (or system-managed, e.g. Apple): warming an uninstalled engine would DOWNLOAD
    // it at launch, racing the first-run wizard's own download. Fresh installs stay lazy until installed.
    func preloadActiveEngineIfNeeded() {
        let id = activeEngine.id
        let systemManaged = SpeechModelCatalog.entry(for: id)?.systemManaged ?? false
        guard systemManaged || ModelInstallStore.installedIds().contains(id) else { return }
        warmActiveEngine()
    }

    // Realize the audio input unit ahead of the first press so the first dictation's capture starts
    // instantly (the one-time HAL realization is otherwise paid on the hot path). Only when the mic is
    // granted — we never touch the input subsystem unauthorized, and no capture stream is opened.
    func prewarmCapture() {
        guard micStatus() == .granted else { return }
        audio.prewarm()
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
        capturedPlan = config.resolved
        capturedEngine = provider.active
        captureStarted = false
        pendingCommit = false
        activeMode = nil
        eligibleModes = []
        routingContext = RoutingContext()

        // Resolve the Phase-A mode. The only slow step is the browser-URL probe (a synchronous AppleScript
        // round trip) for URL-routed modes; with no URL-constrained mode we resolve inline so the mode is
        // known before capture. When a probe IS needed we resolve off the main thread so it never blocks
        // the cue, capture, or HUD — the mode is only needed at commit (transcribeAndInsert awaits this),
        // and the HUD fills its mode in once the probe returns.
        if ModeResolver.requiresURLContext(plan.modes) {
            modeResolveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.resolveModeProbing(triggerKey: triggerKey)
                if self.machine.state == .recording, self.captureStarted {
                    self.hud?.render(.recording(mode: self.activeMode?.name, level: max(0, self.lastRenderedLevel)))
                }
            }
        } else {
            modeResolveTask = nil
            applyResolvedMode(triggerKey: triggerKey, url: nil)
        }

        warmActiveEngine()

        // Option A cue gating: the start cue plays now and CAPTURE comes up only after it finishes, so the
        // cue never lands in the recording. The HUD, however, shows instantly — the truthful `.ready`
        // state (not `.recording`) during the gap, so the window appears with no perceptible delay without
        // claiming to listen before the mic is live; beginCapture flips it to `.recording` when the mic
        // goes live. No cue (sounds off / unbundled) → zero delay → capture and HUD fire together.
        let cueDelay = effects.begin(settings.duringDictation)
        if cueDelay > 0 {
            hud?.render(.ready(mode: currentModeName))
            captureStartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(cueDelay))
                guard let self, !Task.isCancelled, self.machine.state == .recording else { return }
                self.beginCapture()
            }
        } else {
            beginCapture()
        }
    }

    private func beginCapture() {
        lastRenderedLevel = 0
        let sampleRate = activeEngine.captureSampleRate
        captureBringUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.audio.start(sampleRate: sampleRate) { [weak self] level in
                    self?.levelCoalescer.submit(level)
                }
            } catch {
                // Bring-up failed or timed out (e.g. a wedged Bluetooth device). A cancel/commit may have
                // already moved us on — only report the mic error if we are still trying to record.
                if Task.isCancelled || self.machine.state != .recording { return }
                self.log.error("bring-up failed: \(String(describing: error), privacy: .public)")
                if case AudioCaptureError.formatUnavailable = error {
                    // No usable input stream, not a permission issue — so no settings action.
                    self.finishError("No microphone is available")
                } else {
                    self.finishError("Could not start the microphone", action: .openMicrophoneSettings)
                }
                return
            }
            // Released or cancelled while the mic was coming up: nothing to record, so tear the capture
            // back down and bail (a pendingCommit is dropped — there is no audio to transcribe).
            guard !Task.isCancelled, self.machine.state == .recording else {
                if let url = self.audio.stop() { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.captureStarted = true
            self.onRecordingChanged?(true)
            self.startRecordingLimit()
            self.hud?.render(.recording(mode: self.activeMode?.name, level: 0))
            if self.pendingCommit {
                self.pendingCommit = false
                self.handleCommit()
            }
        }
    }

    private func startRecordingLimit() {
        recordingLimitTask?.cancel()
        recordingLimitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxRecordingSeconds))
            guard let self, !Task.isCancelled, self.machine.state == .recording else { return }
            self.abortRecordingOverLimit()
        }
    }

    private func abortRecordingOverLimit() {
        onRecordingChanged?(false)
        if let url = audio.stop() { try? FileManager.default.removeItem(at: url) }
        machine.cancel()
        effects.end(settings.duringDictation, cue: .cancel)
        hud?.render(.error(message: "Recording stopped after \(Int(Self.maxRecordingSeconds / 60)) min", action: nil))
        scheduleHide(after: 4)
        clearRewriteEscapeHatch()
        releaseCapturedPlan()
    }

    // Release the frozen config once a dictation reaches a terminal state, so an idle app doesn't pin a
    // stale ResolvedConfig (fragments + compiled stages) after a config reload until the next recording.
    // `plan` falls back to the live `config.resolved` while nil, so clearing between dictations is safe.
    private func releaseCapturedPlan() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        modeResolveTask?.cancel()
        modeResolveTask = nil
        captureStartTask?.cancel()
        captureStartTask = nil
        captureBringUpTask?.cancel()
        captureBringUpTask = nil
        captureStarted = false
        pendingCommit = false
        capturedPlan = nil
        capturedEngine = nil
        // An engine the user switched away from mid-dictation was held back from eviction to avoid
        // racing the in-flight call; now that we're idle it is safe to free.
        if let deferred = deferredEvictionEngine {
            deferredEvictionEngine = nil
            Task { await deferred.evict() }
        }
        if !idleEvictionWaiters.isEmpty {
            let waiters = idleEvictionWaiters
            idleEvictionWaiters.removeAll()
            Task {
                for waiter in waiters {
                    await waiter.engine.evict()
                    waiter.resume()
                }
            }
        }
        onBecameIdle?()
    }

    func handleCommit() {
        guard machine.state == .recording else { return }
        // The mic may still be coming up (cue-gap, or a slow async bring-up). Defer the release until
        // capture is live so beginCapture honors it the instant the engine starts — transcribing now
        // would drain an empty file.
        guard captureStarted else { pendingCommit = true; return }
        recordingLimitTask?.cancel()
        onRecordingChanged?(false)
        machine.beginTranscribing()
        // Flip the HUD to transcribing now so the tail-drain (commit-on-release flush, ~one buffer) is
        // invisible; finishDraining keeps the engine running just long enough to capture the final word.
        hud?.render(.transcribing(mode: currentModeName))
        let drainStart = DispatchTime.now()
        dictationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = await self.audio.finishDraining() else {
                self.machine.cancel()
                self.effects.end(self.settings.duringDictation, cue: .cancel)
                self.hud?.render(.hidden)
                self.releaseCapturedPlan()
                return
            }
            let drainMs = Double(DispatchTime.now().uptimeNanoseconds - drainStart.uptimeNanoseconds) / 1e6
            if let f = try? AVAudioFile(forReading: url) {
                self.log.debug("wav \(f.length) frames @ \(f.fileFormat.sampleRate, privacy: .public)Hz ch=\(f.fileFormat.channelCount, privacy: .public) drain=\(drainMs, privacy: .public)ms")
            } else {
                self.log.error("wav unreadable at \(url.path, privacy: .public)")
            }
            await self.transcribeAndInsert(url: url)
        }
    }

    // Phase A (design.md §4.3): resolve the mode from app/URL context before recording. A non-nil
    // triggerKey (from a mode's own HotkeyMonitor binding) forces that mode, overriding context. The
    // browser URL is fetched only when a URL-constrained mode exists (resolveModeProbing); otherwise
    // url is nil here.
    private func applyResolvedMode(triggerKey: String?, url: String?) {
        let modes = plan.modes
        let context = RoutingContext(bundleId: capturedSnapshot?.bundleId, url: url)
        routingContext = context
        eligibleModes = ModeResolver.eligibleModes(modes, context: context)
        let automaticMode = ModeResolver.resolvePhaseA(
            modes: modes, defaultModeId: settings.defaultModeId, context: context, triggerKey: triggerKey)
        let override = nextModeOverrideID.flatMap { id in modes.first { $0.id == id && $0.enabled } }
        nextModeOverrideID = nil
        activeMode = override ?? automaticMode
    }

    private func resolveModeProbing(triggerKey: String?) async {
        var url: String?
        if let bundleId = capturedSnapshot?.bundleId {
            url = await ContextProbe.browserURLAsync(forBundleId: bundleId)
        }
        applyResolvedMode(triggerKey: triggerKey, url: url)
    }

    // Dictionary terms fed to the engine's recognition bias before STT. Only the Phase-A mode's
    // dictionary (⊕ global) is known here — a Phase-B voice route resolves post-STT and so cannot
    // bias recognition (design.md §4.3). Normalized once here (VocabularyMerge already dedups in
    // stable order; this trims and drops blanks) so engines consume clean terms. Engines without
    // bias ignore these.
    private func recognitionBiasTerms() -> [String] {
        guard activeEngine.supportsRecognitionBias else { return [] }
        return plan.recognitionBiasTerms(for: activeMode)
    }

    // Bound the STT call so a wedged CoreML/MLX transcribe can't leave the HUD spinning forever.
    // Batch dictation can't salvage a partial, so this is robustness, not speed — the cap scales with
    // the recording length (20× real-time, ≥30s floor), generous enough to never trip on a legitimately
    // long or slow transcription while still abandoning a true hang. The gate runs the engine as an
    // unstructured task, so even an engine that ignores cancellation is abandoned at the deadline
    // (a structured task group would wait for it). A late result resolves a no-op and is discarded.
    // Because an abandoned transcribe may still be running, the gate refuses a second concurrent call
    // (throws `Busy`) until the wedged one truly settles, so two transcribes never run at once.
    private func transcribeBounded(url: URL, biasTerms: [String], engine: any SpeechEngine) async throws -> String {
        let audioSeconds = (try? AVAudioFile(forReading: url))
            .map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        let timeout = max(30, audioSeconds * 20)
        return try await transcribeGate.run(seconds: timeout) {
            try await engine.transcribe(wavURL: url, biasTerms: biasTerms)
        }
    }

    private func transcribeAndInsert(url: URL) async {
        await modeResolveTask?.value
        let engine = activeEngine
        let raw: String
        do {
            raw = try await transcribeBounded(url: url, biasTerms: recognitionBiasTerms(), engine: engine)
        } catch is SingleFlightDeadline.Busy {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { return }
            log.error("transcribe rejected — previous transcription still running (\(engine.id, privacy: .public))")
            finishError("Still finishing the previous dictation")
            return
        } catch is DeadlineExceeded {
            try? FileManager.default.removeItem(at: url)
            // A user cancel cancels this task too; cancel() already handled the terminal state, so a
            // late deadline/error must not stomp the next dictation's HUD/effects/state.
            if Task.isCancelled { return }
            log.error("transcribe timed out (\(engine.id, privacy: .public))")
            finishError("Transcription timed out")
            return
        } catch {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { return }
            log.error("transcribe failed (\(engine.id, privacy: .public)): \(error, privacy: .public)")
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
            let engineUsed = activeEngine
            log.info("aborted: \(message, privacy: .public)")
            finishError(message, action: action)
            clearRewriteEscapeHatch()
            applyEvictionAfterDictation(engine: engineUsed)

        case .insert(let transcript):
            await finishInsertion(transcript: transcript, heard: raw, transformed: transformed, rewrite: rewrite)
        }
    }

    private func finishInsertion(
        transcript: String, heard: String, transformed: String? = nil, rewrite: RewriteDetails?
    ) async {
        clearRewriteEscapeHatch()
        machine.beginInserting()
        hud?.relinquishKeyFocus()
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
            // Trailing text rides inside the atomic insert (still one ⌘Z). The submit keystroke lands
            // OUTSIDE that atom and only on a verified insert — never .copied, where a synthesized Return
            // would hit whatever app is now focused instead of the target the text reached.
            let trailing = activeMode?.trailing ?? .none
            await insert(decision, activeMode?.insertion ?? .paste, transcript + trailing.suffix)
            if outcome == .inserted, let submit = activeMode?.submit, submit != .none {
                await submitKey(submit)
            }
            machine.finish(outcome)
        case .failed:
            machine.finish(outcome)
        }
        recordHistory(heard: heard, transformed: transformed, result: transcript, insertion: outcome, rewrite: rewrite)
        let endCue: DuringDictationEffects.EndCue
        switch outcome {
        case .inserted, .copied: endCue = .success
        case .noSpeech: endCue = .cancel
        case .failed: endCue = .error
        }
        effects.end(settings.duringDictation, cue: endCue)
        hud?.render(rewrite?.fellBack == true
            ? .localFallback(outcome: outcome, mode: currentModeName)
            : .complete(outcome: outcome, mode: currentModeName))
        scheduleHide()
        applyEvictionAfterDictation(engine: activeEngine)
        releaseCapturedPlan()
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

    // Evicts the engine the dictation actually used (the captured one), not whatever is active now —
    // a mid-dictation switch leaves provider.active pointing at a different, unloaded engine.
    private func applyEvictionAfterDictation(engine: any SpeechEngine) {
        lastUsedAt = ProcessInfo.processInfo.systemUptime
        let idle = settings.stt.evictionIdleSeconds.map(Double.init)
        switch EvictionPolicy.afterDictation(mode: settings.stt.eviction, idleSeconds: idle) {
        case .keepLoaded: break
        case .evictNow:
            Task { await engine.evict() }
        case .scheduleIdleCheck(let after): scheduleIdleEviction(after: after, engine: engine)
        }
    }

    private func scheduleIdleEviction(after: Double, engine active: any SpeechEngine) {
        idleEvictionTask?.cancel()
        let mode = settings.stt.eviction
        let idle = settings.stt.evictionIdleSeconds.map(Double.init)
        let usedAt = lastUsedAt
        idleEvictionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard let self, !Task.isCancelled, !self.machine.isBusy else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch EvictionPolicy.onIdleCheck(mode: mode, lastUsedAt: usedAt, now: now, idleSeconds: idle) {
            case .evictNow: await active.evict()
            case .scheduleIdleCheck(let again): self.scheduleIdleEviction(after: again, engine: active)
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
        return await produceDictationText(transcript: routed.transcript, mode: mode)
    }

    // Dictation path. The full pipeline runs FORWARD (verbatim tokenize → text stages → redaction
    // tokenize), the optional LLM runs on the tokenized text, then the pipeline runs in REVERSE to
    // restore (design.md §4.2.1). Verbatim sorts before the text stages, so a verbatim span is opaque
    // to live edits / replacements / numbers / fuzzy and to the LLM — protected from everything
    // except STT. On no/failed rewrite we still insert the locally-processed text — you want your words.
    private func produceDictationText(transcript: String, mode: Mode?) async -> (FinalText, RewriteDetails?, String?) {
        let resolved = mode.flatMap { m in connection(for: m).map { (mode: m, connection: $0) } }
        let pipeline = dictationPipeline(for: mode, willRewrite: resolved != nil)

        var ctx = PipelineContext(text: transcript)
        pipeline.forward(&ctx)
        let tokenized = ctx.text

        // Locally-processed text (tokens restored, no LLM): the history "middle stage", and what we
        // insert when no rewrite runs or it falls back.
        var localCtx = PipelineContext(text: tokenized)
        pipeline.reverse(&localCtx)
        let localProcessed = localCtx.text
        // Only record the middle stage when local processing actually changed the transcript;
        // otherwise Heard already equals it (ui_design.md §8).
        let transformed = localProcessed != transcript ? localProcessed : nil

        guard let resolved,
              !tokenized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (.insert(localProcessed), nil, transformed)
        }
        let result = await rewriteTokenized(
            pipeline: pipeline, tokenized: tokenized, localProcessed: localProcessed,
            instruction: "", mode: resolved.mode, connection: resolved.connection)
        return (.insert(result.text), result.details, transformed)
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
        // The selection-capture ⌘C must reach the target, so drop key focus held for ESC-cancel; the
        // subsequent .rewriting render re-takes it so ESC still cancels the rewrite.
        hud?.relinquishKeyFocus()
        guard let selection = await captureSelection(), !selection.isEmpty else {
            return (.abort("Select some text first", nil), nil)
        }
        guard let connection = connection(for: mode) else {
            return (.abort("Work on Selection needs an AI connection", nil), nil)
        }
        // The selection IS the content (no post-STT text stages); only the tokenization commands run.
        let pipeline = selectionPipeline(for: mode)
        var ctx = PipelineContext(text: selection)
        pipeline.forward(&ctx)
        let result = await rewriteTokenized(
            pipeline: pipeline, tokenized: ctx.text, localProcessed: selection,
            instruction: instruction, mode: mode, connection: connection)
        let final: FinalText = result.ok ? .insert(result.text) : .abort("Rewrite failed — selection unchanged", nil)
        return (final, result.details)
    }

    private func connection(for mode: Mode) -> Connection? {
        guard let rewrite = mode.aiRewrite, !rewrite.connection.isEmpty else { return nil }
        guard let connection = plan.connection(id: rewrite.connection) else {
            log.error("rewrite connection '\(rewrite.connection, privacy: .public)' not found in connections.toml")
            return nil
        }
        return connection
    }

    // The optional LLM rewrite over an already-FORWARD-passed pipeline (design.md §4.2.1): the
    // content is tokenized, the model runs on it, then `pipeline.reverse` restores every nonce (LIFO,
    // structurally). Returns (text, ok): ok=false means the model failed and the locally-processed
    // text was restored — dictation inserts it anyway; selection aborts on !ok.
    private func rewriteTokenized(
        pipeline: Pipeline, tokenized content: String, localProcessed: String,
        instruction: String, mode: Mode, connection: Connection
    ) async -> (text: String, ok: Bool, details: RewriteDetails) {
        let issuedTokens = pipeline.issuedTokens
        if mode.commands.privacy {
            log.debug("redaction: \(issuedTokens.count, privacy: .public) span(s) tokenized before cloud rewrite")
        }
        // Edit-in-place must leave the selection untouched on abandon, so the local-transcript
        // escape hatch is dictation-only — never offer to paste the captured selection back.
        if mode.source != .selection {
            pendingLocalTranscript = localProcessed
            scheduleRewriteEscapeHatch(connection: connection, mode: mode)
        }
        hud?.render(.rewriting(
            connection: connection.name, redacted: mode.commands.privacy,
            contextCategories: mode.effectiveContextCategories, offerLocalTranscript: false))

        // Mode prompt + fragments + valid-term hints + opted-in context, fitted to the budget, plus
        // the size-bumped connection — the change-prone assembly lives in its own builder.
        let request = await RewriteRequestBuilder(
            mode: mode, content: content, instruction: instruction, issuedTokens: issuedTokens,
            capturedBundleId: capturedSnapshot?.bundleId, plan: plan, connection: connection,
            visibleTextCap: Self.visibleTextCap, contextBudgetChars: Self.contextBudgetChars).build()

        let outcome = await RewriteService(client: llmClient).rewrite(
            localText: content, inputs: request.inputs, connection: request.sized, issuedTokens: issuedTokens)
        var restoreCtx = PipelineContext(text: content)
        let fellBack: Bool
        switch outcome {
        case .rewritten(let out): restoreCtx.text = out; fellBack = false
        case .localFallback(let local): restoreCtx.text = local; fellBack = true
        }
        pipeline.reverse(&restoreCtx)
        let text = restoreCtx.text
        let details = RewriteDetails(
            connection: connection.name, model: connection.model, redaction: mode.commands.privacy,
            contextCategories: request.contextCategories, prompt: request.promptForHistory, fellBack: fellBack)
        return (text, !fellBack, details)
    }

    // Full dictation pipeline (design.md §4.2.1): the frozen plan's compiled text stages (live edits →
    // replacements → numbers → fuzzy), then verbatim (if live edits) sorts BEFORE them so its span is
    // opaque to them, and redaction (if privacy AND a cloud rewrite will run) sorts AFTER them,
    // tokenizing the fully-transformed text just before the LLM. Pipeline sorts by position/order, so
    // append order does not matter. Verbatim/redaction hold per-dictation tokenizers and are built
    // fresh here; the text stages are pure config and reused from the plan.
    private func dictationPipeline(for mode: Mode?, willRewrite: Bool) -> Pipeline {
        var stages = plan.postSTTTextStages(for: mode)
        if mode?.commands.liveEdits ?? true { stages.append(TokenizingStage.verbatim()) }
        if (mode?.commands.privacy ?? false) && willRewrite { stages.append(TokenizingStage.redaction()) }
        return Pipeline(stages)
    }

    // Edit-in-place pipeline: the selection IS the content, so no post-STT text stages run — only the
    // tokenization commands (verbatim if live edits, redaction if privacy; a selection rewrite always
    // calls the LLM).
    private func selectionPipeline(for mode: Mode) -> Pipeline {
        var stages: [any PipelineStage] = []
        if mode.commands.liveEdits { stages.append(TokenizingStage.verbatim()) }
        if mode.commands.privacy { stages.append(TokenizingStage.redaction()) }
        return Pipeline(stages)
    }

    func pasteLast() {
        guard let lastResult else { return }
        hud?.relinquishKeyFocus()
        Task { await TextInserter.insertViaPaste(lastResult) }
    }

    // ESC-cancellable only while recording or transcribing/rewriting — never mid-insert, where the
    // text is already landing and cancel() would race finishInsertion (conflicting state + double cue).
    var isCancellable: Bool {
        machine.state == .recording || machine.state == .transcribing
    }

    func cancel() {
        guard machine.isBusy else { return }
        onRecordingChanged?(false)
        dictationTask?.cancel()
        dictationTask = nil
        // Mid-recording stop() hands back the live capture file; nothing downstream will run, so delete
        // it here (transcribeAndInsert owns cleanup once a commit has handed the URL off, when stop()
        // returns nil). Otherwise every press-then-cancel leaks a temp WAV until the OS reclaims it.
        if let url = audio.stop() { try? FileManager.default.removeItem(at: url) }
        machine.cancel()
        effects.end(settings.duringDictation, cue: .cancel)
        hud?.render(.hidden)
        clearRewriteEscapeHatch()
        releaseCapturedPlan()
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
        effects.end(settings.duringDictation, cue: .error)
        hud?.render(.error(message: message, action: action))
        scheduleHide(after: action == nil ? 2 : 8)
        releaseCapturedPlan()
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
