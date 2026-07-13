import AppKit
import AVFoundation
import Foundation
import KeyScribeKit
import os

struct DictationCompletion: Sendable {
    let outcome: DictationOutcome
    let modeId: String?
    let heard: String
    let finalText: String
}

@MainActor
final class DictationController {
    static let fallbackModeName = "Plain Dictation"
    private let log = Logger(subsystem: "com.keyscribe.app", category: "dictation")

    private(set) var settings: Settings
    private let provider: SpeechEngineProvider
    private let config: ConfigCache
    private let history: HistoryStore?
    // Append-only history I/O off the main actor so the disk write never sits on the completion path.
    // Serial so concurrent dictations can't interleave or reorder appends within a day file.
    private let historyWriteQueue = DispatchQueue(label: "com.keyscribe.history.write", qos: .utility)
    private let audio: AudioCapturing
    private let presenceDetector: SpeechPresenceDetecting
    private let insert: (InsertionDecision, Mode.Insertion, Mode.ClipboardModifier, String, Bool) async -> Bool
    private let submitKey: (Mode.Submit) async -> Void
    private let captureSelection: (Mode.ClipboardModifier) async -> String?
    private let clipboard: @MainActor () -> String?
    private let pressSnapshot: @MainActor () -> TargetSnapshot
    private let shouldAdoptFullSnapshot: Bool
    // Full snapshot for the hot AX sites (press adoption + insertion), off the main actor so an
    // unresponsive target can't stall arming/paste. Defaults to the injected sync `snapshot` inline, so a
    // test injecting only `snapshot` keeps its exact call sequence.
    private let snapshotAsync: @MainActor () async -> TargetSnapshot
    private let micStatus: @MainActor () -> PermissionStatus
    private let accessibilityGranted: @MainActor () -> Bool
    private let frontmostBundleId: @MainActor () -> String?
    private let precedingTextProbe: @MainActor (String) async -> String?
    private let activeEngineUsable: @MainActor (any SpeechEngine) -> Bool
    private let isSessionLocked: @MainActor () -> Bool
    private let llmClient: any LLMClient
    // Durable sink for a model-load failure surviving both retries. Injected so tests assert it was
    // recorded without touching the real diagnostics file.
    private let recordModelLoadFailure: @MainActor (_ engineId: String, _ timedOut: Bool, _ error: String) -> Void
    private let effects: DuringDictationEffects
    // Serialises the STT call: a deadline only abandons a wedged transcribe, so this keeps a second
    // dictation from starting a concurrent transcribe on the same engine until the first truly settles.
    private var transcribeGate = SingleFlightDeadline()
    private var transcribeBusyStreak = 0
    private var transcribeBusyStreakStartedAt: Double?
    // Modes whose dropped-for-<CR> replacement rules have already been logged, so a vanished rule is
    // surfaced once per mode rather than on every dictation.
    private var loggedReturnMarkerDropModes: Set<String> = []
    private static let transcribeBusyStreakLimit = 3
    private static let transcribeBusyBackstopSeconds: Double = 600
    // A counter, not a flag: several model rows can verify at once, and each holder must keep occupancy up
    // until its own use settles.
    private var selfTestGateUsers = 0
    private static let selfTestSettlePollMs = 20
    private static let selfTestClearancePolls = 150
    var selfTestClipURLOverride: URL?
    private weak var hud: HUDPresenting?

    private var machine = DictationMachine()

    // Per-dictation state bundled so it drops as a unit at every terminal (releaseCapturedPlan) — reset is
    // structural, no field can leak into the next dictation via a forgotten reset path. `building`
    // accumulates stage timings + boundary fingerprints (finalizeRecord publishes to `lastRecord`; token
    // COUNTS + one-way fingerprints only, never the token→original map, design.md §4.2). The frozen
    // captured* fields insulate the in-flight dictation from a mid-dictation config/engine change (see
    // `plan`/`activeEngine`).
    // DictationIdentity: reference identity per dictation. Struct copies (`session?.field = …`) share it, so
    // `===` distinguishes "still this dictation" from "a successor replaced it" across an await — stops a
    // suspended streaming build from opening on the SUCCESSOR's captured engine.
    private final class DictationIdentity: Sendable {}

    private struct DictationSession {
        let identity = DictationIdentity()
        var building: DictationRecord
        // Press instant (session creation == top of handleStart); the `arm` stage measures this → mic-live.
        var pressedAt = DispatchTime.now()
        var capturedSnapshot: TargetSnapshot?
        var capturedPlan: ResolvedConfig?
        var capturedEngine: (any SpeechEngine)?
        // Name of the input device this dictation bound, snapshotted when the mic goes live so history
        // records the mic actually used even after the session moves on. nil until capture is live.
        var capturedInputDevice: String?
        var capturedRecognitionBias: Bool?
        var activeMode: Mode?
        var eligibleModes: [Mode] = []
        var routingContext = RoutingContext()
        // How the mode was chosen, for the History "how this was chosen" line (UX2 phase 7c). Set at Phase-A
        // resolution (key/context/fallback), overridden to .oneShot for a menu pick, and to .spokenPhrase
        // with the matched phrase when Phase B re-routes.
        var modeChoice: ModeChoiceReason = .fallback
        var routedPhrase: String?
        var triggerDisplay: String?
        var pendingLocalTranscript: String?
        var pendingLocalIssuedTokens: [String] = []
        var pendingHeardTranscript: String?
        var pendingLocalRewriteDetails: RewriteDetails?
        var dictationTask: Task<Void, Never>?
        var rewriteEscapeTask: Task<Void, Never>?
        var recordingLimitTask: Task<Void, Never>?
        var modeResolveTask: Task<Void, Never>?
        var snapshotAdoptionTask: Task<Void, Never>?
        var captureBringUpTask: Task<Void, Never>?
        var levelPollTask: Task<Void, Never>?
        // Streaming transcription (P3-1), non-nil only when the flag is on AND the active engine streams.
        // The driver owns the deferred-start session; the continuation is the writer→driver feed; the feed
        // task drains it. All torn down in releaseCapturedPlan (driver.cancel releases the engine lock).
        var streamingDriver: StreamingDictationDriver?
        var streamingSampleContinuation: AsyncStream<[Float]>.Continuation?
        var streamingFeedTask: Task<Void, Never>?
        // Preconnect and the preceding-text probe fire only once both are set: mode resolved AND secure-aware
        // snapshot adopted (so a secure field neuters the mode first).
        var modeReady = false
        var snapshotReady = false
        var preconnectFired = false
        var precedingTextTask: Task<String?, Never>?
    }
    // Non-nil only while a dictation is in flight. Per-dictation state is `session?.field`; the façade
    // accessors below stay for call-site ergonomics (building/capturedSnapshot/activeMode) and because tests
    // observe them (dictationTask/captureBringUpTask). A nil session reads as "no captured state"; a write
    // outside a dictation no-ops via optional chaining.
    private var session: DictationSession?
    // The triggerKey that started the in-flight dictation, recorded only once a start is actually admitted
    // (past beginArming). Lets a right-modifier "chord wins" abort cancel ONLY the dictation its own key
    // started, never one a different trigger committed. Cleared with the session at every terminal.
    private var activeStartTrigger: String?

    private var building: DictationRecord {
        get { session?.building ?? DictationRecord(modeName: Self.fallbackModeName) }
        set { session?.building = newValue }
    }
    private var capturedSnapshot: TargetSnapshot? {
        get { session?.capturedSnapshot } set { session?.capturedSnapshot = newValue }
    }
    private var activeMode: Mode? {
        get { session?.activeMode } set { session?.activeMode = newValue }
    }
    // Engine bring-up runs async (off-main, watchdogged) so a wedging device can't freeze the app; the
    // machine flips `.arming`→`.recording` only once the mic is live. Public read for tests.
    var captureBringUpTask: Task<Void, Never>? {
        get { session?.captureBringUpTask } set { session?.captureBringUpTask = newValue }
    }
    var snapshotAdoptionTask: Task<Void, Never>? {
        get { session?.snapshotAdoptionTask } set { session?.snapshotAdoptionTask = newValue }
    }
    var dictationTask: Task<Void, Never>? {
        get { session?.dictationTask } set { session?.dictationTask = newValue }
    }

    // Fire-and-forget streaming-session cancel at teardown (releases the engine lock a live session holds);
    // nil when there was no live streaming session. Exposed so tests await the release deterministically.
    private(set) var streamingCancelTask: Task<Void, Never>?

    // Test seam: whether the shared transcribe/finalize gate is still occupied. A wedged finalize keeps it
    // busy until it settles — tests assert the abandoned session holds the gate, then that a later dictation
    // proceeds once freed.
    func transcribeGateBusy() async -> Bool { await transcribeGate.isBusy }

    private var hideTask: Task<Void, Never>?
    private var idleEvictionTask: Task<Void, Never>?
    // BYOK endpoint warm-up (see maybePreconnect); one in flight at a time.
    private var preconnectTask: Task<Void, Never>?
    private var idleEvictionEngine: (any SpeechEngine)?
    // Re-realizes the audio input binding while idle so the first dictation after a long idle/sleep doesn't
    // pay a stale unit-realization on the hot path. See scheduleCaptureRefresh.
    private var captureRefreshTask: Task<Void, Never>?
    private static let captureRefreshIdleSeconds: Double = 240
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastUsedAt: Double = 0
    // Retention only changes at a day boundary, so sweep once per day rather than per dictation.
    private var lastRetentionSweepDay: String?
    private(set) var lastResult: String?
    // Published diagnostics record for the most recent COMPLETED dictation (finalizeRecord copies `building`
    // here at each terminal); survives past the session for the menu/log. Privacy as above.
    private(set) var lastRecord: DictationRecord?
    private(set) var nextModeOverrideID: String?

    // Safety bound on a runaway hold (stuck key, walked away): a recording grows an unbounded WAV +
    // in-memory PCM (~3.7 MiB/min @16k). Drop it with a HUD notice rather than spike memory.
    private let maxRecordingSeconds: Double

    // Frozen config snapshot for the in-flight dictation (captured at record-start). A mid-dictation reload
    // makes a new ResolvedConfig without mutating this one, so one dictation sees one coherent config; nil
    // between dictations, falling back to live `config.resolved`.
    private var plan: ResolvedConfig { session?.capturedPlan ?? config.resolved }

    // STT engine frozen at record-start alongside the plan. Reading `provider.active` afresh at
    // transcribe/bias/evict time would let a mid-dictation engine switch transcribe with a different engine
    // or evict the model mid-call. One capture, used everywhere for this dictation.
    private var activeEngine: any SpeechEngine { session?.capturedEngine ?? provider.active }

    // The in-flight/completed model load for `warmEngineId`, so the press-time warm and commit-time wait
    // share ONE load instead of racing two compiles of a multi-hundred-MB model. Invalidated on eviction.
    private var warmTask: Task<Void, Error>?
    private var warmEngineId: String?
    private var protectedEngineIds: Set<String> = []
    // Backstop for a wedged model load. Cold loads are slow (632 MB CoreML measured ~140 s even from a
    // compiled cache), so this only fires on a genuine hang. Loading runs OUTSIDE the transcribe gate, so a
    // tripped load surfaces an error without wedging the next dictation.
    private static let modelLoadDeadlineSeconds: Double = 300

    // Last HUD level rendered while recording (quantized). Forwarding only on a meaningful change keeps the
    // HUD from re-rendering its whole tree at buffer rate. Reset per recording.
    private var lastRenderedLevel: Float = -1

    // Set at handleStart for a tap-to-toggle trigger so the recording HUD can show "tap X again to stop"
    // (UX2 phase 6b) — a latched recording is otherwise indistinguishable from hold-to-talk. nil for
    // hold gestures and the context-resolved default (no single key fired it).
    private var latchedTriggerName: String?

    // Mic meter is PULLED, not pushed: the capture adapter publishes the level into an atomic from the RT
    // thread (no per-buffer main-actor hop), and a ~30 Hz poll reads it only while recording. Renders
    // deduped by `renderLevel`.
    private static let levelPollInterval: Duration = .milliseconds(33)

    // Output-latency pad on the cue-end admission boundary (P1-1): the chime ends a little after play-call +
    // file-duration, so admit that much later to keep its tail out of the recording.
    private static let cueAdmitPadSeconds: Double = 0.04

    private func pollLevelWhileRecording() {
        session?.levelPollTask?.cancel()
        session?.levelPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, case .recording = self.machine.state else { return }
                self.renderLevel(self.audio.currentLevel)
                try? await Task.sleep(for: Self.levelPollInterval)
            }
        }
    }

    private func renderLevel(_ level: Float) {
        guard case .recording = machine.state else { return }
        // Push every poll tick (keeping the 1/20 quantization for visual stability but dropping the equality
        // skip) so the level indicator keeps moving even when the level is momentarily stable. A 30 Hz publish
        // rebuilds only LevelIndicator (HUDView holds HUDLevel un-observed), so this stays cheap.
        let quantized = (level * 20).rounded() / 20
        lastRenderedLevel = quantized
        hud?.render(.recording(mode: activeMode?.name, level: quantized, latchedTrigger: latchedTriggerName))
    }

    // Fired after every terminal insertion outcome. First run uses it to require one successful dictation
    // before completing onboarding (ui_design.md §2) and to attribute a tutorial-playground lesson to the
    // producing mode.
    var onDictationCompleted: ((DictationCompletion) -> Void)?

    // Fired true when capture starts, false when it ends (commit or a start failure). The menu-bar
    // glyph tints red while true (ui_design.md §Dynamic status).
    var onRecordingChanged: ((Bool) -> Void)?

    // Fired when the dictation reaches a terminal (idle). Lets the app apply work that must wait for quiet —
    // e.g. rebinding hotkeys deferred during a hold so a held key isn't stranded by a mid-dictation reload.
    var onBecameIdle: (() -> Void)?

    var isBusy: Bool { machine.isBusy }
    var hasResult: Bool { lastResult != nil }

    // Work parked by `runWhenIdle` while a dictation is in flight, drained at the next terminal.
    private var pendingIdleWork: [() -> Void] = []

    // Run `work` now if idle, else defer it until the current dictation reaches a terminal state. Main-actor
    // confined, so the parked closures need no synchronization.
    func runWhenIdle(_ work: @escaping () -> Void) {
        guard isBusy else { work(); return }
        pendingIdleWork.append(work)
    }

    private func drainIdleWork() {
        guard !pendingIdleWork.isEmpty else { return }
        let work = pendingIdleWork
        pendingIdleWork.removeAll()
        for item in work { item() }
    }
    var nextModeOverrideName: String? {
        nextModeOverrideID.flatMap { id in config.modes.first { $0.id == id }?.name }
    }
    private var currentModeName: String { activeMode?.name ?? Self.fallbackModeName }

    init(
        settings: Settings, provider: SpeechEngineProvider,
        config: ConfigCache, history: HistoryStore?, hud: HUDPresenting?,
        audio: AudioCapturing? = nil,
        presenceDetector: SpeechPresenceDetecting? = nil,
        effects: DuringDictationEffects? = nil,
        insert: @escaping (InsertionDecision, Mode.Insertion, Mode.ClipboardModifier, String, Bool) async -> Bool = TextInserter.perform,
        submitKey: @escaping (Mode.Submit) async -> Void = TextInserter.submit,
        captureSelection: @escaping (Mode.ClipboardModifier) async -> String? = { await TextInserter.captureSelection(modifier: $0) },
        clipboard: @escaping @MainActor () -> String? = TextInserter.currentClipboardText,
        pressSnapshot: (@MainActor () -> TargetSnapshot)? = nil,
        snapshot: @escaping @MainActor () -> TargetSnapshot = { ContextProbe.snapshot() },
        snapshotAsync: (@MainActor () async -> TargetSnapshot)? = nil,
        micStatus: @escaping @MainActor () -> PermissionStatus = { Permissions.microphoneStatus() },
        accessibilityGranted: @escaping @MainActor () -> Bool = { Permissions.accessibilityStatus() == .granted },
        frontmostBundleId: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        precedingTextProbe: @escaping @MainActor (String) async -> String? = { await ContextProbe.precedingText(forBundleId: $0) },
        activeEngineUsable: @escaping @MainActor (any SpeechEngine) -> Bool = { engine in
            InstalledEngineFilter.shouldRun(engineId: engine.id)
        },
        isSessionLocked: @escaping @MainActor () -> Bool = { SessionLockMonitor.isSessionLocked() },
        llmClient: any LLMClient = HTTPLLMClient(),
        recordModelLoadFailure: @escaping @MainActor (String, Bool, String) -> Void = {
            ModelLoadDiagnosticsWriter.record(engineId: $0, timedOut: $1, error: $2)
        },
        maxRecordingSeconds: Double = 300
    ) {
        self.settings = settings
        self.provider = provider
        self.config = config
        self.history = history
        self.hud = hud
        self.audio = audio ?? AudioCapture()
        self.presenceDetector = presenceDetector ?? SpeechPresenceDetector(modelsDir: KeyScribePaths.modelsDir)
        self.effects = effects ?? DuringDictationEffects()
        self.insert = insert
        self.submitKey = submitKey
        self.captureSelection = captureSelection
        self.clipboard = clipboard
        self.pressSnapshot = pressSnapshot ?? snapshot
        self.shouldAdoptFullSnapshot = pressSnapshot != nil
        self.snapshotAsync = snapshotAsync ?? { snapshot() }
        self.micStatus = micStatus
        self.accessibilityGranted = accessibilityGranted
        self.frontmostBundleId = frontmostBundleId
        self.precedingTextProbe = precedingTextProbe
        self.activeEngineUsable = activeEngineUsable
        self.isSessionLocked = isSessionLocked
        self.llmClient = llmClient
        self.recordModelLoadFailure = recordModelLoadFailure
        self.maxRecordingSeconds = maxRecordingSeconds
        self.audio.setPreferredInputUID(settings.audio.inputDeviceUID)
        installMemoryPressureHandler()
    }

    // Free the resident STT model on critical memory pressure, but only when idle — an in-flight dictation
    // keeps its engine (evicting mid-flight loses the transcription); a later idle/post-dictation check
    // reclaims it. Local reaction to a local signal, never reported (no telemetry).
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
        let previousEviction = self.settings.stt.eviction
        self.settings = settings
        audio.setPreferredInputUID(settings.audio.inputDeviceUID)
        if !isBusy, let engine = idleEvictionEngine {
            scheduleIdleEviction(after: 0, engine: engine)
        }
        if settings.stt.eviction != previousEviction { reconcileCaptureWarmth() }
    }

    // Bring the warm capture unit in line with a just-changed eviction tier. Without this a downgrade from
    // Fastest strands the unit: Fastest holds it via the periodic refresh with no pending idle-eviction
    // checkpoint, so switching to Balanced/Frugal has nothing to release it. Fastest re-prewarms + refreshes
    // and Balanced re-prewarms + schedules the idle release (both via prewarmCapture); Frugal disposes it.
    private func reconcileCaptureWarmth() {
        guard !isBusy else { return }
        if EvictionPolicy.shouldPrewarmCapture(mode: settings.stt.eviction) {
            prewarmCapture()
        } else {
            captureRefreshTask?.cancel()
            audio.releaseWarm()
        }
    }

    func evictSwitchedAwayEngine(_ engine: any SpeechEngine) {
        guard !isProtectedFromEviction(engine) else {
            runWhenIdle { [weak self] in
                guard let self else { return }
                self.invalidateWarm(engine.id)
                Task { await engine.evict() }
            }
            return
        }
        invalidateWarm(engine.id)
        Task { await engine.evict() }
    }

    // Evict an engine on behalf of a Settings delete/reinstall, then return so the caller can delete its files.
    func evictEngineForSettings(_ engine: any SpeechEngine) async {
        guard !isProtectedFromEviction(engine) else {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                runWhenIdle { [weak self] in
                    guard let self else { cont.resume(); return }
                    self.invalidateWarm(engine.id)
                    Task {
                        await engine.evict()
                        cont.resume()
                    }
                }
            }
            return
        }
        invalidateWarm(engine.id)
        await engine.evict()
    }

    private func isProtectedFromEviction(_ engine: any SpeechEngine) -> Bool {
        protectedEngineIds.contains(engine.id)
    }

    // A Settings self-test transcribes on the SAME non-actor engine a live dictation uses, so it runs
    // through the transcribe gate — two at once would race a non-Sendable SDK object. Dictation wins:
    // skipped while a dictation is in flight, and a residual collision surfaces as a skip (nil), never a
    // failed model.
    func selfTestForSettings(_ engine: any SpeechEngine) async -> Bool? {
        guard !isBusy else { return nil }
        let gate = transcribeGate
        let clip = selfTestClipURLOverride ?? ModelSelfTestRunner.clipURL
        selfTestGateUsers += 1
        let result = await ModelSelfTestRunner.verify(engine, clipURL: clip) { url, biasTerms in
            do {
                return try await gate.run(seconds: Self.selfTestTimeoutSeconds) {
                    try await engine.transcribe(wavURL: url, biasTerms: biasTerms)
                }
            } catch is SingleFlightDeadline.Busy {
                throw ModelSelfTestRunner.Skipped()
            }
        }
        // The gate releases on a detached task just after gate.run returns, so hold occupancy until it truly
        // clears — a waiting dictation must re-enter a free gate, not race the release window.
        if result != nil {
            for _ in 0..<Self.selfTestClearancePolls where await gate.isBusy {
                try? await Task.sleep(for: .milliseconds(Self.selfTestSettlePollMs))
            }
        }
        selfTestGateUsers -= 1
        return result
    }
    private static let selfTestTimeoutSeconds: Double = 30

    // Bounded, so a genuinely wedged engine still falls through to the Busy → error path.
    private func awaitSelfTestClearance() async {
        for _ in 0..<Self.selfTestClearancePolls where selfTestGateUsers > 0 {
            try? await Task.sleep(for: .milliseconds(Self.selfTestSettlePollMs))
        }
    }

    // Warm the active STT engine at press, overlapping model load (CoreML/MLX compile, ANE warmup) with
    // speech instead of paying it after release. Idempotent; never blocks recording (failures surface later
    // at transcribe time).
    private func warmActiveEngine() {
        _ = warm(activeEngine)
    }

    // Fire-and-forget press-time preheat of a per-dictation engine session (Apple's one-shot analyzer),
    // consumed at commit. Separate from warm() because warm caches ONE task per residency; a one-shot
    // analyzer needs a fresh pair per dictation. Not awaited so a settling transcribe can't block.
    private func prepareActiveEngineForDictation() {
        let engine = activeEngine
        Task { await engine.prepareForDictation() }
    }

    // Start (or reuse) the single load for `engine`. Idempotent per engine: a launch preload, the
    // press-time warm, and the commit-time wait all resolve to the same Task, so the model compiles
    // once. Cleared by `invalidateWarm` on eviction so the next press reloads.
    @discardableResult
    private func warm(_ engine: any SpeechEngine) -> Task<Void, Error> {
        if warmEngineId == engine.id, let task = warmTask { return task }
        let clip = Self.warmupClipURL
        // Warm with the user's actual global dictionary, not []. For the bias-capable engines (Whisper,
        // Qwen3) this compiles the biased decode path on the warmup clip so the first real dictation
        // doesn't pay it. Empty dictionary ⇒ [] ⇒ the warmup runs unbiased.
        let biasTerms = Self.warmupBiasTerms(settings: settings, engine: engine, plan: plan)
        let task = Task {
            try await engine.loadIfNeeded()
            // Warm the inference graph on a throwaway clip so the first real dictation doesn't pay the
            // one-time first-predict compile (MLX kernel JIT / CoreML graph specialization) — Qwen measured
            // ~3 s cold vs ~50 ms warm. Overlaps speech, so usually invisible. Best-effort: a warmup failure
            // (e.g. clip absent under `swift run`) must never fail the load. The commit-time await of this
            // task serializes warmup before the real transcribe, so non-actor engines are never reentered.
            if let clip, engine.benefitsFromWarmupClip { _ = try? await engine.transcribe(wavURL: clip, biasTerms: biasTerms) }
        }
        warmEngineId = engine.id
        warmTask = task
        return task
    }

    // Throwaway clip used to warm the inference graph (the bundled self-test recording). Absent under
    // `swift run`/tests, where warmup is simply skipped.
    private static let warmupClipURL = Bundle.main.url(forResource: "model-selftest", withExtension: "wav")

    static func warmupBiasTerms(settings: Settings, engine: any SpeechEngine, plan: ResolvedConfig) -> [String] {
        guard settings.stt.recognitionBiasEnabled(
            engineId: engine.id, supportsRecognitionBias: engine.supportsRecognitionBias) else { return [] }
        return plan.recognitionBiasTerms(for: nil)
    }

    private func invalidateWarm(_ engineId: String) {
        guard warmEngineId == engineId else { return }
        warmTask = nil
        warmEngineId = nil
    }

    // Launch-time warm so the first dictation isn't a cold load — independent of the eviction profile
    // (readiness ≠ residency). Only when the model is on disk or system-managed: warming an uninstalled
    // engine would DOWNLOAD it at launch, racing the first-run wizard's download.
    func preloadActiveEngineIfNeeded() {
        guard InstalledEngineFilter.shouldRun(engineId: activeEngine.id) else { return }
        warmActiveEngine()
        prewarmPresenceDetector()
    }

    private func prewarmPresenceDetector() {
        let detector = presenceDetector
        Task { await detector.prewarm() }
    }

    // Realize the audio input unit before the first press so the first capture starts instantly (the
    // one-time HAL realization is otherwise paid on the hot path). Only when mic is granted — never touch
    // the input subsystem unauthorized; no stream is opened.
    func prewarmCapture() {
        guard micStatus() == .granted,
              EvictionPolicy.shouldPrewarmCapture(mode: settings.stt.eviction) else { return }
        audio.prewarm()
        scheduleCaptureRefresh()
    }

    // Wake/long-idle staleness recovery: the cached CoreAudio binding rots while idle/asleep with no
    // device-topology change to trip the adapter's listeners. Rebuild + re-prewarm WHILE IDLE so the next
    // dictation finds a fresh binding, not a rotted unit. Never touches an in-flight dictation.
    func refreshCaptureBinding() {
        guard micStatus() == .granted, !isBusy,
              EvictionPolicy.shouldPrewarmCapture(mode: settings.stt.eviction) else { return }
        audio.refreshBinding()
        scheduleCaptureRefresh()
    }

    // Single-shot: refresh once after captureRefreshIdleSeconds idle, then STOP — binding rot is rare, so a
    // perpetual rebuild would be churn. Re-armed on every return-to-idle (releaseCapturedPlan) and on wake,
    // cancelled at handleStart; a long unbroken idle past one refresh falls back to the bring-up watchdog
    // rather than more idle rebuilds.
    private func scheduleCaptureRefresh() {
        captureRefreshTask?.cancel()
        let mode = settings.stt.eviction
        if EvictionPolicy.periodicallyRefreshesCapture(mode: mode) {
            captureRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.captureRefreshIdleSeconds))
                guard let self, !Task.isCancelled, !self.isBusy, self.micStatus() == .granted else { return }
                self.audio.refreshBinding()
            }
        } else if EvictionPolicy.releasesWarmCaptureOnIdle(mode: mode) {
            // Balanced disposes the warm unit at the idle checkpoint. After a dictation the engine's
            // idle-eviction task does that; but a prewarm OUTSIDE a dictation (launch, wake, a switch into
            // Balanced) has no such task, so schedule the release here — else the mic stays held until the
            // first dictation, which for a tier chosen to coexist with mic-sensitive apps is a leak.
            let after = settings.stt.evictionIdleSeconds.map(Double.init) ?? EvictionPolicy.defaultIdleSeconds
            captureRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(after))
                guard let self, !Task.isCancelled, !self.isBusy else { return }
                self.audio.releaseWarm()
            }
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

    func handleStart(triggerKey: String? = nil, pressStyle: PressStyle = .holdOrTap) {
        // The trigger is a bare modifier event tap with no notion of session state; a key used to
        // wake/unlock the machine can fire it while the login window still owns the console. Never
        // arm the mic while the screen is locked — for a privacy-first app, no audio may be captured
        // while locked. Silent return, same shape as the beginArming guard.
        guard !isSessionLocked() else { return }
        guard machine.beginArming() else { return }
        activeStartTrigger = triggerKey
        latchedTriggerName = (pressStyle == .tapToToggle)
            ? triggerKey.flatMap { try? KeyDescriptor(parsing: $0) }?.displayString : nil
        hideTask?.cancel()
        idleEvictionTask?.cancel()
        captureRefreshTask?.cancel()
        // Open the per-dictation session. Every captured*/activeMode/task/building field below writes
        // through it; it is dropped as a unit at the terminal (releaseCapturedPlan).
        session = DictationSession(building: DictationRecord(modeName: currentModeName))
        // A denied mic does NOT throw — it captures silence, surfacing as a misleading "No speech detected".
        // Catch the real cause up front and point the user at the fix.
        if micStatus() == .denied {
            finishError("Microphone access is off", action: .openMicrophoneSettings)
            return
        }
        let engine = provider.active
        guard activeEngineUsable(engine) else {
            finishError("The selected speech model is not installed", action: nil)
            return
        }
        capturedSnapshot = pressSnapshot()
        adoptFullSnapshot()
        building.targetBundleId = capturedSnapshot?.bundleId
        session?.capturedPlan = config.resolved
        session?.capturedEngine = engine
        protectedEngineIds.insert(engine.id)
        session?.capturedRecognitionBias = settings.stt.recognitionBiasEnabled(
            engineId: engine.id, supportsRecognitionBias: engine.supportsRecognitionBias)

        // Resolve the Phase-A mode. The only slow step is the browser-URL probe (synchronous AppleScript)
        // for URL-routed modes; without one we resolve inline so the mode is known before capture. When a
        // probe is needed we resolve off-main so it never blocks the cue/capture/HUD — the mode is only
        // needed at commit (transcribeAndInsert awaits this).
        if ModeResolver.requiresURLContext(plan.modes) || ModeResolver.requiresWindowTitleContext(plan.modes) {
            session?.modeResolveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.resolveModeProbing(triggerKey: triggerKey)
                guard !Task.isCancelled else { return }
                if self.machine.state == .recording {
                    self.hud?.render(.recording(mode: self.activeMode?.name, level: max(0, self.lastRenderedLevel), latchedTrigger: self.latchedTriggerName))
                } else if self.machine.state == .arming {
                    self.hud?.render(.arming(mode: self.activeMode?.name ?? self.currentModeName))
                }
            }
        } else {
            session?.modeResolveTask = nil
            applyResolvedMode(triggerKey: triggerKey, url: nil, windowTitle: nil)
        }

        warmActiveEngine()
        prepareActiveEngineForDictation()
        prewarmPresenceDetector()

        // Option A cue gating, overlapped (P1-1): the cue plays and the mic comes up UNDER it, but the writer
        // admits only frames at/after the cue-end host time so the cue never lands in the recording. `.arming`
        // shows instantly (ESC still cancels); `.recording`/duck are held until cue end (see beginCapture).
        let cueDelay = effects.begin(settings.duringDictation)
        hud?.render(.arming(mode: currentModeName))
        if cueDelay > 0 {
            let hold = cueDelay + Self.cueAdmitPadSeconds
            let admitAfter = mach_absolute_time() &+ AudioCapture.hostTicks(seconds: hold)
            let holdUntil = DispatchTime.now() + .nanoseconds(Int(hold * 1e9))
            beginCapture(admitAfterHostTime: admitAfter, holdRecordingUntil: holdUntil)
        } else {
            beginCapture()
        }
    }

    private func adoptFullSnapshot() {
        // No async adoption: the press snapshot is already authoritative (incl. its secure-field flag).
        guard shouldAdoptFullSnapshot else { markSnapshotReady(); return }
        let captured = capturedSnapshot?.bundleId
        session?.snapshotAdoptionTask?.cancel()
        session?.snapshotAdoptionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.capturedSnapshot?.bundleId == captured else { return }
            let full = await self.snapshotAsync()
            guard !Task.isCancelled, self.capturedSnapshot?.bundleId == captured, full.bundleId == captured else { return }
            self.capturedSnapshot = full
            self.building.targetBundleId = full.bundleId
            self.activeMode = self.securePolicyApplied(self.activeMode)
            self.markSnapshotReady()   // a bail-out above leaves the gate closed (no preconnect / probe)
        }
    }

    // Deferred-start threshold (Fable adj. #1): audio must exceed this before a streaming session opens, so
    // a short utterance never pays streaming inference or pins the engine lock. Above the press-time
    // prepare/prewarm latency, so session creation never races those on the lock.
    nonisolated static let streamingStartThresholdSeconds: Double = 4

    // Cap on the writer→feed backlog of undelivered PCM chunks. The healthy path stays near-empty; this
    // bounds memory for a future slow/wedged engine whose append can't keep up — overflow is dropped and the
    // driver degrades to batch. ~1024 chunks (writer polls ~5 ms) is many seconds of backlog, past the point
    // streaming has lost its latency win.
    nonisolated static let streamingBackpressureMaxChunks = 1024

    // Stand up the streaming driver + writer→driver feed, or nil when streaming is off / the engine can't
    // stream (the sole gate — the pipeline never branches on flag identity again). Returns the writer-thread
    // sink; nil keeps the batch path byte-for-byte.
    private func setUpStreamingIfEnabled(sampleRate: Int) -> (@Sendable ([Float]) -> Void)? {
        guard settings.features.isEnabled(.streamingTranscription), activeEngine.supportsStreaming else { return nil }
        let policy = StreamingStartPolicy(thresholdSeconds: Self.streamingStartThresholdSeconds, sampleRate: sampleRate)
        let identity = session?.identity
        let driver = StreamingDictationDriver(policy: policy, makeSession: { [weak self] in
            guard let self, let identity else { throw CancellationError() }
            return try await self.makeStreamingSession(for: identity)
        })
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self, bufferingPolicy: .bufferingNewest(Self.streamingBackpressureMaxChunks))
        session?.streamingDriver = driver
        session?.streamingSampleContinuation = continuation
        session?.streamingFeedTask = Task { for await chunk in stream { await driver.ingest(chunk) } }
        return { [weak driver] chunk in
            // Writer-thread sink (off-RT, non-blocking). A dropped chunk means the feed loop fell behind (a
            // wedged/slow append), so trip the driver to batch rather than let memory grow. Off-RT, so a Task
            // here is fine; no-ops once the driver already fell back.
            if case .dropped = continuation.yield(chunk), let driver {
                Task { await driver.noteBackpressureDrop() }
            }
        }
    }

    // Built lazily at the deferred-start crossing (seconds into the recording), so the mode has resolved and
    // its recognition bias is known. Goes through the SerializedEngine wrapper, which holds the exclusive
    // lock for the session's whole lifetime.
    private func makeStreamingSession(for identity: DictationIdentity) async throws -> any StreamingSpeechSession {
        // A SUCCESSOR can start while this deferred-start build is suspended (MainActor hop, mode-resolve
        // await, analyzer setup). Bind to THIS dictation's identity across EVERY suspension: if the live
        // session is gone or is a different dictation, don't open — opening would (a) escape captured-engine
        // discipline by reading the successor's `provider.active`, and (b) steal + lock the successor's engine
        // and consume its one-shot analyzer. Throw so the driver degrades to batch, no lock taken. Check
        // BEFORE the mode-resolve await too, so we wait on THIS dictation's mode task, not a successor's.
        guard session?.identity === identity else { throw StreamingSessionUnavailable() }
        await session?.modeResolveTask?.value
        guard let session, session.identity === identity, let engine = session.capturedEngine else {
            throw StreamingSessionUnavailable()
        }
        return try await engine.makeStreamingSession(sampleRate: engine.captureSampleRate, biasTerms: recognitionBiasTerms())
    }

    private func beginCapture(admitAfterHostTime: UInt64 = 0, holdRecordingUntil: DispatchTime? = nil) {
        lastRenderedLevel = 0
        let sampleRate = activeEngine.captureSampleRate
        let wantsSamples = activeEngine.supportsSampleInput
        let onSamples = setUpStreamingIfEnabled(sampleRate: sampleRate)
        captureBringUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.audio.start(sampleRate: sampleRate, admitAfterHostTime: admitAfterHostTime, wantsSamples: wantsSamples, onSamples: onSamples)
                self.session?.capturedInputDevice = self.audio.currentInputName
            } catch {
                // Bring-up failed or timed out (e.g. a wedged Bluetooth device). A cancel/commit may have
                // already moved us on — only report the mic error if we are still arming.
                if Task.isCancelled || self.machine.state != .arming {
                    if self.machine.state == .cancellingBringUp {
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
            guard !Task.isCancelled, self.machine.state == .arming else {
                self.finishCanceledBringUp(stopAudio: true)
                return
            }
            // Hold "Listening" and the duck until the cue actually ends, so the go-signal and the mute never
            // precede the admission boundary. A no-op when bring-up already outran the cue (or no cue plays).
            if let holdRecordingUntil {
                let remaining = Int64(holdRecordingUntil.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining))
                    guard !Task.isCancelled, self.machine.state == .arming else {
                        self.finishCanceledBringUp(stopAudio: true)
                        return
                    }
                }
            }
            if let pressedAt = self.session?.pressedAt {
                self.building.stageMillis[.arm] = self.elapsedMs(since: pressedAt)
            }
            self.machine.markRecording()
            self.effects.activateDuck()
            self.onRecordingChanged?(true)
            self.startRecordingLimit()
            self.pollLevelWhileRecording()
            self.hud?.render(.recording(mode: self.activeMode?.name, level: 0, latchedTrigger: self.latchedTriggerName))
        }
    }

    private func startRecordingLimit() {
        session?.recordingLimitTask?.cancel()
        let limit = maxRecordingSeconds
        session?.recordingLimitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled, self.machine.state == .recording else { return }
            self.abortRecordingOverLimit()
        }
    }

    private func abortRecordingOverLimit() {
        onRecordingChanged?(false)
        if let url = audio.stop() { try? FileManager.default.removeItem(at: url) }
        finish(machine: .finish(.failed), cue: .cancel,
               state: .error(message: "Recording stopped after \(Int(maxRecordingSeconds / 60)) min", action: nil),
               hideAfter: 4, record: (.failed, "recording limit"), evict: true)
    }

    // Release the frozen config at a terminal so an idle app doesn't pin a stale ResolvedConfig after a
    // reload. `plan` falls back to live `config.resolved` while nil, so clearing between dictations is safe.
    private func releaseCapturedPlan() {
        // Cancel the per-dictation tasks first (dropping the session only releases the references, it does
        // not cancel the Tasks), then drop the whole session as a unit — every captured*/activeMode/
        // routing/building field resets structurally, so none can leak into the next dictation.
        session?.recordingLimitTask?.cancel()
        session?.modeResolveTask?.cancel()
        session?.snapshotAdoptionTask?.cancel()
        captureBringUpTask?.cancel()
        session?.levelPollTask?.cancel()
        session?.rewriteEscapeTask?.cancel()
        session?.precedingTextTask?.cancel()
        // Streaming teardown on EVERY terminal (commit, cancel, error, over-limit): finish the feed and
        // cancel the driver so a session still holding the SerializedEngine lock releases it. Idempotent — a
        // committed dictation already finalized (driver.finish marked it done), so cancel is a no-op there;
        // an aborted dictation with a live session gets its lock freed here (else the engine wedges).
        session?.streamingSampleContinuation?.finish()
        session?.streamingFeedTask?.cancel()
        if let streamingDriver = session?.streamingDriver {
            streamingCancelTask = Task { await streamingDriver.cancel() }
        }
        protectedEngineIds.removeAll()
        session = nil
        activeStartTrigger = nil
        scheduleCaptureRefresh()
        onBecameIdle?()
        // The dictation is fully terminal (reload + transcribe + insert are done), so any deferred idle
        // work — e.g. a Settings model-file deletion parked while this dictation ran — is now safe.
        drainIdleWork()
    }

    func handleCommit() {
        switch machine.state {
        case .arming:
            // Released before the mic went live — nothing to transcribe; tear the pending bring-up down.
            cancelBeforeCaptureStarted()
            return
        case .recording:
            break
        default:
            return
        }
        session?.recordingLimitTask?.cancel()
        onRecordingChanged?(false)
        machine.beginTranscribing()
        // Flip the HUD to transcribing now so the tail-drain (commit-on-release flush, ~one buffer) is
        // invisible; finishDraining keeps the engine running just long enough to capture the final word.
        hud?.render(.transcribing(mode: currentModeName))
        let drainStart = DispatchTime.now()
        dictationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = await self.audio.finishDraining() else {
                if Task.isCancelled { return }
                // Nil drain on an intended commit: the mic was live but produced no file (silence still
                // yields a WAV, caught downstream by .noSpeech). Keep the terminal quiet (hidden HUD, cancel
                // cue — no scary error for a stray tap) but finalize a .failed record so lastRecord describes
                // THIS dictation, not the previous one.
                self.finish(machine: .cancel, cue: .cancel, state: .hidden,
                            record: (.failed, "no audio captured"))
                return
            }
            // The writer already produced this capture's PCM; a sample-capable engine takes it directly
            // instead of re-reading/decoding the WAV (P2-1). The WAV stays on disk for archive/probe/fallback.
            // Read once, right after draining, before a later arm clears it.
            let samples = self.audio.takeDrainedSamples()
            // Capture is done — unmute the output now rather than holding it muted across
            // transcription and the (potentially slow) cloud LLM rewrite.
            self.effects.restoreAudio()
            let drainMs = self.elapsedMs(since: drainStart)
            self.building.stageMillis[.drain] = drainMs
            // The audioSeconds the transcribe deadline scales from. Samples already carry the frame count at
            // the record rate, so derive it directly and skip re-opening the WAV on the release→text path.
            // Only a sample-incapable engine falls back to the file open, which it needs anyway.
            var audioSeconds: Double?
            if let samples {
                audioSeconds = Double(samples.count) / Double(self.activeEngine.captureSampleRate)
                self.log.debug("samples \(samples.count) @ \(self.activeEngine.captureSampleRate, privacy: .public)Hz drain=\(drainMs, privacy: .public)ms")
            } else if let f = try? AVAudioFile(forReading: url) {
                audioSeconds = Double(f.length) / f.fileFormat.sampleRate
                self.log.debug("wav \(f.length) frames @ \(f.fileFormat.sampleRate, privacy: .public)Hz ch=\(f.fileFormat.channelCount, privacy: .public) drain=\(drainMs, privacy: .public)ms")
            } else {
                self.log.error("wav unreadable at \(url.path, privacy: .public)")
            }
            if let reading = await self.noSpeechReading(samples: samples, url: url) {
                try? FileManager.default.removeItem(at: url)
                if Task.isCancelled { return }
                // Two-state no-speech (UX2 phase 6d): nothing-heard (peak never cleared the silence floor — a
                // muted/dead mic) gets the error+repair render; real audio with no speech keeps the neutral
                // "No speech detected". Both record the .noSpeech outcome identically.
                if SpeechPresenceGate.isNothingHeard(peak: reading.peak) {
                    self.finishNothingHeard()
                } else {
                    self.finishNoSpeech()
                }
                return
            }
            // If a streaming session opened, its finalize (post-release inference) produces the transcript;
            // else the driver degraded to batch. Runs after finishDraining, so every sample (incl. the tail)
            // is fed. Bounded by the transcribe deadline gate (finalizeStreamingIfActive): a wedged finalize
            // is terminal — abandoned, never a same-engine batch fallback (the abandoned session still holds
            // the engine lock, so a fallback would queue behind it forever).
            switch await self.finalizeStreamingIfActive(audioSeconds: audioSeconds ?? 0) {
            case .streamed(let text):
                // The streamed arm never re-transcribes, so it has no use for the PCM copy — drop it here
                // rather than carry a multi-MiB buffer through the call for nothing.
                await self.transcribeAndInsert(url: url, audioSeconds: audioSeconds, samples: nil, streamedTranscript: text)
            case .batch:
                await self.transcribeAndInsert(url: url, audioSeconds: audioSeconds, samples: samples, streamedTranscript: nil)
            case .busy:
                try? FileManager.default.removeItem(at: url)
                self.noteTranscribeBusyRejection()
                if Task.isCancelled { return }
                self.log.error("streaming finalize rejected — previous transcription still running (\(self.activeEngine.id, privacy: .public))")
                self.finishError("Still finishing the previous dictation")
            case .timedOut:
                try? FileManager.default.removeItem(at: url)
                if Task.isCancelled { return }
                self.log.error("streaming finalize timed out (\(self.activeEngine.id, privacy: .public))")
                self.finishError("Transcription timed out")
            case .cancelled:
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // The VAD reading when the take is no-speech (so the caller can split nothing-heard vs no-speech on the
    // peak), or nil when speech is present and transcription should proceed.
    private func noSpeechReading(samples: [Float]?, url: URL) async -> SpeechPresenceReading? {
        let reading = await presenceDetector.read(
            samples: samples, url: url, sampleRate: activeEngine.captureSampleRate)
        Log.audio.debug("vad \(reading.presence == .noSpeech ? "noSpeech" : "speech", privacy: .public) maxP=\(reading.maxProbability, privacy: .public) peak=\(reading.peak, privacy: .public) model=\(reading.modelUsed, privacy: .public) \(reading.latencyMs, privacy: .public)ms")
        return reading.presence == .noSpeech ? reading : nil
    }

    private func finishNoSpeech() {
        guard machine.beginInserting() else { return }
        hud?.relinquishKeyFocus()
        let completion = DictationCompletion(
            outcome: .noSpeech, modeId: activeMode?.id, heard: "", finalText: "")
        finish(machine: .finish(.noSpeech), cue: .cancel,
               state: .complete(outcome: .noSpeech, mode: currentModeName),
               hideAfter: 2, record: (.noSpeech, nil), evict: true, completion: completion)
    }

    // Nothing was heard — a hardware/mute problem. Renders like an error with the microphone-settings repair
    // (longer hide, action button) but records the same .noSpeech outcome as finishNoSpeech.
    private func finishNothingHeard() {
        guard machine.beginInserting() else { return }
        hud?.relinquishKeyFocus()
        let completion = DictationCompletion(
            outcome: .noSpeech, modeId: activeMode?.id, heard: "", finalText: "")
        finish(machine: .finish(.noSpeech), cue: .error,
               state: .error(message: "Nothing heard — check your microphone", action: .openMicrophoneSettings),
               hideAfter: 8, record: (.noSpeech, nil), evict: true, completion: completion)
    }

    private enum StreamingFinalizeOutcome {
        case streamed(String)   // streaming produced the transcript — use it, no batch transcribe
        case batch              // no session opened, or the driver degraded — run the batch transcribe
        case busy               // the transcribe gate is still occupied by a prior wedged transcribe/finalize
        case timedOut           // this finalize wedged past the deadline; the session may still hold the lock
        case cancelled          // the commit task was cancelled mid-finalize — terminal, no error to show
    }

    // The dictation ended before the deferred-start session finished building; the driver degrades to batch.
    private struct StreamingSessionUnavailable: Error {}

    // Test seam: the streaming-finalize deadline. Production scales with the recording length exactly like
    // the batch transcribe deadline; tests override it to force the deadline in bounded time.
    var streamingFinalizeTimeoutOverride: Double?
    private func streamingFinalizeTimeout(audioSeconds: Double) -> Double {
        streamingFinalizeTimeoutOverride ?? max(30, audioSeconds * 20)
    }

    // Close the feed and finalize under the SAME single-flight deadline gate as the batch transcribe.
    // Wrapping the WHOLE thing — the feed-drain await AND driver.finish() — is load-bearing: a wedged append
    // hangs at `await feedTask?.value` before finalize, so bounding finalize alone wouldn't save the commit.
    // On deadline/Busy the finalize is terminal (never a same-engine batch fallback: the abandoned session
    // holds the engine's exclusive lock forever) — the gate stays closed until it settles and the next press
    // reports "Still finishing…". Stamps .streamFinalize on success.
    private func finalizeStreamingIfActive(audioSeconds: Double) async -> StreamingFinalizeOutcome {
        guard let driver = session?.streamingDriver else { return .batch }
        await awaitSelfTestClearance()
        let continuation = session?.streamingSampleContinuation
        let feedTask = session?.streamingFeedTask
        let finalizeStart = DispatchTime.now()
        let outcome: StreamingDictationDriver.Outcome
        do {
            outcome = try await transcribeGate.run(seconds: streamingFinalizeTimeout(audioSeconds: audioSeconds)) {
                continuation?.finish()
                await feedTask?.value
                return await driver.finish()
            }
        } catch is SingleFlightDeadline.Busy {
            return .busy
        } catch is CancellationError {
            return .cancelled   // a user cancel, not a wedge — don't misreport it as a timeout
        } catch {
            return .timedOut
        }
        switch outcome {
        case .streamed(let text):
            resetTranscribeBusyStreak()
            building.stageMillis[.streamFinalize] = elapsedMs(since: finalizeStart)
            return .streamed(text)
        case .fallBackToBatch:
            resetTranscribeBusyStreak()
            if await driver.fellBehind {
                log.debug("streaming fell behind real time — falling back to batch transcription")
            } else {
                log.debug("streaming fell back to batch transcription")
            }
            return .batch
        }
    }

    private func cancelBeforeCaptureStarted() {
        // Release/ESC during the cue is a release during bring-up (the unit comes up under the cue). Cancel
        // the bring-up task so a fast bring-up sitting in the cue-end hold wakes at once (its guards see
        // `.isCancelled` and tear the mic down) rather than staying live until the hold expires. The task's
        // completion still runs finishCanceledBringUp.
        let waitForBringUpCleanup = captureBringUpTask != nil
        captureBringUpTask?.cancel()
        session?.modeResolveTask?.cancel()
        session?.modeResolveTask = nil
        guard waitForBringUpCleanup else {
            finish(machine: .cancel, cue: .cancel, state: .hidden)
            return
        }
        // Surface the cancel now, but defer the release tail to finishCanceledBringUp so the in-flight
        // bring-up task unwinds first.
        machine.beginCancellingBringUp()
        effects.end(settings.duringDictation, cue: .cancel)
        hud?.render(.hidden)
        clearRewriteEscapeHatch()
    }

    private func finishCanceledBringUp(stopAudio: Bool) {
        if stopAudio, let url = audio.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        finish(machine: .cancel, cue: nil, state: nil)
    }

    // Phase A (design.md §4.3): resolve the mode from routing context before recording. A non-nil
    // triggerKey (from a mode's own HotkeyMonitor binding) forces that mode, overriding context. The
    // URL and window title are fetched only when a matching constraint exists (resolveModeProbing);
    // otherwise they are nil here.
    private func applyResolvedMode(triggerKey: String?, url: String?, windowTitle: String?) {
        let modes = plan.modes
        let context = RoutingContext(bundleId: capturedSnapshot?.bundleId, url: url, windowTitle: windowTitle)
        session?.routingContext = context
        let eligible = ModeResolver.eligibleModes(modes, context: context)
        session?.eligibleModes = eligible
        // The Direct floor is a persisted system mode, so its user-configured trigger/insertion apply
        // both when its key is pressed and when a trigger falls through to it. Fall back to the canonical
        // profile only if it is somehow missing on disk.
        let directFallback = modes.first { $0.id == Mode.directId } ?? .direct
        let resolved = ModeResolver.resolvePhaseAWithReason(
            modes: modes, directFallback: directFallback, context: context, triggerKey: triggerKey,
            eligible: eligible)
        // A menu-picked one-shot mode is an explicit choice that bypasses the context gate — it is the
        // deliberate way to run a constrained mode outside its apps (design.md §4.3).
        let override = nextModeOverrideID.flatMap { id in modes.first { $0.id == id && $0.enabled } }
        nextModeOverrideID = nil
        let choice: ModeChoiceReason = override != nil ? .oneShot : resolved.reason
        session?.modeChoice = choice
        session?.triggerDisplay = choice == .triggerKey
            ? triggerKey.flatMap { try? KeyDescriptor(parsing: $0) }?.displayString : nil
        activeMode = securePolicyApplied(override ?? resolved.mode)
        session?.modeReady = true
        onModeAndSnapshotReady()
    }

    private func markSnapshotReady() {
        session?.snapshotReady = true
        onModeAndSnapshotReady()
    }

    private func onModeAndSnapshotReady() {
        maybePreconnect()
        maybeStartPrecedingProbe()
    }

    // Warm the resolved mode's endpoint once the mode and the secure-aware snapshot are both settled; a
    // secure field neuters the mode (no connection → no preconnect).
    private func maybePreconnect() {
        guard let session, session.modeReady, session.snapshotReady, !session.preconnectFired,
              let mode = activeMode, let connection = connection(for: mode) else { return }
        self.session?.preconnectFired = true
        preconnectTask?.cancel()
        preconnectTask = Task { [llmClient] in await llmClient.preconnect(connection: connection) }
    }

    // Overlap the preceding-text AX walk with drain+transcribe. A secure field has neutered the mode by here,
    // so effectiveContext.precedingText is off and the field is never read.
    private func maybeStartPrecedingProbe() {
        guard let session, session.modeReady, session.snapshotReady, session.precedingTextTask == nil,
              activeMode?.effectiveContext.precedingText == true,
              let bundleId = capturedSnapshot?.bundleId else { return }
        let probe = precedingTextProbe
        self.session?.precedingTextTask = Task { await probe(bundleId) }
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
        // The probe is the one per-dictation task that can outlive a cancel (browser-URL round trip runs
        // ~0.6 s after ESC). A cancelled dictation must not apply its stale mode: it would write A's
        // routing/activeMode into a live successor B and consume B's one-shot override (nextModeOverrideID
        // lives on the controller, so session == nil doesn't neuter that write).
        guard !Task.isCancelled else { return }
        applyResolvedMode(triggerKey: triggerKey, url: url, windowTitle: windowTitle)
    }

    // Dictionary terms fed to recognition bias before STT. Only the Phase-A mode's dictionary (⊕ global) is
    // known here — a Phase-B route resolves post-STT and can't bias recognition (design.md §4.3). Normalized
    // once (trims, drops blanks). Engines without bias ignore these.
    private func recognitionBiasTerms() -> [String] {
        let enabled = session?.capturedRecognitionBias ?? settings.stt.recognitionBiasEnabled(
            engineId: activeEngine.id, supportsRecognitionBias: activeEngine.supportsRecognitionBias)
        guard enabled else { return [] }
        return plan.recognitionBiasTerms(for: activeMode)
    }

    // Bound the STT call so a wedged CoreML/MLX transcribe can't spin the HUD forever. The cap scales with
    // recording length (20× real-time, ≥30s floor) — never trips on a legitimately slow transcribe, still
    // abandons a true hang. The gate runs the engine as an unstructured task, so even an engine that ignores
    // cancellation is abandoned at the deadline; a late result no-ops. An abandoned transcribe may still run,
    // so the gate refuses a second concurrent call (throws `Busy`) until it settles — two never run at once.
    private func transcribeBounded(audioSeconds: Double, biasTerms: [String], engine: any SpeechEngine, url: URL, samples: [Float]?) async throws -> String {
        await awaitSelfTestClearance()
        let timeout = max(30, audioSeconds * 20)
        return try await transcribeGate.run(seconds: timeout) {
            // Prefer the in-memory PCM when the engine accepts it (P2-1); fall back to the WAV otherwise.
            if engine.supportsSampleInput, let samples {
                return try await engine.transcribe(
                    samples: samples, sampleRate: engine.captureSampleRate, biasTerms: biasTerms)
            }
            return try await engine.transcribe(wavURL: url, biasTerms: biasTerms)
        }
    }

    private func noteTranscribeBusyRejection() {
        let now = ProcessInfo.processInfo.systemUptime
        let streakStart = transcribeBusyStreakStartedAt ?? now
        transcribeBusyStreakStartedAt = streakStart
        transcribeBusyStreak += 1
        let backstopElapsed = now - streakStart >= Self.transcribeBusyBackstopSeconds
        guard transcribeBusyStreak >= Self.transcribeBusyStreakLimit || backstopElapsed else { return }
        log.error("transcribe gate wedged for \(now - streakStart, privacy: .public)s after \(self.transcribeBusyStreak, privacy: .public) rejection(s) — rebuilding the gate")
        transcribeGate = SingleFlightDeadline()
        resetTranscribeBusyStreak()
    }

    private func resetTranscribeBusyStreak() {
        transcribeBusyStreak = 0
        transcribeBusyStreakStartedAt = nil
    }

    private func transcribeAndInsert(url: URL, audioSeconds: Double?, samples: [Float]? = nil, streamedTranscript: String? = nil) async {
        await session?.modeResolveTask?.value
        let engine = activeEngine
        building.audioSeconds = audioSeconds

        let rawFromEngine: String
        if let streamedTranscript {
            // Streaming already produced the transcript during capture (finalize ran in handleCommit). No
            // batch transcribe, no .transcribe stage. The model-load block is skipped: a finalized session
            // proves the model is loaded, so running load machinery here could only fabricate an impossible
            // "model load failed" after a successful transcript.
            rawFromEngine = streamedTranscript
            try? FileManager.default.removeItem(at: url)
        } else {
            // Load the model OUTSIDE the bounded transcribe. A CoreML/MLX compile is a one-time cost (632 MB
            // measured ~140 s even from a compiled cache), so counting it against the transcribe deadline
            // (≥30 s) both false-times-out a healthy load and leaves the gate `Busy` (the abandoned load keeps
            // running) until it settles. Awaiting the single warm load (started at press) keeps the deadline
            // on inference.
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
            let modelWaitStart = DispatchTime.now()
            // A resident model resolves loadOnce() in ~0 ms; a cold load can run seconds (~140 s for a big ANE
            // model). Rather than leave the HUD on "Transcribing" — a lie during a load — name the wait once
            // it exceeds ~1 s (P2-2). Cancelled on resolution; guarded on machine.state so a cancel can't
            // render it stale.
            let loadingHUD = scheduleLoadingModelHUD()
            do {
                try await loadOnce()
            } catch {
                if Task.isCancelled { loadingHUD.cancel(); try? FileManager.default.removeItem(at: url); return }
                // A genuine 300 s hang is not retried — a second wait is worse than surfacing.
                if error is DeadlineExceeded { loadingHUD.cancel(); failModelLoadTerminal(error); return }
                // One automatic retry: a cold CoreML/MLX compile can fail transiently right after launch; a
                // fresh reload usually succeeds. invalidateWarm drops the failed task so warm(engine) builds a
                // new one; the HUD stays on `transcribing`, so a recovered transient is invisible. Mirrors the
                // pipeline's one-retry policy (design.md §4.2).
                invalidateWarm(engine.id)
                log.notice("model load failed, retrying once (\(engine.id, privacy: .public)): \(error, privacy: .public)")
                do {
                    try await loadOnce()
                } catch {
                    loadingHUD.cancel()
                    if Task.isCancelled { try? FileManager.default.removeItem(at: url); return }
                    failModelLoadTerminal(error)
                    return
                }
            }
            loadingHUD.cancel()
            // Flip back to Transcribing for the inference that follows. A no-op (render dedupes) unless the
            // loading-model state was actually shown during a slow load.
            hud?.render(.transcribing(mode: currentModeName))
            building.stageMillis[.modelWait] = elapsedMs(since: modelWaitStart)

            let transcribeStart = DispatchTime.now()
            do {
                rawFromEngine = try await transcribeBounded(
                    audioSeconds: audioSeconds ?? 0, biasTerms: recognitionBiasTerms(), engine: engine, url: url, samples: samples)
                resetTranscribeBusyStreak()
            } catch is SingleFlightDeadline.Busy {
                try? FileManager.default.removeItem(at: url)
                noteTranscribeBusyRejection()
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
        }
        // A no-speech clip an engine renders as a whole-utterance annotation (Whisper's `[BLANK_AUDIO]` /
        // `(water running)`) collapses to "" here, so routing/history/outcome see empty and short-circuit to
        // .noSpeech instead of pasting the marker. A bracketed marker riding real speech (Whisper Small's
        // trailing ` [END]`) is trimmed off the boundary, leaving the genuine transcript.
        let raw = OutputCleanup.strippingBoundaryAnnotation(OutputCleanup.blankingNonSpeechAnnotation(rawFromEngine))
        building.fingerprints[.raw] = .of(raw)

        // Cancelled during STT: bail before routing, rewrite, insertion, or history. cancel() already
        // ended effects and hid the HUD — a stale task must not run the cloud rewrite, touch the
        // target, or mutate routing state a newer dictation may now own.
        if Task.isCancelled { return }

        // Phase B (design.md §4.3): a trigger-phrase suffix re-routes to that mode's pipeline
        // and is stripped from the transcript; otherwise the Phase-A mode stands.
        let eligible = session?.eligibleModes ?? []
        let routed = ModeResolver.resolvePhaseB(eligibleModes: eligible, transcript: raw, context: session?.routingContext ?? RoutingContext())
        if let phraseModeId = routed.routedModeId, eligible.contains(where: { $0.id == phraseModeId }) {
            session?.modeChoice = .spokenPhrase
            session?.routedPhrase = routed.matchedPhrase
        }
        // Neuter the routed mode BEFORE it drives the rewrite: produceFinalText resolves the connection off
        // this mode, so a Phase-B re-route to a cloud mode from a secure field must be local-only here, not
        // only on the stored activeMode.
        let finalMode = securePolicyApplied(routed.routedModeId.flatMap { id in eligible.first { $0.id == id } } ?? activeMode)
        activeMode = finalMode
        session?.pendingHeardTranscript = raw
        let (final, rewrite, transformed) = await produceFinalText(routed: routed, mode: finalMode)

        // Cancelled during the rewrite: bail before any insert or history write.
        if Task.isCancelled { return }

        switch final {
        case .abort(let message, let action):
            // A selection rewrite that failed (or had nothing to do) leaves the target untouched —
            // a destructive op must never overwrite the user's text on failure.
            log.info("aborted: \(message, privacy: .public)")
            clearRewriteEscapeHatch()
            finishError(message, action: action)   // applies eviction internally

        case .insert(let transcript, let bare, let submit):
            await finishInsertion(transcript: transcript, heard: raw, transformed: transformed, rewrite: rewrite, bare: bare, submitOverride: submit)
        }
    }

    private func finishInsertion(
        transcript: String, heard: String, transformed: String? = nil, rewrite: RewriteDetails?,
        bare: Bool = false, submitOverride: Mode.Submit? = nil
    ) async {
        clearRewriteEscapeHatch()
        // Guarded transition: another terminal path may already have won the race.
        guard machine.beginInserting() else { return }
        hud?.relinquishKeyFocus()
        let current = await snapshotAsync()
        let targetDecision = decideInsertion(
            captured: capturedSnapshot ?? TargetSnapshot(bundleId: nil), current: current)
        // Without Accessibility every synthetic insertion path is silently dropped by the OS. Divert to
        // the clipboard so the text survives and the outcome reports "copied" truthfully.
        let decision = accessibilityGranted() ? targetDecision : .clipboardFallback(reason: .accessibilityDenied)
        building.targetBundleId = current.bundleId ?? capturedSnapshot?.bundleId
        // Don't clobber a rewrite fallback reason already recorded above — that cause (an LLM 400) is the
        // more surprising one; the insertion-clipboard reason only fills the slot when nothing else claimed it.
        if case .clipboardFallback(let reason) = decision, building.fallbackReason == nil {
            building.fallbackReason = String(describing: reason)
        }
        building.fingerprints[.final] = .of(transcript)
        let initialOutcome = DictationMachine.outcomeForTranscript(finalText: transcript, heard: heard, decision: decision)
        // May downgrade to .failed if paste silently fails; insertion success is observed, not assumed.
        var outcome = initialOutcome
        switch initialOutcome {
        case .noSpeech:
            // A whole-utterance replacement whose entire output is `<CR>` (e.g. "press enter" → Return)
            // trims to empty text, so there is nothing to insert — but the requested keystroke must still
            // land. Fire the submit under the same guards as the insert path (real target, focus unmoved).
            if let submitOverride, transcript.isEmpty {
                if decision == .insert, await submitTargetStillFocused() {
                    await submitKey(submitOverride)
                    outcome = .inserted
                    machine.finish(.inserted)
                } else {
                    // The command WAS heard and the app deliberately declined the Return — that is a refusal,
                    // not silence. Finish truthfully with the real cause instead of "No speech detected".
                    let refusal = submitRefusal(for: decision)
                    finishError(refusal.message, action: refusal.action)
                    return
                }
            } else {
                machine.finish(.noSpeech)
            }
        case .inserted, .copied:
            lastResult = transcript
            // Trailing text rides inside the atomic insert (still one ⌘Z). The submit keystroke lands
            // OUTSIDE that atom and only on a verified insert — never .copied, where a synthesized Return
            // would hit whatever app is now focused instead of the target the text reached.
            let trailing = bare ? .none : (activeMode?.trailing ?? .none)
            // A `<CR>` on a whole-utterance replacement overrides the mode's standing submit for this
            // insert only; absent an override the mode's submit behaves exactly as before.
            let submit = submitOverride ?? activeMode?.submit ?? .none
            // Await the paste's clipboard settle inline only when a submit Return must land after ⌘V.
            let submitFollows = initialOutcome == .inserted && submit != .none
            let insertStart = DispatchTime.now()
            let actuated = await insert(decision, activeMode?.insertion ?? .paste, activeMode?.clipboardModifier ?? .command, transcript + trailing.suffix(after: transcript), submitFollows)
            building.stageMillis[.insert] = elapsedMs(since: insertStart)
            if !actuated {
                // Nothing landed. Report the truth; the text stays recoverable via "Paste last dictation"
                // (lastResult is set). Never fire submit against a paste that did not happen.
                outcome = .failed
            } else if initialOutcome == .inserted, submit != .none,
                      await submitTargetStillFocused() {
                await submitKey(submit)
            }
            machine.finish(outcome)
        case .failed:
            machine.finish(outcome)
        }
        // Fire the user-perceptible completion (end cue + HUD) the instant the text lands, before
        // record-keeping — the diagnostics record, history write, and eviction are invisible and must not
        // delay the "done" signal.
        let endCue: DuringDictationEffects.EndCue
        switch outcome {
        case .inserted, .copied: endCue = .success
        case .noSpeech: endCue = .cancel
        case .failed: endCue = .error
        }
        let recordOutcome: DictationRecord.Outcome
        switch outcome {
        case .noSpeech: recordOutcome = .noSpeech
        case .inserted: recordOutcome = rewrite?.fellBack == true ? .localFallback : .inserted
        case .copied: recordOutcome = rewrite?.fellBack == true ? .localFallback : .copied
        case .failed: recordOutcome = .failed
        }
        // Built here, while the session is still alive, so modeId survives releaseCapturedPlan.
        let completion = DictationCompletion(
            outcome: outcome, modeId: activeMode?.id, heard: heard, finalText: transcript)
        finish(machine: .alreadyTransitioned, cue: endCue,
               state: rewrite?.fellBack == true
                   ? .localFallback(outcome: outcome, mode: currentModeName)
                   : .complete(outcome: outcome, mode: currentModeName),
               hideAfter: 2,
               record: (recordOutcome, nil),
               history: HistoryWrite(heard: heard, transformed: transformed, result: transcript,
                                     insertion: outcome, rewrite: rewrite),
               evict: true, completion: completion)
    }

    // The submit Return fires after the paste-settle window and lands outside the insert atom. Re-run the
    // same focus-race decision against a fresh snapshot before submitting.
    private func submitTargetStillFocused() async -> Bool {
        let decision = decideInsertion(
            captured: capturedSnapshot ?? TargetSnapshot(bundleId: nil), current: await snapshotAsync())
        if decision == .insert { return true }
        log.notice("submit skipped: focus moved before Return (\(String(describing: decision), privacy: .public))")
        return false
    }

    // Truthful copy for a refused bare-`<CR>` submit, keyed off the guard that declined it (ui_components.md
    // vocabulary — name the concrete cause, never "secure"/"safe"). `.insert` here means the pre-insert
    // decision passed but the post-decision focus re-check moved the target out from under the Return.
    private func submitRefusal(for decision: InsertionDecision) -> (message: String, action: HUDErrorAction?) {
        switch decision {
        case .clipboardFallback(.accessibilityDenied):
            return ("Accessibility is off — \(Branding.appName) can't press Return for you.", .openAccessibilitySettings)
        case .clipboardFallback(.secureField):
            return ("Return not sent — the focused field is a password field.", nil)
        case .clipboardFallback, .insert:
            return ("Return not sent — the target window changed.", nil)
        }
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
            device: session?.capturedInputDevice,
            heard: heard, transformed: transformed,
            result: result, outcome: outcome,
            cloudInvolved: rewrite != nil, redaction: rewrite?.redaction ?? false,
            contextCategories: rewrite?.contextCategories ?? [],
            connection: rewrite?.connection, model: rewrite?.model, prompt: rewrite?.prompt,
            modeChoice: session?.modeChoice, routedPhrase: session?.routedPhrase,
            triggerKey: session?.triggerDisplay,
            fallbackReason: outcome == .localFallback ? rewrite?.fallbackReason : nil)
        guard let history else { return }
        let retentionDays = settings.history.retentionDays
        let today = HistoryStore.todayString()
        let sweepRetention = lastRetentionSweepDay != today
        lastRetentionSweepDay = today
        historyWriteQueue.async { [log] in
            do {
                try history.append(entry, today: today)
                if sweepRetention { history.applyRetention(today: today, retentionDays: retentionDays) }
            }
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
            // Frugal (the only tier that evicts immediately) opens the mic only while dictating, so dispose
            // the warm capture unit the commit path left stopped-but-realized — including when the user
            // switched to Frugal mid-dictation, where reconcileCaptureWarmth deferred to this terminal.
            audio.releaseWarm()
        case .scheduleIdleCheck(let after): scheduleIdleEviction(after: after, engine: engine)
        }
    }

    private func scheduleIdleEviction(after: Double, engine active: any SpeechEngine) {
        idleEvictionTask?.cancel()
        idleEvictionEngine = active
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
                // Only Fastest holds the mic warm, and it never reaches evictNow — so any idle eviction
                // (Balanced past its window, or a tier switched to Frugal) also disposes the warm unit.
                self.audio.releaseWarm()
                self.idleEvictionEngine = nil
            case .scheduleIdleCheck(let again): self.scheduleIdleEviction(after: again, engine: active)
            case .keepLoaded: self.idleEvictionEngine = nil
            }
        }
    }

    private enum FinalText {
        // `bare` ⇒ a whole-utterance replacement: insert verbatim, suppress trim + trailing. `submit`
        // is a `<CR>`-requested Return that overrides the mode's submit for this insert only.
        case insert(String, bare: Bool, submit: Mode.Submit?)
        // leave the target untouched; surface this message, optionally with a repair action
        case abort(String, HUDErrorAction?)
    }

    // Defense-in-depth before insert (design.md §4.2): after the LIFO restore pass, no ISSUED nonce should
    // survive — one that does means a token-opacity/restore bug that would paste a literal `⟦SN:VERB:1⟧` or
    // (worse) leak a redacted span. Fail safely and visibly. A sentinel-SHAPED substring that is NOT an
    // issued token is legitimate user content (a clipboard/verbatim value containing the sentinel) and
    // passes through untouched.
    private func guardedInsert(_ text: String, issuedTokens: [String]) -> FinalText {
        if Self.shouldAbortInsertion(text: text, issuedTokens: issuedTokens) {
            log.error("insert aborted: unrestored sentinel token survived the restore pass")
            return .abort("Dictation could not be completed — please try again", nil)
        }
        return .insert(text, bare: false, submit: nil)
    }

    static func shouldAbortInsertion(text: String, issuedTokens: [String]) -> Bool {
        issuedTokens.contains { text.contains($0) }
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
        // Why the cloud rewrite was abandoned (HTTP error, missing key, validation failure). nil when the
        // rewrite succeeded or when fallback was pre-committed before the cause was known (selection path).
        var fallbackReason: String? = nil
    }

    private func trimmedIfNeeded(_ tokenizedText: String, mode: Mode?) -> String {
        guard mode?.trimTrailingPunctuation ?? false else { return tokenizedText }
        return OutputCleanup.trimTrailingPunctuation(tokenizedText)
    }

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

        let localStart = DispatchTime.now()
        let payload = pipeline.forward(transcript)
        let tokenized = payload.text

        // Whole-utterance replacement: one rule owned the entire utterance, so insert its generated
        // value verbatim — bypassing the LLM (the model never sees it; redaction is moot) and the
        // trailing/trim shaping. Detected at the replacements stage and surfaced on the payload.
        if let bare = payload.bareReplacement {
            building.stageMillis[.localProcess] = elapsedMs(since: localStart)
            building.fingerprints[.localProcessed] = .of(bare.text)
            return (.insert(bare.text, bare: true, submit: bare.submit), nil, bare.text)
        }

        // Locally-processed text (tokens restored, no LLM): the history "middle stage", and what we
        // insert when no rewrite runs or it falls back.
        let localProcessed = pipeline.restore(trimmedIfNeeded(tokenized, mode: mode))
        building.stageMillis[.localProcess] = elapsedMs(since: localStart)
        building.fingerprints[.localProcessed] = .of(localProcessed)
        // Record the on-device intermediate unconditionally — the local pipeline runs every dictation, so a
        // no-op still leaves an artifact (else history reads as "local was skipped"). Equals `transcript`
        // when nothing changed; the History diff shows "no differences".
        let transformed = localProcessed

        guard let resolved,
              !tokenized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (guardedInsert(localProcessed, issuedTokens: payload.issuedTokens), nil, transformed)
        }
        let result = await rewriteTokenized(
            pipeline: pipeline, payload: payload, localProcessed: localProcessed,
            instruction: "", mode: resolved.mode, connection: resolved.connection)
        return (guardedInsert(result.text, issuedTokens: payload.issuedTokens), result.details, transformed)
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
        let redactionTokenizer = Tokenizer()
        let pipeline = selectionPipeline(for: mode, redactionTokenizer: redactionTokenizer)
        let payload = await Task.detached(priority: .userInitiated) {
            pipeline.forward(selection)
        }.value
        // The dictated instruction is user content too (design.md §4.4): with privacy on, redact it
        // through the SAME tokenizer as the selection. Unlike `payload.issuedTokens`, these ride as
        // `instructionTokens` (allowed, not required) — most instructions echo nothing back, but one
        // that inserts a value ("change the recipient to ⟦SN:REDACT:2⟧") needs that occurrence to
        // pass the gate rather than fail as stray.
        let contentTokenCount = redactionTokenizer.issuedTokens.count
        let redactedInstruction = mode.commands.privacy
            ? RedactionTokenizer.apply(instruction, into: redactionTokenizer)
            : instruction
        let instructionTokens = Array(redactionTokenizer.issuedTokens.dropFirst(contentTokenCount))
        let result = await rewriteTokenized(
            pipeline: pipeline, payload: payload, localProcessed: selection,
            instruction: redactedInstruction, mode: mode, connection: connection,
            instructionTokens: instructionTokens)
        let final: FinalText = result.ok
            ? guardedInsert(result.text, issuedTokens: payload.issuedTokens)
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
        pipeline: Pipeline, payload: TokenizedPayload, localProcessed: String,
        instruction: String, mode: Mode, connection: Connection, instructionTokens: [String] = []
    ) async -> (text: String, ok: Bool, details: RewriteDetails) {
        let content = payload.text
        let issuedTokens = payload.issuedTokens
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
            session?.pendingLocalTranscript = localProcessed
            session?.pendingLocalIssuedTokens = issuedTokens
            scheduleRewriteEscapeHatch(connection: connection, mode: mode)
        }
        hud?.render(.rewriting(
            connection: connection.name, mode: mode.name, redacted: mode.commands.privacy,
            contextCategories: mode.effectiveContextCategories, offerLocalTranscript: false))

        // Mode prompt + fragments + valid-term hints + opted-in context, fitted to the budget, plus the
        // size-bumped connection — the change-prone assembly lives in its own builder. `issuedTokens`
        // here also lists `instructionTokens` so the model gets the opaque-marker rule even when the
        // selection itself issued none.
        let request = await RewriteRequestBuilder(
            mode: mode, content: content, instruction: instruction, issuedTokens: issuedTokens + instructionTokens,
            capturedBundleId: capturedSnapshot?.bundleId, plan: plan, connection: connection,
            precedingTextTask: session?.precedingTextTask, precedingTextProbe: precedingTextProbe).build()

        if mode.source != .selection {
            session?.pendingLocalRewriteDetails = RewriteDetails(
                connection: connection.name, model: connection.model, redaction: mode.commands.privacy,
                contextCategories: request.contextCategories, prompt: request.promptForHistory, fellBack: true)
        }

        let rewriteStart = DispatchTime.now()
        let outcome = await RewriteService(client: llmClient).rewrite(
            payload: payload, inputs: request.inputs, connection: request.sized,
            allowedTokens: instructionTokens, prompt: request.prompt)
        building.stageMillis[.rewrite] = elapsedMs(since: rewriteStart)
        let gateApproved: String
        let fellBack: Bool
        var fallbackReason: String?
        switch outcome {
        case .rewritten(let out): gateApproved = out; fellBack = false; building.fingerprints[.llmOut] = .of(out)
        case .localFallback(let local, let reason):
            gateApproved = local; fellBack = true; fallbackReason = reason
            // The rewrite silently returning a local fallback used to be invisible — the user saw a benign
            // "local fallback" with no cause. Log the reason on the dictation path so it is diagnosable live,
            // and stamp it on the diagnostics record (humanSummary) too.
            log.notice("rewrite fell back to local: \(reason ?? "unknown", privacy: .public)")
            building.fallbackReason = reason
        }
        // Restore runs only on the gate-approved text (or the fallback), never before the gate — the
        // ordering is structural now that `rewrite` owns the gate and returns the vetted string.
        let text = pipeline.restore(trimmedIfNeeded(gateApproved, mode: mode))
        let details = RewriteDetails(
            connection: connection.name, model: connection.model, redaction: mode.commands.privacy,
            contextCategories: request.contextCategories, prompt: request.promptForHistory, fellBack: fellBack,
            fallbackReason: fallbackReason)
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
        logDroppedReturnMarkerRules(in: stages, mode: mode)
        if mode?.commands.liveEdits ?? true {
            stages.append(TokenizingStage.verbatim())
            // Read the clipboard ONLY when the command actually survives to the clipboard stage — an
            // ordinary dictation never touches the user's clipboard (privacy + no needless copy of large
            // clipboards). The stage sorts AFTER verbatim and reads lazily, so a phrase deliberately
            // wrapped in a verbatim span ("begin verbatim insert clipboard contents end verbatim") is
            // already tokenized away and never triggers a read. The read is main-actor (NSPasteboard);
            // this pipeline's forward pass runs on the main actor, so the bridge is safe.
            stages.append(TokenizingStage.clipboard(read: { [clipboard] in MainActor.assumeIsolated { clipboard() } }))
        }
        if (mode?.commands.privacy ?? false) && willRewrite { stages.append(TokenizingStage.redaction()) }
        return Pipeline(stages)
    }

    // A replacement rule with an unescaped mid-template `<CR>` is invalid config and ReplacementsStage silently
    // drops it — surface that here (KeyScribeKit has no os.Logger) so a vanished rule is diagnosable. Once per mode.
    private func logDroppedReturnMarkerRules(in stages: [any PipelineStage], mode: Mode?) {
        let dropped = stages.compactMap { $0 as? ReplacementsStage }.flatMap(\.droppedForReturnMarker)
        guard !dropped.isEmpty else { return }
        guard loggedReturnMarkerDropModes.insert(mode?.id ?? "").inserted else { return }
        for rule in dropped {
            Log.config.notice("replacement rule dropped: '\(rule.heard, privacy: .public)' has a <CR> that is not at the end of the replacement — a Return marker is only valid as the final token")
        }
    }

    // Edit-in-place pipeline: the selection IS the content, so no post-STT text stages run — only the
    // tokenization commands (verbatim if live edits, redaction if privacy; a selection rewrite always
    // calls the LLM). No clipboard stage: the selection-capture ⌘C has already clobbered the clipboard
    // with the selection, so "insert clipboard contents" here would be meaningless. `redactionTokenizer`
    // is exposed so the caller can also redact the spoken instruction through the same tokenizer (H1).
    private func selectionPipeline(for mode: Mode, redactionTokenizer: Tokenizer = Tokenizer()) -> Pipeline {
        var stages: [any PipelineStage] = []
        if mode.commands.liveEdits { stages.append(TokenizingStage.verbatim()) }
        if mode.commands.privacy { stages.append(TokenizingStage.redaction(tokenizer: redactionTokenizer)) }
        return Pipeline(stages)
    }

    func pasteLast() {
        guard let lastResult else { return }
        guard !pasteLastDivertsToClipboard(
            frontmostBundleId: frontmostBundleId(),
            ownBundleId: Bundle.main.bundleIdentifier,
            accessibilityGranted: accessibilityGranted()
        ) else { _ = TextInserter.copyToClipboard(lastResult); return }
        hud?.relinquishKeyFocus()
        Task { await TextInserter.insertViaPaste(lastResult) }
    }

    // ESC-cancellable only while arming, recording, or transcribing/rewriting — never mid-insert, where the
    // text is already landing and cancel() would race finishInsertion (conflicting state + double cue).
    var isCancellable: Bool { machine.isCancellable }

    func cancel() {
        guard machine.isBusy else { return }
        if machine.state == .arming {
            cancelBeforeCaptureStarted()
            return
        }
        // Already tearing a cancelled bring-up down, or mid-insert — nothing safe to cancel here.
        guard machine.state == .recording || machine.state == .transcribing else { return }
        onRecordingChanged?(false)
        dictationTask?.cancel()
        dictationTask = nil
        // Mid-recording stop() hands back the live capture file; nothing downstream will run, so delete
        // it here (transcribeAndInsert owns cleanup once a commit has handed the URL off, when stop()
        // returns nil). Otherwise every press-then-cancel leaks a temp WAV until the OS reclaims it.
        if let url = audio.stop() { try? FileManager.default.removeItem(at: url) }
        finish(machine: .cancel, cue: .cancel, state: .hidden)
    }

    // The "chord wins" abort from a right-side modifier trigger: the key turned out to be part of a chord, so
    // discard the dictation IT started — never an unrelated one another trigger committed. Two guards, both
    // required: (1) the active session was started by this same trigger key; (2) it is still pre-commit
    // (arming/recording). A dictation that already reached transcribing was committed by a prior deliberate
    // release, so its starting gesture is no longer held and a still-held aborting key cannot own it — cancelling
    // it would be data loss (e.g. right-⌥ punctuation typed while an Fn dictation is transcribing, or the same
    // key re-pressed in a chord after its own tap-to-toggle commit).
    func cancelStartedByModifier(triggerKey: String?) {
        guard activeStartTrigger == triggerKey,
              machine.state == .arming || machine.state == .recording else { return }
        cancel()
    }

    // The screen locked mid-dictation (lid close / hot corner). Cancel any in-flight capture so the
    // mic stops immediately and its temp WAV is deleted — no locked-screen audio survives.
    func handleScreenLocked() {
        guard machine.isBusy else { return }
        cancel()
    }

    func insertLocalTranscriptNow() {
        guard let transcript = session?.pendingLocalTranscript, let heard = session?.pendingHeardTranscript,
              machine.state == .transcribing else { return }
        let issuedTokens = session?.pendingLocalIssuedTokens ?? []
        let rewrite = session?.pendingLocalRewriteDetails
        dictationTask?.cancel()
        clearRewriteEscapeHatch()
        switch guardedInsert(transcript, issuedTokens: issuedTokens) {
        case .abort(let message, let action):
            finishError(message, action: action)
        case .insert(let final, let bare, let submit):
            Task { await self.finishInsertion(transcript: final, heard: heard, transformed: transcript, rewrite: rewrite, bare: bare, submitOverride: submit) }
        }
    }

    private static let loadingModelHUDDelay: Duration = .seconds(1)

    private func scheduleLoadingModelHUD() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.loadingModelHUDDelay)
            guard let self, !Task.isCancelled, self.machine.state == .transcribing else { return }
            self.hud?.render(.loadingModel(mode: self.currentModeName))
        }
    }

    private func scheduleRewriteEscapeHatch(connection: Connection, mode: Mode) {
        session?.rewriteEscapeTask?.cancel()
        session?.rewriteEscapeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.session?.pendingLocalTranscript != nil,
                  self.machine.state == .transcribing else { return }
            self.hud?.render(.rewriting(
                connection: connection.name, mode: mode.name, redacted: mode.commands.privacy,
                contextCategories: mode.effectiveContextCategories, offerLocalTranscript: true))
        }
    }

    private func clearRewriteEscapeHatch() {
        session?.rewriteEscapeTask?.cancel()
        session?.rewriteEscapeTask = nil
        session?.pendingLocalTranscript = nil
        session?.pendingLocalIssuedTokens = []
        session?.pendingHeardTranscript = nil
        session?.pendingLocalRewriteDetails = nil
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

    private enum MachineTerminal {
        case cancel
        case finish(DictationOutcome)
        case alreadyTransitioned
    }

    private struct HistoryWrite {
        let heard: String
        let transformed: String?
        let result: String
        let insertion: DictationOutcome
        let rewrite: RewriteDetails?
    }

    // The one terminal tail every dictation exits through. The fixed order is load-bearing: finalizeRecord
    // and recordHistory read session state (activeMode/activeEngine/currentModeName) so they run before
    // releaseCapturedPlan nils the session; the engine is captured before release so eviction targets the
    // engine this dictation used; onBecameIdle fires exactly once (only from releaseCapturedPlan). A caller
    // that already ran its machine transition (finishInsertion) passes .alreadyTransitioned, and one that
    // must report the mode it used builds `completion` before calling in (activeMode is gone after release).
    private func finish(
        machine terminal: MachineTerminal,
        cue: DuringDictationEffects.EndCue?,
        state: HUDState?,
        hideAfter: Double? = nil,
        record: (outcome: DictationRecord.Outcome, error: String?)? = nil,
        history: HistoryWrite? = nil,
        evict: Bool = false,
        completion: DictationCompletion? = nil
    ) {
        switch terminal {
        case .cancel: machine.cancel()
        case .finish(let outcome): machine.finish(outcome)
        case .alreadyTransitioned: break
        }
        if let cue { effects.end(settings.duringDictation, cue: cue) }
        if let state {
            hud?.render(state)
            if let hideAfter { scheduleHide(after: hideAfter) }
        }
        if let record { finalizeRecord(outcome: record.outcome, error: record.error) }
        if let history {
            recordHistory(heard: history.heard, transformed: history.transformed, result: history.result,
                          insertion: history.insertion, rewrite: history.rewrite)
        }
        let engineUsed = activeEngine
        releaseCapturedPlan()
        if evict { applyEvictionAfterDictation(engine: engineUsed) }
        if let completion { onDictationCompleted?(completion) }
    }

    private func finishError(_ message: String, action: HUDErrorAction? = nil) {
        // Eviction awaits any abandoned transcribe's settlement via SerializedEngine, so releasing the
        // press-time-warmed model here can't race the in-flight call; without it a transcribe failure/
        // timeout would pin the model resident until quit (no other terminal re-arms the idle check).
        finish(machine: .finish(.failed), cue: .error, state: .error(message: message, action: action),
               hideAfter: action == nil ? 2 : 8, record: (.failed, message), evict: true)
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
