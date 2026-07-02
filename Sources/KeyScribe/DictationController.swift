import AVFoundation
import Foundation
import KeyScribeKit
import os

@MainActor
final class DictationController {
    static let fallbackModeName = "Plain Dictation"
    private let log = Logger(subsystem: "com.keyscribe.app", category: "dictation")

    private(set) var settings: Settings
    private let provider: SpeechEngineProvider
    private let config: ConfigCache
    private let history: HistoryStore?
    // History writes are append-only file I/O — serialized off the main actor so the disk write never
    // sits on the dictation's completion path. Serial so concurrent dictations can't interleave a write
    // or reorder appends within a day file.
    private let historyWriteQueue = DispatchQueue(label: "com.keyscribe.history.write", qos: .utility)
    private let audio: AudioCapturing
    private let insert: (InsertionDecision, Mode.Insertion, Mode.ClipboardModifier, String) async -> Bool
    private let submitKey: (Mode.Submit) async -> Void
    private let captureSelection: (Mode.ClipboardModifier) async -> String?
    private let clipboard: @MainActor () -> String?
    private let snapshot: @MainActor () -> TargetSnapshot
    private let micStatus: @MainActor () -> PermissionStatus
    private let accessibilityGranted: @MainActor () -> Bool
    private let activeEngineUsable: @MainActor (any SpeechEngine) -> Bool
    private let llmClient: any LLMClient
    // Durable sink for a model-load failure that survives both automatic retries (engine id + error).
    // Injected so tests assert the failure was recorded without touching the real diagnostics file.
    private let recordModelLoadFailure: @MainActor (_ engineId: String, _ timedOut: Bool, _ error: String) -> Void
    private let effects: DuringDictationEffects
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
    // Re-realizes the audio input binding while idle so the first dictation after a long idle (or a system
    // sleep) does not pay a stale unit-realization on the hot path. See scheduleCaptureRefresh.
    private var captureRefreshTask: Task<Void, Never>?
    private static let captureRefreshIdleSeconds: Double = 240
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private(set) var dictationTask: Task<Void, Never>?
    private var lastUsedAt: Double = 0
    private(set) var lastResult: String?
    // One structured, in-memory diagnostics record for the most recent dictation, kept UNCONDITIONALLY
    // (never gated on history). `building` accumulates stage timings + boundary fingerprints as the
    // in-flight dictation progresses; finalizeRecord publishes it to `lastRecord`. Privacy: only token
    // COUNTS and one-way fingerprints enter the record — never the token→original map (design.md §4.2).
    private(set) var lastRecord: DictationRecord?
    private var building = DictationRecord(modeName: DictationController.fallbackModeName)
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
    // freeze the app. captureStarted flips true only once the mic is actually live.
    private(set) var captureBringUpTask: Task<Void, Never>?
    private var captureStarted = false
    private var captureBringUpCancelling = false

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
    private var capturedDictionaryRecovery: Bool?

    // The in-flight (or completed) model load for `warmEngineId`, so the press-time warm and the
    // commit-time wait share ONE load instead of racing two concurrent compiles of a multi-hundred-MB
    // model. Invalidated whenever that engine is evicted (its model goes back to nil).
    private var warmTask: Task<Void, Error>?
    private var warmEngineId: String?
    // Backstop for a wedged model load. Real cold loads are slow (a 632 MB CoreML model measured ~140 s
    // to load even from a compiled cache), so this only fires on a genuine hang — far above any real
    // load — and, because loading runs OUTSIDE the transcribe single-flight gate, a load that trips it
    // surfaces an error without wedging the next dictation.
    private static let modelLoadDeadlineSeconds: Double = 300

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

    var isBusy: Bool { machine.isBusy || captureBringUpCancelling }
    var hasResult: Bool { lastResult != nil }
    var nextModeOverrideName: String? {
        nextModeOverrideID.flatMap { id in config.modes.first { $0.id == id }?.name }
    }
    private var currentModeName: String { activeMode?.name ?? Self.fallbackModeName }

    init(
        settings: Settings, provider: SpeechEngineProvider,
        config: ConfigCache, history: HistoryStore?, hud: HUDPresenting?,
        audio: AudioCapturing? = nil,
        insert: @escaping (InsertionDecision, Mode.Insertion, Mode.ClipboardModifier, String) async -> Bool = TextInserter.perform,
        submitKey: @escaping (Mode.Submit) async -> Void = TextInserter.submit,
        captureSelection: @escaping (Mode.ClipboardModifier) async -> String? = TextInserter.captureSelection,
        clipboard: @escaping @MainActor () -> String? = TextInserter.currentClipboardText,
        snapshot: @escaping @MainActor () -> TargetSnapshot = ContextProbe.snapshot,
        micStatus: @escaping @MainActor () -> PermissionStatus = { Permissions.microphoneStatus() },
        accessibilityGranted: @escaping @MainActor () -> Bool = { Permissions.accessibilityStatus() == .granted },
        activeEngineUsable: @escaping @MainActor (any SpeechEngine) -> Bool = { engine in
            guard let entry = SpeechModelCatalog.entry(for: engine.id) else { return true }
            return entry.systemManaged || ModelInstallStore.installedIds().contains(engine.id)
        },
        llmClient: any LLMClient = HTTPLLMClient(),
        recordModelLoadFailure: @escaping @MainActor (String, Bool, String) -> Void = {
            ModelLoadDiagnosticsWriter.record(engineId: $0, timedOut: $1, error: $2)
        }
    ) {
        self.settings = settings
        self.provider = provider
        self.config = config
        self.history = history
        self.hud = hud
        self.audio = audio ?? AudioCapture()
        self.effects = DuringDictationEffects()
        self.insert = insert
        self.submitKey = submitKey
        self.captureSelection = captureSelection
        self.clipboard = clipboard
        self.snapshot = snapshot
        self.micStatus = micStatus
        self.accessibilityGranted = accessibilityGranted
        self.activeEngineUsable = activeEngineUsable
        self.llmClient = llmClient
        self.recordModelLoadFailure = recordModelLoadFailure
        levelCoalescer.onLevel = { [weak self] level in self?.renderLevel(level) }
        self.audio.setPreferredInputUID(settings.audio.inputDeviceUID)
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
                guard let self, !self.isBusy else { return }
                let active = self.provider.active
                self.log.notice("memory pressure (critical): evicting \(active.id, privacy: .public)")
                self.invalidateWarm(active.id)
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

    // The active engine changed (Settings). Evict the one we switched away from. SerializedEngine.evict
    // waits for any in-flight load and the transcribe lock to settle before tearing the SDK handle down,
    // so evicting mid-dictation is safe now — no controller-side deferral needed.
    func evictSwitchedAwayEngine(_ engine: any SpeechEngine) {
        invalidateWarm(engine.id)
        Task { await engine.evict() }
    }

    // Evict an engine on behalf of a Settings delete/reinstall, then return so the caller can delete its
    // files. SerializedEngine.evict awaits load + transcribe settlement, so the await completes only once
    // the engine is truly idle — neither the evict nor the caller's subsequent file delete can race a
    // live transcribe.
    func evictEngineForSettings(_ engine: any SpeechEngine) async {
        invalidateWarm(engine.id)
        await engine.evict()
    }

    // A Settings self-test transcribes on the SAME non-actor engine instance a live dictation uses, so it
    // runs through the dictation transcribe gate — two transcribes at once would race a non-Sendable SDK
    // object. Dictation always wins: the test is skipped while a dictation is in flight, and a residual
    // mid-test collision surfaces as a skip (nil), never a failed model.
    func selfTestForSettings(_ engine: any SpeechEngine) async -> Bool? {
        guard !isBusy else { return nil }
        let gate = transcribeGate
        return await ModelSelfTestRunner.verify(engine) { url, biasTerms in
            do {
                return try await gate.run(seconds: Self.selfTestTimeoutSeconds) {
                    try await engine.transcribe(wavURL: url, biasTerms: biasTerms)
                }
            } catch is SingleFlightDeadline.Busy {
                throw ModelSelfTestRunner.Skipped()
            }
        }
    }
    private static let selfTestTimeoutSeconds: Double = 30

    // Warm the active STT engine the instant a press begins, overlapping model load (CoreML/MLX
    // compile, ANE warmup) with the user's speech instead of paying it after key-release. Idempotent
    // — a no-op once loaded — and never blocks recording: failures surface later at transcribe time.
    private func warmActiveEngine() {
        _ = warm(activeEngine)
    }

    // Start (or reuse) the single load for `engine`. Idempotent per engine: a launch preload, the
    // press-time warm, and the commit-time wait all resolve to the same Task, so the model compiles
    // once. Cleared by `invalidateWarm` on eviction so the next press reloads.
    @discardableResult
    private func warm(_ engine: any SpeechEngine) -> Task<Void, Error> {
        if warmEngineId == engine.id, let task = warmTask { return task }
        let clip = Self.warmupClipURL
        // Warm with the user's actual global dictionary, not []. For bias-capable engines this also compiles
        // the bias path — notably Parakeet, whose CTC-WS bias model is NOT loaded by loadIfNeeded() and would
        // otherwise compile mid-dictation on the first biased transcribe. Empty dictionary ⇒ [] ⇒ Parakeet
        // keeps skipping the CTC load entirely, preserving that optimization for users who never bias.
        let biasTerms = plan.recognitionBiasTerms(for: nil)
        let task = Task {
            try await engine.loadIfNeeded()
            // Warm the inference graph on a throwaway clip so the user's first real dictation isn't the one
            // that pays the one-time first-predict compile (MLX kernel JIT / CoreML graph specialization) —
            // Qwen's first transcribe measured ~3 s cold vs ~50 ms warm. Started at launch/press, it overlaps
            // the user's speech, so the cost is usually invisible. Best-effort: a warmup failure (e.g. the
            // clip is absent under `swift run`) must never fail the load. The commit-time await of this same
            // task serializes warmup before the real transcribe, so the non-actor engines are never reentered.
            if let clip { _ = try? await engine.transcribe(wavURL: clip, biasTerms: biasTerms) }
        }
        warmEngineId = engine.id
        warmTask = task
        return task
    }

    // Throwaway clip used to warm the inference graph (the bundled self-test recording). Absent under
    // `swift run`/tests, where warmup is simply skipped.
    private static let warmupClipURL = Bundle.main.url(forResource: "model-selftest", withExtension: "wav")

    private func invalidateWarm(_ engineId: String) {
        guard warmEngineId == engineId else { return }
        warmTask = nil
        warmEngineId = nil
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
        scheduleCaptureRefresh()
    }

    // Wake-from-sleep / long-idle staleness recovery: a resident engine's cached CoreAudio binding rots
    // while the app sits idle or the system sleeps, with no device-topology change to trip the adapter's
    // own listeners. Proactively rebuild + re-prewarm the binding WHILE IDLE so the next dictation's hot
    // path finds a fresh one instead of realizing a rotted unit. Never touches an in-flight dictation.
    func refreshCaptureBinding() {
        guard micStatus() == .granted, !isBusy else { return }
        audio.refreshBinding()
        scheduleCaptureRefresh()
    }

    // Single-shot: refresh the binding once it has sat idle for captureRefreshIdleSeconds, then STOP —
    // binding rot is rare, so a perpetual every-N-min rebuild would be churn for a rare event. Re-armed on
    // every return-to-idle (releaseCapturedPlan) and on wake, and cancelled at handleStart, so active use
    // and sleep/wake each re-arm it; a long unbroken idle past one refresh falls back to the non-destructive
    // bring-up watchdog (which adopts the slightly-slow first dictation) rather than more idle rebuilds.
    private func scheduleCaptureRefresh() {
        captureRefreshTask?.cancel()
        captureRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.captureRefreshIdleSeconds))
            guard let self, !Task.isCancelled, !self.isBusy, self.micStatus() == .granted else { return }
            self.audio.refreshBinding()
        }
    }

    func setNextModeOverride(id: String?) {
        nextModeOverrideID = id.flatMap { candidate in
            config.modes.first { $0.id == candidate && $0.enabled }?.id
        }
    }

    // ui_design.md §6: a one-shot mode picked from the menu is acknowledged in the HUD before the
    // next dictation. Only when idle — never stomp an in-flight dictation's state.
    func acknowledgeNextMode() {
        guard !isBusy, let name = nextModeOverrideName else { return }
        hud?.render(.ready(mode: name))
        scheduleHide()
    }

    func handleStart(triggerKey: String? = nil) {
        guard !captureBringUpCancelling else { return }
        guard machine.beginRecording() else { return }
        hideTask?.cancel()
        idleEvictionTask?.cancel()
        captureRefreshTask?.cancel()
        building = DictationRecord(modeName: currentModeName)
        // A denied mic does NOT make AVAudioEngine throw — it starts and captures silence, which would
        // surface as a misleading "No speech detected". Catch the real cause up front and point the user
        // at the fix instead of recording nothing.
        if micStatus() == .denied {
            finishError("Microphone access is off", action: .openMicrophoneSettings)
            return
        }
        let engine = provider.active
        guard activeEngineUsable(engine) else {
            finishError("The selected speech model is not installed", action: nil)
            return
        }
        capturedSnapshot = snapshot()
        building.targetBundleId = capturedSnapshot?.bundleId
        capturedPlan = config.resolved
        capturedEngine = engine
        capturedDictionaryRecovery = settings.stt.dictionaryRecoveryEnabled(
            engineId: activeEngine.id, supportsRecognitionBias: activeEngine.supportsRecognitionBias)
        captureStarted = false
        activeMode = nil
        eligibleModes = []
        routingContext = RoutingContext()

        // Resolve the Phase-A mode. The only slow step is the browser-URL probe (a synchronous AppleScript
        // round trip) for URL-routed modes; with no URL-constrained mode we resolve inline so the mode is
        // known before capture. When a probe IS needed we resolve off the main thread so it never blocks
        // the cue, capture, or HUD — the mode is only needed at commit (transcribeAndInsert awaits this),
        // and the HUD fills its mode in once the probe returns.
        if ModeResolver.requiresURLContext(plan.modes) || ModeResolver.requiresWindowTitleContext(plan.modes) {
            modeResolveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.resolveModeProbing(triggerKey: triggerKey)
                if self.machine.state == .recording, self.captureStarted {
                    self.hud?.render(.recording(mode: self.activeMode?.name, level: max(0, self.lastRenderedLevel)))
                } else if self.machine.state == .recording {
                    self.hud?.render(.arming(mode: self.activeMode?.name ?? self.currentModeName))
                }
            }
        } else {
            modeResolveTask = nil
            applyResolvedMode(triggerKey: triggerKey, url: nil, windowTitle: nil)
        }

        warmActiveEngine()

        // Option A cue gating: the start cue plays now and CAPTURE comes up only after it finishes, so the
        // cue never lands in the recording. The HUD, however, shows instantly — the truthful `.arming`
        // state (not `.recording`) during the gap, so ESC can cancel before the mic is live and before any
        // deferred output mute fires; beginCapture flips it to `.recording` when the mic goes live.
        let cueDelay = effects.begin(settings.duringDictation)
        hud?.render(.arming(mode: currentModeName))
        if cueDelay > 0 {
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
                if Task.isCancelled || self.machine.state != .recording {
                    if self.captureBringUpCancelling {
                        self.finishCanceledBringUp(stopAudio: false)
                    }
                    return
                }
                self.log.error("bring-up failed: \(String(describing: error), privacy: .public)")
                if case AudioCaptureError.preferredInputFailed = error {
                    let name = self.settings.audio.inputDeviceName ?? "selected microphone"
                    self.finishError("Could not start \(name)", action: .openMicrophoneSettings)
                } else if case AudioCaptureError.formatUnavailable = error {
                    // No usable input stream, not a permission issue — so no settings action.
                    self.finishError("No microphone is available")
                } else {
                    self.finishError("Could not start the microphone", action: .openMicrophoneSettings)
                }
                return
            }
            // Released or cancelled while the mic was coming up: nothing to record, so tear the capture
            // back down and bail.
            guard !Task.isCancelled, self.machine.state == .recording else {
                self.finishCanceledBringUp(stopAudio: true)
                return
            }
            self.captureStarted = true
            self.effects.activateDuck()
            self.onRecordingChanged?(true)
            self.startRecordingLimit()
            self.hud?.render(.recording(mode: self.activeMode?.name, level: 0))
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
        // Release the press-time-warmed model on Balanced/Frugal (this terminal does not route through
        // finishError). Capture before releaseCapturedPlan nils capturedEngine.
        let engineUsed = activeEngine
        releaseCapturedPlan()
        applyEvictionAfterDictation(engine: engineUsed)
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
        capturedPlan = nil
        capturedEngine = nil
        capturedDictionaryRecovery = nil
        scheduleCaptureRefresh()
        onBecameIdle?()
    }

    func handleCommit() {
        guard machine.state == .recording else { return }
        guard captureStarted else {
            cancelBeforeCaptureStarted()
            return
        }
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
            // Capture is done — unmute the output now rather than holding it muted across
            // transcription and the (potentially slow) cloud LLM rewrite.
            self.effects.restoreAudio()
            let drainMs = self.elapsedMs(since: drainStart)
            self.building.stageMillis[.drain] = drainMs
            // Open the freshly-written capture once here, for both the debug log and the audioSeconds the
            // transcribe deadline scales from — transcribeAndInsert no longer re-opens it.
            var audioSeconds: Double?
            if let f = try? AVAudioFile(forReading: url) {
                audioSeconds = Double(f.length) / f.fileFormat.sampleRate
                self.log.debug("wav \(f.length) frames @ \(f.fileFormat.sampleRate, privacy: .public)Hz ch=\(f.fileFormat.channelCount, privacy: .public) drain=\(drainMs, privacy: .public)ms")
            } else {
                self.log.error("wav unreadable at \(url.path, privacy: .public)")
            }
            await self.transcribeAndInsert(url: url, audioSeconds: audioSeconds)
        }
    }

    private func cancelBeforeCaptureStarted() {
        let waitForBringUpCleanup = captureBringUpTask != nil
        captureBringUpCancelling = waitForBringUpCleanup
        machine.cancel()
        effects.end(settings.duringDictation, cue: .cancel)
        hud?.render(.hidden)
        clearRewriteEscapeHatch()
        modeResolveTask?.cancel()
        modeResolveTask = nil
        captureStartTask?.cancel()
        captureStartTask = nil
        guard waitForBringUpCleanup else {
            releaseCapturedPlan()
            return
        }
    }

    private func finishCanceledBringUp(stopAudio: Bool) {
        if stopAudio, let url = audio.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        captureBringUpCancelling = false
        releaseCapturedPlan()
    }

    // Phase A (design.md §4.3): resolve the mode from routing context before recording. A non-nil
    // triggerKey (from a mode's own HotkeyMonitor binding) forces that mode, overriding context. The
    // URL and window title are fetched only when a matching constraint exists (resolveModeProbing);
    // otherwise they are nil here.
    private func applyResolvedMode(triggerKey: String?, url: String?, windowTitle: String?) {
        let modes = plan.modes
        let context = RoutingContext(bundleId: capturedSnapshot?.bundleId, url: url, windowTitle: windowTitle)
        routingContext = context
        eligibleModes = ModeResolver.eligibleModes(modes, context: context)
        // The Direct floor is a persisted system mode, so its user-configured trigger/insertion apply
        // both when its key is pressed and when a trigger falls through to it. Fall back to the canonical
        // profile only if it is somehow missing on disk.
        let directFallback = modes.first { $0.id == Mode.directId } ?? .direct
        let resolved = ModeResolver.resolvePhaseA(
            modes: modes, directFallback: directFallback, context: context, triggerKey: triggerKey,
            eligible: eligibleModes)
        // A menu-picked one-shot mode is an explicit choice that bypasses the context gate — it is the
        // deliberate way to run a constrained mode outside its apps (design.md §4.3).
        let override = nextModeOverrideID.flatMap { id in modes.first { $0.id == id && $0.enabled } }
        nextModeOverrideID = nil
        activeMode = securePolicyApplied(override ?? resolved)
    }

    // A focused secure (password) field forces whatever mode resolves fully local: no cloud rewrite, no
    // context, never recorded (design.md §4.4). Applied at every site that sets activeMode so a Phase-B
    // voice re-route to a cloud mode is neutered too. Best-effort — depends on the field exposing the
    // AXSecureTextField subrole (captured in TargetSnapshot.isSecureField).
    private func securePolicyApplied(_ mode: Mode?) -> Mode? {
        guard capturedSnapshot?.isSecureField == true else { return mode }
        return mode?.localOnlyForSecureField()
    }

    private func resolveModeProbing(triggerKey: String?) async {
        var url: String?
        var windowTitle: String?
        if let bundleId = capturedSnapshot?.bundleId {
            // Each probe is gated on a mode actually using it: the URL probe needs Apple Events (an
            // Automation prompt), the title probe an extra AX round trip — neither runs unless a mode's
            // constraints depend on it.
            if ModeResolver.requiresURLContext(plan.modes) {
                url = await ContextProbe.browserURLAsync(forBundleId: bundleId)
            }
            if ModeResolver.requiresWindowTitleContext(plan.modes) {
                windowTitle = ContextProbe.focusedWindowTitle(bundleId: bundleId)
            }
        }
        applyResolvedMode(triggerKey: triggerKey, url: url, windowTitle: windowTitle)
    }

    // Dictionary terms fed to the engine's recognition bias before STT. Only the Phase-A mode's
    // dictionary (⊕ global) is known here — a Phase-B voice route resolves post-STT and so cannot
    // bias recognition (design.md §4.3). Normalized once here (VocabularyMerge already dedups in
    // stable order; this trims and drops blanks) so engines consume clean terms. Engines without
    // bias ignore these.
    private func recognitionBiasTerms() -> [String] {
        guard settings.stt.recognitionBiasEnabled(
            engineId: activeEngine.id, supportsRecognitionBias: activeEngine.supportsRecognitionBias) else { return [] }
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
    private func transcribeBounded(audioSeconds: Double, biasTerms: [String], engine: any SpeechEngine, url: URL) async throws -> String {
        let timeout = max(30, audioSeconds * 20)
        return try await transcribeGate.run(seconds: timeout) {
            try await engine.transcribe(wavURL: url, biasTerms: biasTerms)
        }
    }

    private func transcribeAndInsert(url: URL, audioSeconds: Double?) async {
        await modeResolveTask?.value
        let engine = activeEngine
        building.audioSeconds = audioSeconds

        // Load the model OUTSIDE the bounded transcribe. A CoreML/MLX compile is a legitimate one-time
        // cost — a 632 MB model measured ~140 s to load even from a compiled cache — so counting it
        // against the per-utterance transcribe deadline (≥30 s) both false-times-out a healthy load and,
        // because the abandoned load keeps running, leaves the single-flight gate `Busy` so every later
        // dictation reports "Still finishing…" until it settles. Awaiting the single warm load (started at
        // press, overlapping speech) here keeps the deadline on inference, where it belongs.
        func loadOnce() async throws {
            try await runWithDeadline(seconds: Self.modelLoadDeadlineSeconds) { [task = warm(engine)] in
                try await task.value
            }
        }
        func failModelLoadTerminal(_ error: Error) {
            try? FileManager.default.removeItem(at: url)
            invalidateWarm(engine.id)
            let timedOut = error is DeadlineExceeded
            recordModelLoadFailure(engine.id, timedOut, String(describing: error))
            log.error("model load \(timedOut ? "timed out" : "failed", privacy: .public) (\(engine.id, privacy: .public)): \(error, privacy: .public)")
            finishError(timedOut ? "Loading the speech model timed out" : "Could not load the speech model")
        }
        do {
            try await loadOnce()
        } catch {
            if Task.isCancelled { try? FileManager.default.removeItem(at: url); return }
            // A genuine 300 s hang is not retried — a second wait is worse than surfacing.
            if error is DeadlineExceeded { failModelLoadTerminal(error); return }
            // One automatic retry: a cold CoreML/MLX compile can fail transiently right after launch, and a
            // fresh reload (what a user does by hand) usually succeeds. invalidateWarm drops the failed task
            // so warm(engine) builds a new one; the HUD stays on `transcribing`, so a recovered transient is
            // invisible. Mirrors the pipeline's one-retry policy (design.md §4.2).
            invalidateWarm(engine.id)
            log.notice("model load failed, retrying once (\(engine.id, privacy: .public)): \(error, privacy: .public)")
            do {
                try await loadOnce()
            } catch {
                if Task.isCancelled { try? FileManager.default.removeItem(at: url); return }
                failModelLoadTerminal(error)
                return
            }
        }

        let transcribeStart = DispatchTime.now()
        let rawFromEngine: String
        do {
            rawFromEngine = try await transcribeBounded(
                audioSeconds: audioSeconds ?? 0, biasTerms: recognitionBiasTerms(), engine: engine, url: url)
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
        building.stageMillis[.transcribe] = elapsedMs(since: transcribeStart)
        // A no-speech clip that an engine renders as a whole-utterance annotation (Whisper's
        // `[BLANK_AUDIO]` / `(water running)`) collapses to "" here, so routing, history, and the
        // outcome all see empty and short-circuit to .noSpeech instead of pasting the marker.
        let raw = OutputCleanup.blankingNonSpeechAnnotation(rawFromEngine)
        building.fingerprints[.raw] = .of(raw)

        // Cancelled during STT: bail before routing, rewrite, insertion, or history. cancel() already
        // ended effects and hid the HUD — a stale task must not run the cloud rewrite, touch the
        // target, or mutate routing state a newer dictation may now own.
        if Task.isCancelled { return }

        // Phase B (design.md §4.3): a trigger-phrase suffix re-routes to that mode's pipeline
        // and is stripped from the transcript; otherwise the Phase-A mode stands.
        let routed = ModeResolver.resolvePhaseB(eligibleModes: eligibleModes, transcript: raw, context: routingContext)
        let finalMode = routed.routedModeId.flatMap { id in eligibleModes.first { $0.id == id } } ?? activeMode
        if let finalMode { activeMode = securePolicyApplied(finalMode) }
        pendingHeardTranscript = raw
        let (final, rewrite, transformed) = await produceFinalText(routed: routed, mode: finalMode)

        // Cancelled during the rewrite: bail before any insert or history write.
        if Task.isCancelled { return }

        switch final {
        case .abort(let message, let action):
            // A selection rewrite that failed (or had nothing to do) leaves the target untouched —
            // a destructive op must never overwrite the user's text on failure.
            log.info("aborted: \(message, privacy: .public)")
            finishError(message, action: action)   // applies eviction internally
            clearRewriteEscapeHatch()

        case .insert(let transcript, let bare):
            await finishInsertion(transcript: transcript, heard: raw, transformed: transformed, rewrite: rewrite, bare: bare)
        }
    }

    private func finishInsertion(
        transcript rawTranscript: String, heard: String, transformed: String? = nil, rewrite: RewriteDetails?,
        bare: Bool = false
    ) async {
        // Trim runs on the fully-restored final string, before the trailing suffix is appended, so a
        // command/subject-line mode never ends in a stray "." or "?" — enforcement the rewrite prompt
        // can only request, not guarantee. Applied here so the trimmed text is what the fingerprint,
        // no-speech outcome, insert, and history all see. A `bare` whole-utterance replacement is
        // already the exact value to insert — skip trim (and the trailing suffix below).
        let transcript = (!bare && (activeMode?.trimTrailingPunctuation ?? false))
            ? OutputCleanup.trimTrailingPunctuation(rawTranscript)
            : rawTranscript
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
        building.targetBundleId = current.bundleId ?? capturedSnapshot?.bundleId
        if case .clipboardFallback(let reason) = decision { building.fallbackReason = String(describing: reason) }
        building.fingerprints[.final] = .of(transcript)
        let initialOutcome = DictationMachine.outcomeForTranscript(finalText: transcript, heard: heard, decision: decision)
        // May downgrade to .failed if the actuation (paste) silently fails — success is OBSERVED, not
        // assumed (H1): a clipboard manager racing our scratch write skips ⌘V, so a reported "inserted"
        // with a submit Return would fire into the target with nothing pasted.
        var outcome = initialOutcome
        switch initialOutcome {
        case .noSpeech:
            machine.finish(.noSpeech)
        case .inserted, .copied:
            lastResult = transcript
            // Trailing text rides inside the atomic insert (still one ⌘Z). The submit keystroke lands
            // OUTSIDE that atom and only on a verified insert — never .copied, where a synthesized Return
            // would hit whatever app is now focused instead of the target the text reached.
            let trailing = bare ? .none : (activeMode?.trailing ?? .none)
            let insertStart = DispatchTime.now()
            let actuated = await insert(decision, activeMode?.insertion ?? .paste, activeMode?.clipboardModifier ?? .command, transcript + trailing.suffix(after: transcript))
            building.stageMillis[.insert] = elapsedMs(since: insertStart)
            if !actuated {
                // Nothing landed. Report the truth; the text stays recoverable via "Paste last dictation"
                // (lastResult is set). Never fire submit against a paste that did not happen.
                outcome = .failed("The text could not be inserted")
            } else if initialOutcome == .inserted, let submit = activeMode?.submit, submit != .none,
                      submitTargetStillFocused() {
                await submitKey(submit)
            }
            machine.finish(outcome)
        case .failed:
            machine.finish(outcome)
        }
        // Fire the user-perceptible completion (end cue + HUD) the instant the text has landed, before
        // any record-keeping — the cue and HUD are what the user waits on; the diagnostics record, the
        // history write, and engine eviction are invisible and must not delay the "done" signal.
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
        let recordOutcome: DictationRecord.Outcome
        switch outcome {
        case .noSpeech: recordOutcome = .noSpeech
        case .inserted: recordOutcome = rewrite?.fellBack == true ? .localFallback : .inserted
        case .copied: recordOutcome = rewrite?.fellBack == true ? .localFallback : .copied
        case .failed: recordOutcome = .failed
        }
        finalizeRecord(outcome: recordOutcome)
        recordHistory(heard: heard, transformed: transformed, result: transcript, insertion: outcome, rewrite: rewrite)
        applyEvictionAfterDictation(engine: activeEngine)
        releaseCapturedPlan()
        onDictationCompleted?(outcome)
    }

    // The submit Return fires AFTER the ~250 ms paste-settle window — long enough for the user to ⌘-tab
    // (or switch windows within the same app) away — and lands outside the insert atom, so a stale
    // target sends the keystroke into the wrong place (H4). Re-run the SAME focus-race decision the
    // insert used (`decideInsertion`), against a fresh snapshot, right before submitting: it compares
    // bundle id AND focused window id AND secure-field state, so a same-app window switch or a moved
    // focus is caught, not just an app change. Submit only on a clean `.insert`.
    private func submitTargetStillFocused() -> Bool {
        let decision = decideInsertion(
            captured: capturedSnapshot ?? TargetSnapshot(bundleId: nil), current: snapshot())
        if decision == .insert { return true }
        log.notice("submit skipped: focus moved before Return (\(String(describing: decision), privacy: .public))")
        return false
    }

    // Local history (design.md §4.7): one append per dictation that produced text, unless history is
    // off or the mode opts out. noSpeech is not recorded (nothing was said). Audio and the redaction
    // map are never written; the stored prompt carries tokens, not their originals.
    private func recordHistory(
        heard: String, transformed: String?, result: String, insertion: DictationOutcome,
        rewrite: RewriteDetails?
    ) {
        // A secure-field dictation is never persisted, regardless of the history setting or the mode —
        // the spoken text is a password (design.md §4.4). The diagnostics record holds only fingerprints
        // (hashes), never the transcript, so it is safe to keep; this guards the verbatim history store.
        guard settings.history.enabled, !(activeMode?.excludeFromHistory ?? false),
              capturedSnapshot?.isSecureField != true else { return }
        let outcome: HistoryEntry.Outcome
        switch insertion {
        case .noSpeech: return
        case .inserted: outcome = rewrite?.fellBack == true ? .localFallback : .inserted
        case .copied: outcome = rewrite?.fellBack == true ? .localFallback : .copied
        case .failed: outcome = .failed
        }
        let entry = HistoryEntry(
            timestamp: Date(), modeName: currentModeName, engine: activeEngine.displayName,
            heard: heard, transformed: transformed,
            result: result, outcome: outcome,
            cloudInvolved: rewrite != nil, redaction: rewrite?.redaction ?? false,
            contextCategories: rewrite?.contextCategories ?? [],
            connection: rewrite?.connection, model: rewrite?.model, prompt: rewrite?.prompt)
        guard let history else { return }
        historyWriteQueue.async { [log] in
            do { try history.append(entry) }
            catch { log.error("history append failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // Evicts the engine the dictation actually used (the captured one), not whatever is active now —
    // a mid-dictation switch leaves provider.active pointing at a different, unloaded engine.
    private func applyEvictionAfterDictation(engine: any SpeechEngine) {
        lastUsedAt = ProcessInfo.processInfo.systemUptime
        let idle = settings.stt.evictionIdleSeconds.map(Double.init)
        switch EvictionPolicy.afterDictation(mode: settings.stt.eviction, idleSeconds: idle) {
        case .keepLoaded: break
        case .evictNow:
            invalidateWarm(engine.id)
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
            guard let self, !Task.isCancelled, !self.isBusy else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch EvictionPolicy.onIdleCheck(mode: mode, lastUsedAt: usedAt, now: now, idleSeconds: idle) {
            case .evictNow:
                self.invalidateWarm(active.id)
                await active.evict()
            case .scheduleIdleCheck(let again): self.scheduleIdleEviction(after: again, engine: active)
            case .keepLoaded: break
            }
        }
    }

    private enum FinalText {
        // `bare` ⇒ a whole-utterance replacement: insert verbatim, suppress trim + trailing.
        case insert(String, bare: Bool)
        // leave the target untouched; surface this message, optionally with a repair action
        case abort(String, HUDErrorAction?)
    }

    // Defense-in-depth before insert (design.md §4.2): after the LIFO restore pass, no ISSUED nonce
    // should survive — one that does means a token-opacity/restore bug corrupted the text, which would
    // otherwise paste a literal `⟦SN:VERB:1⟧` or (worse) leak a redacted span. Fail safely and visibly
    // instead. A sentinel-SHAPED substring that is NOT an issued token is legitimate user content (a
    // clipboard/verbatim value that literally contains the sentinel, which restore deliberately leaves
    // as-is) and is passed through untouched.
    private func guardedInsert(_ text: String, issuedTokens: [String]) -> FinalText {
        if issuedTokens.contains(where: { text.contains($0) }) {
            log.error("insert aborted: unrestored sentinel token survived the restore pass")
            return .abort("Dictation could not be completed — please try again", nil)
        }
        return .insert(text, bare: false)
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
        let pipeline = dictationPipeline(for: mode, willRewrite: resolved != nil, transcript: transcript)

        let localStart = DispatchTime.now()
        var ctx = PipelineContext(text: transcript)
        pipeline.forward(&ctx)
        let tokenized = ctx.text

        // Whole-utterance replacement: one rule owned the entire utterance, so insert its generated
        // value verbatim — bypassing the LLM (the model never sees it; redaction is moot) and the
        // trailing/trim shaping. Detected at the replacements stage and reported on the context.
        if let bare = ctx.bareReplacement {
            building.stageMillis[.localProcess] = elapsedMs(since: localStart)
            building.fingerprints[.localProcessed] = .of(bare)
            return (.insert(bare, bare: true), nil, bare)
        }

        // Locally-processed text (tokens restored, no LLM): the history "middle stage", and what we
        // insert when no rewrite runs or it falls back.
        var localCtx = PipelineContext(text: tokenized)
        pipeline.reverse(&localCtx)
        let localProcessed = localCtx.text
        building.stageMillis[.localProcess] = elapsedMs(since: localStart)
        building.fingerprints[.localProcessed] = .of(localProcessed)
        // Record the on-device intermediate unconditionally — the local pipeline runs on every
        // dictation, so a no-op still has to leave an artifact, else history reads as "local was
        // skipped". It equals `transcript` when nothing changed; the History diff renders that as
        // "no differences" rather than a noise stage.
        let transformed = localProcessed

        guard let resolved,
              !tokenized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (guardedInsert(localProcessed, issuedTokens: pipeline.issuedTokens), nil, transformed)
        }
        let result = await rewriteTokenized(
            pipeline: pipeline, tokenized: tokenized, localProcessed: localProcessed,
            instruction: "", mode: resolved.mode, connection: resolved.connection)
        return (guardedInsert(result.text, issuedTokens: pipeline.issuedTokens), result.details, transformed)
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
            return (.abort("Accessibility is off — \(Branding.appName) can't read the selected text.", .openAccessibilitySettings), nil)
        }
        // The selection-capture ⌘C must reach the target, so drop key focus held for ESC-cancel; the
        // subsequent .rewriting render re-takes it so ESC still cancels the rewrite.
        hud?.relinquishKeyFocus()
        guard let selection = await captureSelection(mode.clipboardModifier), !selection.isEmpty else {
            return (.abort("Select some text first", nil), nil)
        }
        guard let connection = connection(for: mode) else {
            return (.abort("\(mode.name) needs an AI connection", nil), nil)
        }
        // The selection IS the content (no post-STT text stages); only the tokenization commands run.
        // A selection can be large (whole documents), and tokenization is pure CPU — run the forward
        // pass off the main actor so a big selection cannot stutter the HUD.
        let pipeline = selectionPipeline(for: mode)
        let tokenized = await Task.detached(priority: .userInitiated) {
            var ctx = PipelineContext(text: selection)
            pipeline.forward(&ctx)
            return ctx.text
        }.value
        let result = await rewriteTokenized(
            pipeline: pipeline, tokenized: tokenized, localProcessed: selection,
            instruction: instruction, mode: mode, connection: connection)
        let final: FinalText = result.ok
            ? guardedInsert(result.text, issuedTokens: pipeline.issuedTokens)
            : .abort("Rewrite failed — selection unchanged", nil)
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
        // Cloud-boundary metadata for the diagnostics record. `content` is exactly what crosses to the
        // LLM (forward-tokenized), so its fingerprint is the sentToLLM boundary for both the dictation
        // and selection paths. The token→original map is never stored — only the count.
        building.cloudInvolved = true
        building.connection = connection.name
        building.model = connection.model
        building.redaction = mode.commands.privacy
        building.issuedTokenCount = issuedTokens.count
        building.fingerprints[.sentToLLM] = .of(content)
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
            connection: connection.name, mode: mode.name, redacted: mode.commands.privacy,
            contextCategories: mode.effectiveContextCategories, offerLocalTranscript: false))

        // Mode prompt + fragments + valid-term hints + opted-in context, fitted to the budget, plus
        // the size-bumped connection — the change-prone assembly lives in its own builder.
        let request = await RewriteRequestBuilder(
            mode: mode, content: content, instruction: instruction, issuedTokens: issuedTokens,
            capturedBundleId: capturedSnapshot?.bundleId, plan: plan, connection: connection).build()

        let rewriteStart = DispatchTime.now()
        let outcome = await RewriteService(client: llmClient).rewrite(
            localText: content, inputs: request.inputs, connection: request.sized,
            issuedTokens: issuedTokens, prompt: request.prompt)
        building.stageMillis[.rewrite] = elapsedMs(since: rewriteStart)
        var restoreCtx = PipelineContext(text: content)
        let fellBack: Bool
        switch outcome {
        case .rewritten(let out): restoreCtx.text = out; fellBack = false; building.fingerprints[.llmOut] = .of(out)
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
    private func dictationPipeline(for mode: Mode?, willRewrite: Bool, transcript: String) -> Pipeline {
        // Dictionary recovery is captured at record start so a settings change mid-dictation cannot
        // change which post-STT stages run.
        let dictionaryRecovery = capturedDictionaryRecovery
            ?? settings.stt.dictionaryRecoveryEnabled(
                engineId: activeEngine.id, supportsRecognitionBias: activeEngine.supportsRecognitionBias)
        var stages = plan.postSTTTextStages(for: mode, dictionaryRecovery: dictionaryRecovery)
        if mode?.commands.liveEdits ?? true {
            stages.append(TokenizingStage.verbatim())
            // Read the clipboard ONLY when the command will actually fire — an ordinary dictation never
            // touches the user's clipboard (privacy + no needless copy of large clipboards). The check
            // runs on the transcript AFTER verbatim tokenization, so a phrase deliberately wrapped in a
            // verbatim span ("begin verbatim insert clipboard contents end verbatim") stays literal and
            // does not trigger a read.
            let afterVerbatim = VerbatimTokenizer.apply(transcript, into: Tokenizer())
            let clip = ClipboardTokenizer.mentions(afterVerbatim) ? clipboard() : nil
            stages.append(TokenizingStage.clipboard(clip))
        }
        if (mode?.commands.privacy ?? false) && willRewrite { stages.append(TokenizingStage.redaction()) }
        return Pipeline(stages)
    }

    // Edit-in-place pipeline: the selection IS the content, so no post-STT text stages run — only the
    // tokenization commands (verbatim if live edits, redaction if privacy; a selection rewrite always
    // calls the LLM). No clipboard stage: the selection-capture ⌘C has already clobbered the clipboard
    // with the selection, so "insert clipboard contents" here would be meaningless.
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
        if machine.state == .recording, !captureStarted, captureBringUpTask != nil {
            cancelBeforeCaptureStarted()
            return
        }
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
                connection: connection.name, mode: mode.name, redacted: mode.commands.privacy,
                contextCategories: mode.effectiveContextCategories, offerLocalTranscript: true))
        }
    }

    private func clearRewriteEscapeHatch() {
        rewriteEscapeTask?.cancel()
        rewriteEscapeTask = nil
        pendingLocalTranscript = nil
        pendingHeardTranscript = nil
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    // Publish the in-flight `building` record to `lastRecord` and emit its textless one-line summary.
    // Called at every terminal point (finishInsertion, finishError) UNCONDITIONALLY — the diagnostics
    // record is not gated on history. humanSummary() carries hashes/counts/ms only, never transcript.
    private func finalizeRecord(outcome: DictationRecord.Outcome, error: String? = nil) {
        building.modeName = currentModeName
        building.outcome = outcome
        if let error { building.error = error }
        lastRecord = building
        log.debug("\(self.building.humanSummary(), privacy: .public)")
    }

    private func finishError(_ message: String, action: HUDErrorAction? = nil) {
        machine.finish(.failed(message))
        effects.end(settings.duringDictation, cue: .error)
        hud?.render(.error(message: message, action: action))
        scheduleHide(after: action == nil ? 2 : 8)
        finalizeRecord(outcome: .failed, error: message)
        // A failed dictation must release the model on Balanced/Frugal just like a successful one —
        // otherwise a transcribe timeout/failure (or a mic/bring-up error after the press-time warm load)
        // pins the model resident until quit, since no other terminal re-arms the idle check. Capture the
        // engine before releaseCapturedPlan nils capturedEngine; eviction awaits any abandoned transcribe's
        // settlement via SerializedEngine, so this can't race the in-flight call.
        let engineUsed = activeEngine
        releaseCapturedPlan()
        applyEvictionAfterDictation(engine: engineUsed)
    }

    private func scheduleHide(after seconds: Double = 2) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, !isBusy else { return }
            hud?.render(.hidden)
        }
    }
}
