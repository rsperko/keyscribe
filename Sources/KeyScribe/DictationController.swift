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
    private let reporter: TakeReporter
    private let inserter: InsertOutput
    private let agentOutput: AgentOutput
    private let commandOutput: VoiceCommandOutput
    private let agentTake: AgentTake
    private let rewriter: TakeRewrite
    private let engines: EngineKeeper
    private let audio: AudioCapturing
    private let presenceDetector: SpeechPresenceDetecting
    private let insert: (InsertionDecision, Mode.Insertion, ClipboardPaste, String, Bool) async -> Bool
    private let submitKey: (Mode.Submit) async -> Void
    private let captureSelection: (ClipboardKeystroke) async -> String?
    private let clipboard: @MainActor () -> String?
    private let agentClipboard: AgentClipboard
    private let pressSnapshot: @MainActor () -> TargetSnapshot
    private let shouldAdoptFullSnapshot: Bool
    private let snapshotAsync: @MainActor () async -> TargetSnapshot
    private let micStatus: @MainActor () -> PermissionStatus
    private let accessibilityGranted: @MainActor () -> Bool
    private let frontmostBundleId: @MainActor () -> String?
    private let precedingTextProbe: @MainActor (pid_t, String?) async -> String?
    private let prefetchClipboard: @MainActor () -> Void
    private let discardPrefetchedClipboard: @MainActor () -> Void
    private let activeEngineUsable: @MainActor (any SpeechEngine) -> Bool
    private let isSessionLocked: @MainActor () -> Bool
    private let llmClient: any LLMClient
    private let silencer: SpeechSilencer
    private let voiceCommands: VoiceCommandRunning
    private let permits: @Sendable (Connection) -> Bool
    private let recordModelLoadFailure: @MainActor (_ engineId: String, _ timedOut: Bool, _ error: String) -> Void
    private let effects: DuringDictationEffects
    private let transcriber = Transcriber()
    private var loggedReturnMarkerDropModes: Set<String> = []
    var selfTestClipURLOverride: URL? {
        get { engines.selfTestClipOverride }
        set { engines.selfTestClipOverride = newValue }
    }
    let hud: HUDChannel

    private var machine = DictationMachine()

    private final class DictationIdentity: Sendable {}

    // Record loss before the main-actor hop, which can arrive after insertion checks. Keep the flag per
    // session; object identifiers can reuse addresses after a session ends.
    final class CaptureLossFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var lost = false
        func markLost() { lock.withLock { lost = true } }
        var isLost: Bool { lock.withLock { lost } }
    }

    private struct DictationSession {
        let identity = DictationIdentity()
        let captureLoss = CaptureLossFlag()
        let recorder = TakeRecorder()
        var voiceCommandStopsAtPress: Int
        var building: DictationRecord
        var pendingPress: PendingPress?
        var pressedAt = DispatchTime.now()
        var capturedSnapshot: TargetSnapshot?
        var capturedPlan: ResolvedConfig?
        var capturedEngine: (any SpeechEngine)?
        var capturedInputDevice: String?
        var capturedRecognitionBias: Bool?
        var activeMode: Mode?
        var eligibleModes: [Mode] = []
        var choiceId: Int?
        var routingContext = RoutingContext()
        var modeChoice: ModeChoiceReason = .fallback
        var routedPhrase: String?
        var triggerDisplay: String?
        var shortcutCandidates: [ModeCandidate] = []
        var pendingLocalTranscript: String?
        var pendingLocalIssuedTokens: [String] = []
        var pendingHeardTranscript: String?
        var pendingLocalRewriteDetails: RewriteDetails?
        var rewriteStartedAt: DispatchTime?
        var releasedAt: DispatchTime?
        var dictationTask: Task<Void, Never>?
        var rewriteEscapeTask: Task<Void, Never>?
        var stoppedAtLimit = false
        var rewriteSkippedAtLimit = false
        var replacementEffects: [ReplacementEffect] = []
        var spokenEdits: String?
        var replacementUsageEpoch: Int?
        var modeResolveTask: Task<Void, Never>?
        var snapshotAdoptionTask: Task<Void, Never>?
        var captureBringUpTask: Task<Void, Never>?
        var modeReady = false
        var snapshotReady = false
        var effectsBegan = false
        var preconnectFired = false
        // An unconfirmed target is treated as secure: no cloud rewrite, context, or history.
        var targetUnconfirmed = false
        var precedingTextTask: Task<String?, Never>?
        var agentRecipient: AgentRecipient.Frozen?
        var agentFrontTask: Task<Void, Never>?
        var agentFrontCutoff: ContinuousClock.Instant?
        var agentSnapshot: AgentSnapshot?
        var agentDestination: String?
        var agentFacts: [HistoryEntry.Fact] = []
    }
    private final class PendingPress {
        let confirmed = SignalLatch()
        var backstop: Task<Void, Never>?
    }
    private var session: DictationSession?
    weak var spokenUpdates: SpokenResultOutput?
    weak var answers: SpokenAnswerOutput?
    var onMemoryPressure: (() -> Void)?
    var spokenAttempts: SpokenAttempts?
    var keepLastReply: (() -> SessionReturns.KeptReply)?
    private(set) var lastSpokenReplyEntry: String?
    private(set) var lastHeardReply: (entry: String?, conversation: String)?
    var onSpokenReplyRecorded: ((_ attempt: String?, _ entry: String) -> Void)?
    var agents: AgentHub? {
        didSet {
            if agents !== oldValue { agentOutput.forgetReceipts() }
            voiceCommands.returnToSessions(agents.map(sessionReturns))
        }
    }

    private func sessionReturns(through hub: AgentHub) -> SessionReturns {
        SessionReturns(
            inFront: { [weak self, weak hub] in
                guard let self, self.settings.features.isEnabled(.codingAgents), let hub else { return nil }
                return await hub.sessionInFront()
            },
            open: { [weak self, weak hub] id, stillWanted in
                guard let self, self.settings.features.isEnabled(.codingAgents), let hub else { return .none }
                return await hub.open(id, makingCurrent: false, stillWanted: stillWanted)
            },
            handle: { [weak self, weak hub] id in
                guard let self, self.settings.features.isEnabled(.codingAgents) else { return nil }
                return hub?.handle(of: id)
            },
            replay: { [weak self] in
                guard let self, self.settings.features.isEnabled(.codingAgents), let spoken = self.spokenUpdates else { return .off }
                return spoken.repeatLast()
            },
            keepReply: { [weak self] in
                guard let self, self.settings.features.isEnabled(.codingAgents) else { return .nothingHeard }
                return self.keepLastReply?() ?? .nothingHeard
            })
    }

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
    var captureBringUpTask: Task<Void, Never>? {
        get { session?.captureBringUpTask } set { session?.captureBringUpTask = newValue }
    }
    var agentFrontTask: Task<Void, Never>? {
        get { session?.agentFrontTask } set { session?.agentFrontTask = newValue }
    }
    var hasFrozenAgentSnapshot: Bool { session?.agentSnapshot != nil }
    var recordingDeadline: ContinuousClock.Instant? { session?.recorder.deadline }
    var snapshotAdoptionTask: Task<Void, Never>? {
        get { session?.snapshotAdoptionTask } set { session?.snapshotAdoptionTask = newValue }
    }
    var dictationTask: Task<Void, Never>? {
        get { session?.dictationTask } set { session?.dictationTask = newValue }
    }

    func transcribeGateBusy() async -> Bool { await transcriber.gate.isBusy }

    private var hideTask: Task<Void, Never>?
    private var noticedReasoning: Set<String> = []
    private var dictationStarts = 0
    private var preconnectTask: Task<Void, Never>?
    private var captureRefreshTask: Task<Void, Never>?
    private static let captureRefreshIdleSeconds: Double = 240
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private(set) var lastResult: String?
    // Survives release into transcription because route loss can arrive after release.
    private var captureTruncated = false

    // The synchronous flag catches loss before the main-actor handler runs.
    var captureWasLost: Bool {
        captureTruncated || (session?.captureLoss.isLost ?? false)
    }
    private(set) var lastRecord: DictationRecord?
    private(set) var nextModeOverrideID: String?
    // Bumped by anything that must stop voice-command work already under way; every action re-checks it.

    private let maxRecordingSeconds: Double
    private let modelRecordingLimit: (String) -> Double?
    private let limitWarningSeconds: Double

    private var plan: ResolvedConfig { session?.capturedPlan ?? config.resolved }

    private var activeEngine: any SpeechEngine { session?.capturedEngine ?? provider.active }

    private static let modelLoadDeadlineSeconds: Double = 300

    private var lastRenderedLevel: Float = -1
    private var levelTicks = 0
    private var tickedCountdown: RecordingCountdown?
    private static let levelTicksPerRebuild = 15

    private var latchedTriggerName: String?

    private static let cueTailPadSeconds: Double = 0.04

    private func pollLevelWhileRecording() {
        session?.recorder.pollLevel { [weak self] in
            guard let self, case .recording = self.machine.state else { return false }
            self.renderLevel(self.audio.currentLevel)
            return true
        }
    }

    private func renderLevel(_ level: Float) {
        guard case .recording = machine.state else { return }
        let quantized = (level * 20).rounded() / 20
        let countdown = recordingCountdown
        levelTicks += 1
        if levelTicks % Self.levelTicksPerRebuild == 1 || countdown != tickedCountdown {
            tickedCountdown = countdown
            lastRenderedLevel = quantized
            hud.presentIfChanged(recordingHUD(level: quantized))
            return
        }
        guard quantized != lastRenderedLevel else { return }
        lastRenderedLevel = quantized
        hud.presentLevel(quantized)
    }

    private var recordingCountdown: RecordingCountdown? {
        session?.recorder.deadline.flatMap { deadline in
            RecordingCountdown(
                remaining: Self.seconds(ContinuousClock.now.duration(to: deadline)),
                warningSeconds: limitWarningSeconds)
        }
    }

    private func recordingHUD(level: Float) -> HUDState {
        .recording(
            mode: activeMode?.name, level: level, latchedTrigger: latchedTriggerName, countdown: recordingCountdown,
            agents: agentTake.roster)
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    var onDictationCompleted: ((DictationCompletion) -> Void)?

    var onRecordingChanged: ((Bool) -> Void)?

    var onBecameIdle: (() -> Void)?
    var onPress: (() -> Void)?

    var onHistoryUpdated: (() -> Void)?

    var isBusy: Bool { machine.isBusy }
    var hasResult: Bool { lastResult != nil }

    private var pendingIdleWork: [() -> Void] = []

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
        config: ConfigCache, history: HistoryStore?, replacementUsage: ReplacementUsageStore? = nil,
        hud: HUDPresenting?,
        permits: @escaping @Sendable (Connection) -> Bool,
        audio: AudioCapturing? = nil,
        presenceDetector: SpeechPresenceDetecting? = nil,
        effects: DuringDictationEffects? = nil,
        insert: @escaping (InsertionDecision, Mode.Insertion, ClipboardPaste, String, Bool) async -> Bool = TextInserter.perform,
        submitKey: @escaping (Mode.Submit) async -> Void = TextInserter.submit,
        captureSelection: @escaping (ClipboardKeystroke) async -> String? = { await TextInserter.captureSelection(keystroke: $0) },
        clipboard: @escaping @MainActor () -> String? = TextInserter.currentClipboardText,
        agentClipboard: AgentClipboard = AgentClipboard(),
        pressSnapshot: (@MainActor () -> TargetSnapshot)? = nil,
        snapshot: @escaping @MainActor () -> TargetSnapshot = { ContextProbe.snapshot() },
        snapshotAsync: (@MainActor () async -> TargetSnapshot)? = nil,
        micStatus: @escaping @MainActor () -> PermissionStatus = { Permissions.microphoneStatus() },
        accessibilityGranted: @escaping @MainActor () -> Bool = { Permissions.accessibilityStatus() == .granted },
        prefetchClipboard: @escaping @MainActor () -> Void = {},
        discardPrefetchedClipboard: @escaping @MainActor () -> Void = {},
        frontmostBundleId: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        precedingTextProbe: @escaping @MainActor (pid_t, String?) async -> String? = { await ContextProbe.precedingText(pid: $0, windowId: $1) },
        activeEngineUsable: @escaping @MainActor (any SpeechEngine) -> Bool = { engine in
            InstalledEngineFilter.shouldRun(engineId: engine.id)
        },
        isSessionLocked: @escaping @MainActor () -> Bool = { SessionLockMonitor.isSessionLocked() },
        llmClient: any LLMClient = HTTPLLMClient(),
        voiceCommands: VoiceCommandRunning? = nil,
        recordModelLoadFailure: @escaping @MainActor (String, Bool, String) -> Void = {
            ModelLoadDiagnosticsWriter.record(engineId: $0, timedOut: $1, error: $2)
        },
        maxRecordingSeconds: Double = RecordingLimit.backstopSeconds,
        modelRecordingLimit: @escaping (String) -> Double? = RecordingLimit.modelLimit(engineId:),
        limitWarningSeconds: Double = 30,
        warmupClip: URL? = EngineKeeper.bundledWarmupClip,
        silencer: SpeechSilencer = .shared
    ) {
        self.silencer = silencer
        self.settings = settings
        self.provider = provider
        self.config = config
        self.reporter = TakeReporter(history: history, replacementUsage: replacementUsage)
        self.inserter = InsertOutput(
            snapshotAsync: snapshotAsync ?? { snapshot() }, accessibilityGranted: accessibilityGranted,
            insert: insert, submitKey: submitKey)
        self.hud = HUDChannel(hud: hud)
        self.agentOutput = AgentOutput(hud: self.hud, reporter: self.reporter)
        self.audio = audio ?? AudioCapture()
        self.presenceDetector = presenceDetector ?? SpeechPresenceDetector(modelsDir: KeyScribePaths.modelsDir)
        self.effects = effects ?? DuringDictationEffects()
        self.insert = insert
        self.submitKey = submitKey
        self.captureSelection = captureSelection
        self.clipboard = clipboard
        self.agentClipboard = agentClipboard
        self.pressSnapshot = pressSnapshot ?? snapshot
        self.shouldAdoptFullSnapshot = pressSnapshot != nil
        self.snapshotAsync = snapshotAsync ?? { snapshot() }
        self.micStatus = micStatus
        self.accessibilityGranted = accessibilityGranted
        self.frontmostBundleId = frontmostBundleId
        self.precedingTextProbe = precedingTextProbe
        self.prefetchClipboard = prefetchClipboard
        self.discardPrefetchedClipboard = discardPrefetchedClipboard
        self.activeEngineUsable = activeEngineUsable
        self.isSessionLocked = isSessionLocked
        self.llmClient = llmClient
        self.rewriter = TakeRewrite(client: llmClient, permits: permits, hud: self.hud)
        self.voiceCommands = voiceCommands ?? VoiceCommandRunner(findsInApps: { config.findsInAppsEnabled })
        self.commandOutput = VoiceCommandOutput(runner: self.voiceCommands, hud: self.hud, reporter: self.reporter)
        self.agentTake = AgentTake(
            hud: self.hud, output: self.agentOutput, voiceCommands: self.voiceCommands, submitKey: submitKey,
            snapshotAsync: self.snapshotAsync, agentClipboard: agentClipboard)
        self.permits = permits
        self.recordModelLoadFailure = recordModelLoadFailure
        self.maxRecordingSeconds = maxRecordingSeconds
        self.modelRecordingLimit = modelRecordingLimit
        self.limitWarningSeconds = limitWarningSeconds
        self.engines = EngineKeeper(warmupClip: warmupClip)
        self.audio.setPreferredInputUID(settings.audio.inputDeviceUID)
        installMemoryPressureHandler()
        self.voiceCommands.onProgress = { [weak self] progress in self?.showCommandProgress(progress) }
        self.hud.onDraw = { [weak self] state in
            if state.spokenHelp == nil { self?.help.release() }
        }
        self.hud.choices = { [weak self] in
            HUDChannel.Choices(answering: self?.answeringChoicePrompt, pending: self?.pendingVoiceCommandChoice)
        }
        reporter.onHistoryUpdated = { [weak self] in self?.onHistoryUpdated?() }
        agentOutput.keepsHistory = { [weak self] in self?.settings.history.enabled ?? false }
        agentOutput.noticesBlocked = { [weak self] in self.map { $0.machine.isBusy || $0.voiceCommands.pendingChoice != nil } ?? false }
        agentOutput.hide = { [weak self] in self?.scheduleHide(after: $0) }
        commandOutput.host = self
        agentTake.host = self
        engines.host = self
    }

    private func showCommandProgress(_ progress: VoiceCommandProgress) {
        guard machine.state == .inserting else { return }
        hud.present(.transcribing(mode: currentModeName, status: progress.text))
    }

    // Record loss here; every terminal handles it at insertion. A stale report must not affect a successor.
    private func handleCaptureLost(identity: DictationIdentity?) {
        guard let identity, let current = session?.identity, current === identity else { return }
        captureTruncated = true
        switch machine.state {
        case .recording:
            // A tap-to-toggle user may never release; commit the available prefix now.
            handleCommit()
        case .arming:
            if session?.pendingPress != nil {
                cancelBeforeCaptureStarted()
                return
            }
            // Arming has no audio; report the microphone failure instead of a silent early release.
            cancelBeforeCaptureStarted()
            finishTruncatedCapture(transcript: "")
        default:
            break
        }
    }

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.onMemoryPressure?()
                guard let self, !self.isBusy else { return }
                let active = self.provider.active
                self.log.notice("memory pressure (critical): evicting \(active.id, privacy: .public)")
                self.engines.evictUnderMemoryPressure(active)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func updateSettings(_ settings: Settings) {
        let previousEviction = self.settings.stt.eviction
        let previousOtherAudio = self.settings.duringDictation.otherAudio
        self.settings = settings
        if settings.duringDictation.otherAudio != previousOtherAudio { effects.otherAudioChanged(settings.duringDictation.otherAudio) }
        if !settings.features.isEnabled(.voiceCommands) { stopVoiceCommandChoice() }
        if !settings.features.isEnabled(.codingAgents) { StopGate.closeAll() }
        audio.setPreferredInputUID(settings.audio.inputDeviceUID)
        engines.rescheduleIdleEviction()
        if settings.stt.eviction != previousEviction { reconcileCaptureWarmth() }
    }

    func previewStartCue(volumePercent: Int) {
        guard !isBusy else { return }
        effects.previewStartCue(volumePercent: volumePercent)
    }

    func lowerOtherAudioForSpeech(_ lower: Bool) {
        if lower { effects.speechStarted(settings.duringDictation.otherAudio) } else { effects.speechEnded() }
    }

    private func reconcileCaptureWarmth() {
        guard !isBusy else { return }
        if EvictionPolicy.shouldPrewarmCapture(mode: settings.stt.eviction) {
            prewarmCapture()
        } else {
            captureRefreshTask?.cancel()
            audio.releaseWarm()
        }
    }

    func evictSwitchedAwayEngine(_ engine: any SpeechEngine) { engines.evictSwitchedAway(engine) }

    func evictEngineForSettings(_ engine: any SpeechEngine) async { await engines.evictForSettings(engine) }

    func selfTestForSettings(_ engine: any SpeechEngine) async -> Bool? {
        guard !isBusy else { return nil }
        return await engines.selfTest(engine, gate: transcriber.gate)
    }

    var checkStallSeconds: Double = 10

    private func awaitSelfTestClearance() async {
        let gate = transcriber.gate
        guard await engines.checkHolds(gate) else { return await engines.awaitSelfTestClearance(on: gate) }
        let mode = currentModeName
        hud.present(.waitingForCheck(mode: mode, stalled: false))
        let stall = checkStallSeconds
        let stalled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(stall * 1000)))
            guard !Task.isCancelled else { return }
            self?.hud.present(.waitingForCheck(mode: mode, stalled: true))
        }
        await engines.awaitSelfTestClearance(on: gate)
        stalled.cancel()
        if !Task.isCancelled { hud.present(.transcribing(mode: mode)) }
    }

    func listenToSpokenReply(wav: URL) async -> EngineKeeper.Listening {
        guard !isBusy else { return .busy }
        return await engines.listen(activeEngine, wav: wav, gate: transcriber.gate)
    }

    private func warmActiveEngine() {
        engines.warm(activeEngine)
    }

    private func prepareActiveEngineForDictation() {
        let engine = activeEngine
        Task { await engine.prepareForDictation() }
    }

    static func warmupBiasTerms(settings: Settings, engine: any SpeechEngine, plan: ResolvedConfig) -> [String] {
        EngineKeeper.warmupBiasTerms(settings: settings, engine: engine, plan: plan)
    }

    func preloadActiveEngineIfNeeded() {
        let engine = activeEngine
        guard InstalledEngineFilter.shouldRun(engineId: engine.id) else { return }
        prewarmPresenceDetector()
        engines.preload(engine)
    }

    private func prewarmPresenceDetector() {
        let detector = presenceDetector
        Task { await detector.prewarm() }
    }

    func prewarmCues() {
        effects.prewarm()
    }

    func prewarmCapture() {
        guard micStatus() == .granted,
              EvictionPolicy.shouldPrewarmCapture(mode: settings.stt.eviction) else { return }
        audio.prewarm()
        scheduleCaptureRefresh()
    }

    func refreshCaptureBinding() {
        guard micStatus() == .granted, !isBusy,
              EvictionPolicy.shouldPrewarmCapture(mode: settings.stt.eviction) else { return }
        audio.refreshBinding()
        scheduleCaptureRefresh()
    }

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
            // Prewarming outside dictation has no eviction task, so schedule a release for Balanced mode.
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

    func acknowledgeNextMode() {
        guard !isBusy, let name = nextModeOverrideName else { return }
        dismissVoiceCommandChoice()
        hud.present(.ready(mode: name))
        scheduleHide()
    }

    func announceConfigProblems(_ issues: [ConfigFileIssue]) {
        guard !isBusy, !issues.isEmpty else { return }
        let message = issues.map(\.oneLine).joined(separator: " · ")
        hud.present(issues.contains(where: \.isError) ? .error(message: message, action: nil) : .advisory(message: message))
        scheduleHide(after: 8)
    }

    private var settingsReplacedPending = false

    private func announceSettingsReplacedOnceHidden() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.settingsReplacedPending, !self.isBusy,
                  (self.hud.lastPresented ?? .hidden) == .hidden else { return }
            self.announceSettingsReplaced()
        }
    }

    func announceSettingsReplaced() {
        guard !isBusy else { return settingsReplacedPending = true }
        settingsReplacedPending = false
        hud.present(.advisory(message: HUDState.settingsReplaced))
        scheduleHide(after: 8)
    }

    var pressConfirmationBackstop: Duration = .seconds(1)
    lazy var help = HelpPresenter(escape: EscapeClaim()) { [weak self] in self?.hud.present(.hidden) }
    var runningAppNames: () -> [String] = {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName)
    }

    func handleEngage(triggerKey: String?) {
        guard !isSessionLocked(), machine.state == .idle, micStatus() != .denied, !audio.inputIsBluetooth else { return }
        let engine = provider.active
        guard activeEngineUsable(engine), machine.beginArming() else { return }
        engines.cancelIdleEviction()
        captureRefreshTask?.cancel()
        if !replayingKeys { keysTakenByHUD = [] }
        let pending = PendingPress()
        session = DictationSession(voiceCommandStopsAtPress: commandOutput.stops, building: DictationRecord(modeName: currentModeName))
        session?.pendingPress = pending
        session?.capturedEngine = engine
        engines.protect(engine)
        beginCapture()
        pending.backstop = Task { @MainActor [weak self, backstop = pressConfirmationBackstop] in
            try? await Task.sleep(for: backstop)
            guard !Task.isCancelled else { return }
            self?.dropUnconfirmedPress()
        }
    }

    func handleEngageDropped(triggerKey: String?) {
        dropUnconfirmedPress()
    }

    private func dropUnconfirmedPress() {
        guard session?.pendingPress != nil, machine.state == .arming else { return }
        cancelBeforeCaptureStarted()
    }

    private struct DeferredPress {
        let triggerKey: String?
        let pressStyle: PressStyle
        let pressedAt: DispatchTime?
        var released = false
    }
    private var droppingPress = false
    private var deferredPress: DeferredPress?

    func handleStart(
        triggerKey: String? = nil, pressStyle: PressStyle = .holdOrTap, pressedAt: DispatchTime? = nil
    ) {
        // A wake key can reach the tap while the login window still owns the console.
        guard !isSessionLocked() else { return }
        onPress?()
        if droppingPress, machine.state == .cancellingBringUp {
            deferredPress = DeferredPress(triggerKey: triggerKey, pressStyle: pressStyle, pressedAt: pressedAt)
            return
        }
        let engaged = machine.state == .arming ? session?.pendingPress : nil
        if engaged == nil {
            guard machine.beginArming() else {
                if pressStyle == .startOnly { return }
                if case .rewriting(_, _, _, _, true, _)? = hud.lastPresented {
                    insertLocalTranscriptNow()
                } else {
                    playBusyPressCue()
                }
                return
            }
        }
        dictationStarts += 1
        if !replayingKeys { keysTakenByHUD = [] }
        effects.pressBegan()
        answers?.close()
        silencer.recordingStarted()
        activeStartTrigger = triggerKey
        hud.setKeyFocusFree(pressStyle == .doubleTap)
        latchedTriggerName = [.tapToToggle, .doubleTap].contains(pressStyle)
            ? triggerKey.flatMap { try? KeyDescriptor(parsing: $0) }?.displayString : nil
        hideTask?.cancel()
        help.release()
        if let engaged {
            session?.pendingPress = nil
            session?.voiceCommandStopsAtPress = commandOutput.stops
            engaged.backstop?.cancel()
        } else {
            engines.cancelIdleEviction()
            captureRefreshTask?.cancel()
            session = DictationSession(voiceCommandStopsAtPress: commandOutput.stops, building: DictationRecord(modeName: currentModeName))
        }
        if let pressedAt {
            session?.pressedAt = pressedAt
            building.stageMillis[.grace] = elapsedMs(since: pressedAt)
        }
        let engine: any SpeechEngine
        if engaged != nil, let captured = session?.capturedEngine {
            engine = captured
        } else {
            // A denied mic captures silence without throwing, so diagnose permission before starting.
            if micStatus() == .denied {
                finishError("Microphone access is off", action: .openMicrophoneSettings)
                return
            }
            engine = provider.active
            guard activeEngineUsable(engine) else {
                finishError("The selected speech model is not installed", action: .openSpeechModels)
                return
            }
            session?.capturedEngine = engine
            engines.protect(engine)
            // The mic comes up while the probe and mode resolution below run. Audio never leaves the machine,
            // so nothing here needs the secure-field verdict first: everything content-bearing (preconnect,
            // context, rewrite, history) waits for snapshot adoption. A press no mode can serve now opens the
            // mic briefly and tears it down without a cue.
            beginCapture()
        }
        engaged?.confirmed.signal()

        // Capture secure-field state at press before any asynchronous work can change the target.
        let snapshotStart = DispatchTime.now()
        capturedSnapshot = pressSnapshot()
        Log.context.debug("press snapshot=\(self.elapsedMs(since: snapshotStart), privacy: .public)ms")
        adoptFullSnapshot()
        building.targetBundleId = capturedSnapshot?.bundleId
        session?.capturedPlan = config.resolved
        session?.replacementUsageEpoch = reporter.usageEpoch()
        session?.capturedRecognitionBias = settings.stt.recognitionBiasEnabled(
            engineId: engine.id, supportsRecognitionBias: engine.supportsRecognitionBias)

        // Probe only eligible modes: URL and window lookups can defer the decision past capture.
        let probeCandidates = self.probeCandidates()
        if ModeResolver.requiresURLContext(probeCandidates)
            || ModeResolver.requiresWindowTitleContext(probeCandidates) {
            session?.modeResolveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.resolveModeProbing(triggerKey: triggerKey)
                guard !Task.isCancelled else { return }
                // A late resolution must not show the HUD before the cue has played.
                if self.machine.state == .recording {
                    self.hud.present(self.recordingHUD(level: max(0, self.lastRenderedLevel)))
                } else if self.machine.state == .transcribing {
                    self.renameTranscribingHUD()
                }
            }
        } else {
            session?.modeResolveTask = nil
            applyResolvedMode(triggerKey: triggerKey, url: nil, windowTitle: nil)
            // An unclaimed press has already been cancelled; nothing more to prepare.
            guard machine.state == .arming else { return }
        }

        // Keep the HUD hidden until the cue has played; showing it earlier invites speech before the mic is live.
        hud.present(.hidden)

        warmActiveEngine()
        prepareActiveEngineForDictation()
        prewarmPresenceDetector()
    }

    private func playBusyPressCue() {
        guard !machine.isCapturingAudio else { return }
        log.notice("trigger ignored — \(String(describing: self.machine.state), privacy: .public) still in flight")
        effects.alert(settings.duringDictation, cue: .error)
    }

    private func adoptFullSnapshot() {
        guard shouldAdoptFullSnapshot else { markSnapshotReady(); return }
        let capturedBundle = capturedSnapshot?.bundleId
        let capturedPid = capturedSnapshot?.pid
        session?.snapshotAdoptionTask?.cancel()
        session?.snapshotAdoptionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled,
                  self.capturedSnapshot?.bundleId == capturedBundle,
                  self.capturedSnapshot?.pid == capturedPid else { return }
            let full = await self.snapshotAsync()
            guard !Task.isCancelled,
                  self.capturedSnapshot?.bundleId == capturedBundle,
                  self.capturedSnapshot?.pid == capturedPid else { return }
            guard let adopted = PressResolver.adoption(
                of: full, capturedBundle: capturedBundle, capturedPid: capturedPid,
                capturedSecure: self.capturedSnapshot?.isSecureField ?? false)
            else {
                self.session?.targetUnconfirmed = true
                self.activeMode = self.securePolicyApplied(self.activeMode)
                return   // leave the gate closed: no preconnect, no context probe
            }
            self.capturedSnapshot = adopted
            self.building.targetBundleId = adopted.bundleId
            self.activeMode = self.securePolicyApplied(self.activeMode)
            self.markSnapshotReady()
        }
    }

    private func beginCapture() {
        lastRenderedLevel = 0
        levelTicks = 0
        tickedCountdown = nil
        captureTruncated = false
        // Bound to THIS dictation's identity and installed before arming, so AudioCapture snapshots it into
        // the session it belongs to. Without that, the main-actor hop below could deliver a dead capture's
        // loss to whichever dictation happens to be running when it lands.
        let identity = session?.identity
        let lossFlag = session?.captureLoss
        audio.setCaptureLostHandler { [weak self] in
            // Record synchronously FIRST, into THIS dictation's own flag: the hop below is what updates HUD
            // and state, but actuation may run before it lands and must still see the loss.
            lossFlag?.markLost()
            Task { @MainActor in self?.handleCaptureLost(identity: identity) }
        }
        let sampleRate = activeEngine.captureSampleRate
        let wantsSamples = activeEngine.supportsSampleInput
        // Detached so bring-up starts NOW, while the caller still holds the main actor for the press probe and
        // mode resolution. A main-actor task would not begin until handleStart returned.
        let starting = Task.detached(priority: .userInitiated) { [audio] in
            try await audio.start(sampleRate: sampleRate, wantsSamples: wantsSamples)
        }
        captureBringUpTask = Task { @MainActor [weak self] in
            guard let self else { starting.cancel(); return }
            do {
                // Resolves on the input's first delivered buffer, not on the AudioUnit start returning: a
                // Bluetooth route that binds and starts but never delivers must not read as a live mic.
                _ = try await withTaskCancellationHandler {
                    try await starting.value
                } onCancel: {
                    starting.cancel()
                }
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
                if let pending = self.session?.pendingPress {
                    pending.backstop?.cancel()
                    self.session?.pendingPress = nil
                    self.finishCanceledBringUp(stopAudio: false)
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
            if let pending = self.session?.pendingPress { await pending.confirmed.wait() }
            // Released or cancelled while the mic was coming up: nothing to record, so tear the capture
            // back down and bail.
            guard !Task.isCancelled, self.machine.state == .arming else {
                self.finishCanceledBringUp(stopAudio: true)
                return
            }
            // The mic is live, so the cue can honestly invite speech. The mic has been recording since its first
            // buffer and the cue stays in the recording: cutting it out would also cut the speech under it, which
            // costs more words than the cue does.
            self.session?.effectsBegan = true
            let cueSeconds = self.effects.begin(self.settings.duringDictation)
            let hold = cueSeconds > 0 ? cueSeconds + Self.cueTailPadSeconds : 0
            // Hold "Listening" and the duck until the cue actually ends, so the HUD never precedes the go-signal
            // and the mute never swallows it.
            if hold > 0 {
                try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
                guard !Task.isCancelled, self.machine.state == .arming else {
                    self.finishCanceledBringUp(stopAudio: true)
                    return
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
            self.hud.present(self.recordingHUD(level: 0))
        }
    }

    private func startRecordingLimit() {
        let limit = RecordingLimit.seconds(backstop: maxRecordingSeconds, modelLimit: modelRecordingLimit(activeEngine.id))
        session?.recorder.startLimit(
            seconds: limit, stillRecording: { [weak self] in self?.machine.state == .recording },
            reached: { [weak self] in self?.commitAtRecordingLimit() })
    }

    private func commitAtRecordingLimit() {
        session?.stoppedAtLimit = true
        building.stoppedAtLimit = true
        log.notice("recording limit reached after \(self.recordingLimitSeconds, privacy: .public)s — committing the take")
        handleCommit()
    }

    private var recordingLimitSeconds: Double { session?.recorder.limitSeconds ?? maxRecordingSeconds }
    var limitPhrase: String { RecordingLimit.phrase(seconds: recordingLimitSeconds) }

    static let rewriteSkippedAtLimitReason = "The recording limit stopped this dictation, so the rewrite was skipped."

    // Release the frozen config at a terminal so an idle app doesn't pin a stale ResolvedConfig after a
    // reload. `plan` falls back to live `config.resolved` while nil, so clearing between dictations is safe.
    private func releaseCapturedPlan() {
        // Cancel the per-dictation tasks first (dropping the session only releases the references, it does
        // not cancel the Tasks), then drop the whole session as a unit — every captured*/activeMode/
        // routing/building field resets structurally, so none can leak into the next dictation.
        session?.modeResolveTask?.cancel()
        session?.snapshotAdoptionTask?.cancel()
        captureBringUpTask?.cancel()
        session?.rewriteEscapeTask?.cancel()
        session?.precedingTextTask?.cancel()
        session?.agentFrontTask?.cancel()
        session?.recorder.tearDown()
        engines.releaseProtection()
        discardPrefetchedClipboard()
        session = nil
        activeStartTrigger = nil
        scheduleCaptureRefresh()
        onBecameIdle?()
        if settingsReplacedPending { announceSettingsReplacedOnceHidden() }
        // The dictation is fully terminal (reload + transcribe + insert are done), so any deferred idle
        // work — e.g. a Settings model-file deletion parked while this dictation ran — is now safe.
        drainIdleWork()
    }

    func handleCommit() {
        if deferredPress != nil {
            deferredPress?.released = true
            return
        }
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
        session?.recorder.stopLimit()
        session?.releasedAt = .now()
        session?.agentFrontCutoff = .now + frontReadingGrace
        onRecordingChanged?(false)
        machine.beginTranscribing()
        // Flip the HUD to transcribing now so the tail-drain (commit-on-release flush, ~one buffer) is
        // invisible; finishDraining keeps the engine running just long enough to capture the final word.
        hud.present(.transcribing(mode: currentModeName))
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
            // instead of re-reading/decoding the WAV. The WAV stays on disk for archive/probe/fallback.
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
            let reading = await self.presenceReading(samples: samples, url: url)
            if reading.presence == .noSpeech {
                try? FileManager.default.removeItem(at: url)
                if Task.isCancelled { return }
                // A take whose mic died before any speech landed reads as silence here. "No speech detected"
                // would blame the user for a hardware failure, so the real cause wins.
                if self.captureWasLost {
                    self.finishTruncatedCapture(transcript: "")
                    return
                }
                // Two-state no-speech: nothing-heard (peak never cleared the silence floor — a muted/dead
                // mic) gets the error+repair render; real audio with no speech keeps the neutral "No speech
                // detected". Both record the .noSpeech outcome identically.
                if SpeechPresenceGate.isNothingHeard(peak: reading.peak) {
                    self.finishNothingHeard()
                } else {
                    self.finishNoSpeech()
                }
                return
            }
            await self.transcribeAndInsert(url: url, audioSeconds: audioSeconds, samples: samples, reading: reading)
        }
    }

    // The take's VAD reading. A noSpeech verdict ends the dictation here (the caller splits nothing-heard vs
    // no-speech on the peak); a speech verdict carries through to transcription, where its speech-start
    // evidence drives the empty-transcript recovery.
    private func presenceReading(samples: [Float]?, url: URL) async -> SpeechPresenceReading {
        let reading = await presenceDetector.read(
            samples: samples, url: url, sampleRate: activeEngine.captureSampleRate)
        // clearing/chunks is the axis admission actually keys on — maxP alone cannot explain a suppression
        // (a stray press scores as high as 0.92 on its one hot chunk).
        let clearing = SpeechPresenceGate.chunksClearingGate(reading.chunkProbabilities)
        Log.audio.debug("vad \(reading.presence.rawValue, privacy: .public) clearing=\(clearing, privacy: .public)/\(reading.chunkProbabilities.count, privacy: .public) need=\(SpeechPresenceGate.minSpeechChunks, privacy: .public) maxP=\(reading.maxProbability, privacy: .public) peak=\(reading.peak, privacy: .public) model=\(reading.modelUsed, privacy: .public) speechStart=\(reading.speechStart ?? -1, privacy: .public) \(reading.latencyMs, privacy: .public)ms")
        return reading
    }

    private func finishVoiceCommand(heard: String) async {
        guard settings.features.isEnabled(.voiceCommands) else {
            finishError("Voice commands are turned off.")
            return
        }
        if captureWasLost {
            finishCommandCaptureLost()
            return
        }
        guard heard.contains(where: { !$0.isWhitespace }) else {
            finishNoSpeech()
            return
        }
        let excerpt = targetMayHoldSecureText ? nil : HeardExcerpt(heard: heard)
        let origin = capturedSnapshot.flatMap(Self.origin)
        let start = DispatchTime.now()
        let commands = config.voiceCommands
        let reading = plan.voiceCommandReading(
            heard: heard, mode: activeMode, places: commands.places, scripts: commands.scripts)
        let transcript = reading.text
        let late = VoiceCommandOutput.LateResult()
        let stopsAtStart = session?.voiceCommandStopsAtPress
        // Lookup stays cancellable (still transcribing); the first check that passes is where acting begins.
        let lease = lease(for: .voiceCommands, stopsAtPress: stopsAtStart)
        let stillWanted: @MainActor () -> Bool = { lease.keepActing() }
        let onLateResult: @MainActor (VoiceCommandOutcome) -> Void = { [weak self] outcome in
            late.outcome = outcome
            self?.commandOutput.applyLateResult(late)
        }
        let reply: VoiceCommandAnswer
        if let id = session?.choiceId {
            reply = await voiceCommands.answer(
                transcript, choice: id, places: commands.places, scripts: commands.scripts, origin: origin,
                stillWanted: stillWanted, onLateResult: onLateResult)
        } else {
            reply = .command(await voiceCommands.run(
                transcript: transcript, places: commands.places, scripts: commands.scripts, origin: origin,
                stillWanted: stillWanted, onLateResult: onLateResult))
        }
        if Task.isCancelled { return }
        if !reading.firedReplacements.isEmpty, VoiceCommandOutput.ranACommand(reply) {
            reporter.recordUsage(reading.firedReplacements, capturedAt: session?.replacementUsageEpoch)
        }
        building.stageMillis[.insert] = elapsedMs(since: start)
        if voiceCommands.pendingChoice == nil { commandOutput.clear() }
        switch reply {
        case .command(let outcome):
            finishCommand(outcome, heard: heard, transcript: transcript, late: late, excerpt: excerpt)
        case .selected(let selection):
            finishCommand(selection.outcome, heard: heard, transcript: transcript, late: late,
                          resultPrefix: VoiceCommandOutput.selectionPrefix(selection))
        case .cancelled(let request):
            finish(machine: .finish(.inserted), cue: .cancel, state: .hidden, record: (.command, nil),
                   history: HistoryWrite(heard: heard, transformed: transcript,
                                         result: "Cancelled the choice for \u{201C}\(request)\u{201D}.", insertion: .inserted,
                                         rewrite: nil, outcome: .commandCancelled))
        case .retry(let message, let reason):
            let shown = reason == .unrecognizedAnswer ? excerpt : nil
            let status: VoiceCommandChoiceStatus = shown.map { .waiting(note: nil, heard: $0) } ?? .waiting(note: message)
            let state: HUDState = commandOutput.prompt.map { .choice($0, status: status) } ?? .error(message: message, action: nil)
            finish(machine: .finish(.inserted), cue: nil, endsQuietly: true, state: state,
                   hideAfter: commandOutput.prompt == nil ? 3 : nil, record: (.command, nil),
                   history: HistoryWrite(heard: heard, transformed: transcript, result: message, insertion: .inserted,
                                         rewrite: nil, outcome: .commandNeedsChoice))
        }
    }

    static func origin(of snapshot: TargetSnapshot) -> VoiceCommandOrigin? {
        snapshot.bundleId.map { VoiceCommandOrigin(bundleId: $0, pid: snapshot.pid, windowId: snapshot.focusedWindowId) }
    }

    private func finishCommand(
        _ outcome: VoiceCommandOutcome, heard: String, transcript: String, late: VoiceCommandOutput.LateResult, resultPrefix: String = "",
        excerpt: HeardExcerpt? = nil
    ) {
        if let shown = VoiceCommandOutput.presentation(of: outcome, resultPrefix: resultPrefix, excerpt: excerpt) {
            let failed = shown.failure != nil
            var write = HistoryWrite(heard: heard, transformed: transcript, result: shown.result,
                                     insertion: failed ? .failed : .inserted, rewrite: nil, failureReason: shown.failure,
                                     reported: shown.reported, outcome: shown.outcome)
            let started = shown.outcome == .commandStarted
            if started {
                write.onRecorded = { [weak self] entry in
                    late.entry = entry
                    self?.commandOutput.applyLateResult(late)
                }
            }
            finish(machine: .finish(failed ? .failed : .inserted), cue: shown.cue, state: shown.state,
                   hideAfter: shown.hideAfter, record: failed ? (.failed, "voice command did not run") : (.command, nil),
                   history: write)
            if started {
                late.started = true
                commandOutput.applyLateResult(late)
            }
            return
        }
        switch outcome {
        case .done, .started, .failed:
            break
        case .cancelled:
            finish(machine: .finish(.noSpeech), cue: .cancel, state: .advisory(message: VoiceCommandRunner.cancelledMessage),
                   hideAfter: 2, record: (.noSpeech, nil))
        case .abandoned:
            if captureWasLost {
                finishCommandCaptureLost()
            } else if machine.isBusy {
                finish(machine: .cancel, cue: .cancel, state: .hidden)
            }
        case .needsChoice(let pending):
            let prompt = commandOutput.offer(pending)
            let rows = pending.rows.map { "\($0.number). \($0.name)" }.joined(separator: ", ")
            var write = HistoryWrite(heard: heard, transformed: transcript, result: "Asked to choose: \(rows)",
                                     insertion: .inserted, rewrite: nil, outcome: .commandNeedsChoice)
            write.onRecorded = { [weak self] entry in
                self?.commandOutput.noteAsked(entry, choice: pending.id)
            }
            finish(machine: .finish(.inserted), cue: nil, endsQuietly: true,
                   state: .choice(prompt, status: .waiting(note: nil)), record: (.command, nil), history: write)
            commandOutput.scheduleExpiry(pending.id)
        }
    }

    private var answeringChoicePrompt: VoiceCommandChoicePrompt? {
        if session != nil, session?.modeReady != true, let prompt = pendingVoiceCommandChoice { return prompt }
        guard let id = session?.choiceId, let prompt = commandOutput.prompt, prompt.id == id,
              voiceCommands.pendingChoice?.id == id else { return nil }
        return prompt
    }

    private func claimOrDismissVoiceCommandChoice() {
        guard voiceCommands.pendingChoice != nil else { return }
        guard activeMode?.runsVoiceCommands == true, settings.features.isEnabled(.voiceCommands) else {
            dismissVoiceCommandChoice()
            return
        }
        commandOutput.pauseExpiry()
        session?.choiceId = voiceCommands.claimChoice()
        if session?.choiceId == nil { dismissVoiceCommandChoice() }
    }

    var choiceExpirySleep: @MainActor (Double) async -> Void {
        get { commandOutput.expirySleep }
        set { commandOutput.expirySleep = newValue }
    }

    var pendingVoiceCommandChoice: VoiceCommandChoicePrompt? { commandOutput.pendingPrompt }

    func dismissVoiceCommandChoice() { commandOutput.dismiss() }

    private func stopVoiceCommandChoice() { commandOutput.stop() }

    func noteAppActivated(bundleId: String) { commandOutput.noteAppActivated(bundleId: bundleId) }

    func voiceCommandConfigurationChanged() { commandOutput.configurationChanged() }

    func chooseVoiceCommand(choice id: Int, candidate identity: String) {
        commandOutput.choose(choice: id, candidate: identity)
    }

    func cancelVoiceCommandChoice(choice id: Int) { commandOutput.cancel(choice: id) }

    func finishCommandCaptureLost() {
        log.error("capture lost mid-recording — voice command not run")
        finish(machine: .finish(.failed), cue: .error,
               state: .error(message: "The microphone stopped, so the command did not run.", action: nil),
               hideAfter: 8, record: (.failed, "capture lost mid-recording"))
    }

    func finishNoSpeech() {
        guard machine.beginInserting() else { return }
        hud.relinquishKeyFocus()
        let completion = DictationCompletion(
            outcome: .noSpeech, modeId: activeMode?.id, heard: "", finalText: "")
        finish(machine: .finish(.noSpeech), cue: .cancel,
               state: .complete(outcome: .noSpeech, mode: currentModeName),
               hideAfter: 2, record: (.noSpeech, nil), completion: completion)
    }

    // The user threw the take away by voice: nothing is inserted or kept in History, like a cancel.
    func finishDiscarded(message: String = discardedMessage) {
        guard machine.beginInserting() else { return }
        hud.relinquishKeyFocus()
        let completion = DictationCompletion(
            outcome: .noSpeech, modeId: activeMode?.id, heard: "", finalText: "")
        finish(machine: .finish(.noSpeech), cue: .cancel,
               state: .advisory(message: message),
               hideAfter: 2, record: (.noSpeech, nil), completion: completion)
    }

    static let discardedMessage = "Discarded: nothing was inserted"

    // Nothing was heard — a hardware/mute problem. Renders like an error with the microphone-settings repair
    // (longer hide, action button) but records the same .noSpeech outcome as finishNoSpeech.
    private func finishNothingHeard() {
        guard machine.beginInserting() else { return }
        hud.relinquishKeyFocus()
        let completion = DictationCompletion(
            outcome: .noSpeech, modeId: activeMode?.id, heard: "", finalText: "")
        finish(machine: .finish(.noSpeech), cue: .error,
               state: .error(message: "Nothing heard — check your microphone", action: .openMicrophoneSettings),
               hideAfter: 8, record: (.noSpeech, nil), completion: completion)
    }

    // VAD heard speech but the speech model returned no text. Names the model instead of claiming silence —
    // there is no user repair for an engine failure, so no action button. Records .noSpeech like the other
    // no-text terminals (the finishNothingHeard pattern): honest HUD copy, untouched history semantics.
    private func finishHeardButNoText(engine: any SpeechEngine) {
        // A take cut short by its microphone can also transcribe to nothing. Blaming the speech model would
        // point the user at the one thing that did not fail.
        if captureWasLost {
            finishTruncatedCapture(transcript: "")
            return
        }
        guard machine.beginInserting() else { return }
        hud.relinquishKeyFocus()
        let completion = DictationCompletion(
            outcome: .noSpeech, modeId: activeMode?.id, heard: "", finalText: "")
        finish(machine: .finish(.noSpeech), cue: .error,
               state: .error(message: "Heard speech, but \(engine.displayName) returned no text", action: nil),
               hideAfter: 8, record: (.noSpeech, nil), completion: completion)
    }

    // The pressed key belongs only to modes that cannot run here, and the Direct floor does not own it
    // either — so this press was never ours to serve.
    //
    // The mic is already coming up (beginCapture runs before resolution). If the start cue has not played,
    // tear it down silently: no cue, no HUD, like the chord grace discarding a pending arm. Once it has
    // played — a URL/window-title probe can land after the cue — cancel audibly so the go-signal is answered.
    // The probe is bounded at 0.6s and usually returns before the cue; what the mic heard is discarded.
    // `.cancel`, not `.error`: nothing is wrong, the key just does not apply here.
    private func abortPressWithNoEligibleMode() {
        log.notice(
            "press ignored — no mode for \(self.activeStartTrigger ?? "(none)", privacy: .public) here")
        guard captureBringUpTask != nil else {
            finish(machine: .cancel, cue: nil, state: .hidden)
            return
        }
        if machine.state == .arming, session?.effectsBegan != true {
            cancelBeforeCaptureStarted(silently: true)
            return
        }
        cancel()
    }

    private func cancelBeforeCaptureStarted(silently: Bool = false) {
        let unconfirmed = session?.pendingPress
        session?.pendingPress = nil
        unconfirmed?.backstop?.cancel()
        defer { unconfirmed?.confirmed.signal() }
        let silently = silently || unconfirmed != nil
        // Release/ESC during the cue is a release during bring-up (the unit comes up under the cue). Cancel
        // the bring-up task so a fast bring-up sitting in the cue-end hold wakes at once (its guards see
        // `.isCancelled` and tear the mic down) rather than staying live until the hold expires. The task's
        // completion still runs finishCanceledBringUp.
        let waitForBringUpCleanup = captureBringUpTask != nil
        captureBringUpTask?.cancel()
        session?.modeResolveTask?.cancel()
        session?.modeResolveTask = nil
        guard waitForBringUpCleanup else {
            finish(machine: .cancel, cue: silently ? nil : .cancel, state: .hidden)
            return
        }
        droppingPress = unconfirmed != nil
        // Surface the cancel now, but defer the release tail to finishCanceledBringUp so the in-flight
        // bring-up task unwinds first.
        machine.beginCancellingBringUp()
        if !silently { effects.end(settings.duringDictation, cue: .cancel) }
        hud.present(.hidden)
        clearRewriteEscapeHatch()
    }

    private func finishCanceledBringUp(stopAudio: Bool) {
        if stopAudio, let url = audio.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        finish(machine: .cancel, cue: nil, state: nil)
        droppingPress = false
        if let deferred = deferredPress {
            deferredPress = nil
            handleStart(triggerKey: deferred.triggerKey, pressStyle: deferred.pressStyle, pressedAt: deferred.pressedAt)
            if deferred.released { handleCommit() }
        }
    }

    // The modes whose eligibility the frontmost bundle cannot settle on its own, so a URL or window-title
    // probe could still change the answer for them. Same predicate registration uses
    // (`ModeResolver.canClaimKey`) — "not disproved by the bundle alone" is exactly the question both ask,
    // so the two can never drift into a mode whose key is claimed but never probed, or the reverse.
    private func probeCandidates() -> [Mode] {
        let bundleId = capturedSnapshot?.bundleId
        return plan.modes.filter { ModeResolver.canClaimKey($0, bundleId: bundleId) }
    }

    // Phase A (design.md §4.3): resolve the mode from routing context before recording. A non-nil
    // triggerKey (from a mode's own HotkeyMonitor binding) forces that mode, overriding context. The
    // URL and window title are fetched only when a matching constraint exists (resolveModeProbing);
    // otherwise they are nil here.
    private func applyResolvedMode(triggerKey: String?, url: String?, windowTitle: String?) {
        let context = RoutingContext(bundleId: capturedSnapshot?.bundleId, url: url, windowTitle: windowTitle)
        session?.routingContext = context
        let press = PressResolver.phaseA(
            modes: plan.modes, context: context, triggerKey: triggerKey, overrideId: nextModeOverrideID)
        session?.eligibleModes = press.eligible
        if press.consumesOverride { nextModeOverrideID = nil }
        guard let choice = press.choice else {
            abortPressWithNoEligibleMode()
            return
        }
        let chosen = choice.mode
        session?.modeChoice = choice.reason
        session?.shortcutCandidates = choice.shortcutCandidates
        session?.triggerDisplay = choice.triggerDisplay
        activeMode = securePolicyApplied(chosen)
        agentTake.freezeRecipient()
        session?.modeReady = true
        claimOrDismissVoiceCommandChoice()
        onModeAndSnapshotReady()
    }

    private func markSnapshotReady() {
        session?.snapshotReady = true
        onModeAndSnapshotReady()
    }

    private func onModeAndSnapshotReady() {
        if activeMode?.answersAloud == true { answers?.prepare() }
        maybePreconnect()
        maybeStartPrecedingProbe()
    }

    // Fires only once the mode is resolved AND the secure-aware snapshot has confirmed the field isn't a
    // password field (a secure field neuters the mode first, so it has no connection → no preconnect).
    // llmClient.preconnect is a bodyless, auth-less HEAD plus a token-command cache fill — content-free
    // regardless of whether a rewrite ultimately runs.
    private func maybePreconnect() {
        guard let session, session.modeReady, session.snapshotReady, !session.preconnectFired,
              let mode = activeMode, let connection = connection(for: mode),
              connection.configIssue(permits: permits) == nil else { return }
        self.session?.preconnectFired = true
        preconnectTask?.cancel()
        preconnectTask = Task { [llmClient] in await llmClient.preconnect(connection: connection) }
    }

    // Overlap the preceding-text AX walk with drain+transcribe. A secure field has neutered the mode by here,
    // so effectiveContext.precedingText is off and the field is never read.
    private func maybeStartPrecedingProbe() {
        guard let session, session.modeReady, session.snapshotReady, session.precedingTextTask == nil,
              activeMode?.effectiveContext.precedingText == true,
              let pid = capturedSnapshot?.pid else { return }
        let probe = precedingTextProbe
        let windowId = capturedSnapshot?.focusedWindowId
        self.session?.precedingTextTask = Task { await probe(pid, windowId) }
    }

    // A focused secure (password) field forces whatever mode resolves fully local: no cloud rewrite, no
    // context, never recorded (design.md §4.7). Applied at every site that sets activeMode so a Phase-B
    // voice re-route to a cloud mode is neutered too. Best-effort — depends on the field exposing the
    // AXSecureTextField subrole (captured in TargetSnapshot.isSecureField). An unconfirmed target (the
    // secure-aware snapshot could not prove the field is safe because focus moved during the probe) is
    // treated identically — forced fully local (KS-01).
    private func securePolicyApplied(_ mode: Mode?) -> Mode? {
        guard targetMayHoldSecureText else { return mode }
        return mode?.localOnlyForSecureField()
    }

    private func resolveModeProbing(triggerKey: String?) async {
        // Settle the secure-aware snapshot first so the title probe can bind to the captured window id (the
        // press snapshot has none). Bounded by the same AX timeout the URL probe already tolerates; mode is
        // only needed at commit, so this cannot delay anything user-visible past the HUD.
        await session?.snapshotAdoptionTask?.value
        let (url, windowTitle) = await PressResolver.probeContext(candidates: probeCandidates(), captured: capturedSnapshot)
        // The probe is the one per-dictation task that can outlive a cancel (browser-URL round trip runs
        // ~0.6 s after ESC). A cancelled dictation must not apply its stale mode: it would write A's
        // routing/activeMode into a live successor B and consume B's one-shot override (nextModeOverrideID
        // lives on the controller, so session == nil doesn't neuter that write).
        guard !Task.isCancelled else { return }
        applyResolvedMode(triggerKey: triggerKey, url: url, windowTitle: windowTitle)
    }

    private func renameTranscribingHUD() {
        switch hud.lastPresented {
        case .transcribing(_, let status)?: hud.present(.transcribing(mode: currentModeName, status: status))
        case .loadingModel?: hud.present(.loadingModel(mode: currentModeName))
        default: break
        }
    }

    func startClipboardPrefetch() -> Task<Void, Never>? {
        guard let identity = session?.identity else { return nil }
        return Task { @MainActor [weak self] in
            guard let self, self.session?.identity === identity else { return }
            self.prefetchClipboard()
        }
    }

    // The secure-aware snapshot decides whether the mode is neutered (secure/unconfirmed target). Settle it
    // before any cloud rewrite reads activeMode, so a target that couldn't be confirmed can't leak (KS-01).
    // Adoption is not cancelled on commit, so this observes the real result.
    private func settleModeAndTarget() async {
        await session?.modeResolveTask?.value
        await session?.snapshotAdoptionTask?.value
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
    // Test seam: production scales the deadline with the recording
    // length; tests pin it to exercise the retry's budget check in bounded time.
    var transcribeTimeoutOverride: Double? {
        get { transcriber.timeoutOverride }
        set { transcriber.timeoutOverride = newValue }
    }

    var recoveryDecisionObserver: ((String) -> Void)? {
        get { transcriber.recoveryObserver }
        set { transcriber.recoveryObserver = newValue }
    }

    private func transcribeAndInsert(url: URL, audioSeconds: Double?, samples: [Float]? = nil, reading: SpeechPresenceReading? = nil) async {
        let transcribesWithoutTheMode = session?.capturedRecognitionBias == false
        if !transcribesWithoutTheMode { await settleModeAndTarget() }
        // A password field can steal focus AFTER adoption settled (autofill, a manager prompt, the user
        // clicking a login form mid-recording). The press/adoption snapshots cannot see that, so re-probe at
        // commit and fold the result in before the rewrite and history read it (X-1). Started here so the AX
        // walk overlaps transcription; awaited just before Phase-B, so it costs no user-visible latency.
        let commitSecureProbe = Task { @MainActor [snapshotAsync] in await snapshotAsync().isSecureField }
        let engine = activeEngine
        building.audioSeconds = audioSeconds
        let recovery = Transcriber.RecoveryProgress()

        let rawFromEngine: String
        // Load the model OUTSIDE the bounded transcribe. A CoreML/MLX compile is a one-time cost (632 MB
        // measured ~140 s even from a compiled cache), so counting it against the transcribe deadline
        // (≥30 s) both false-times-out a healthy load and leaves the gate `Busy` (the abandoned load keeps
        // running) until it settles. Awaiting the single warm load (started at press) keeps the deadline
        // on inference.
        func loadOnce() async throws {
            try await runWithDeadline(seconds: Self.modelLoadDeadlineSeconds) { [task = engines.warm(engine)] in
                try await task.value
            }
        }
        func settledBeforeFailing() async -> Bool {
            if transcribesWithoutTheMode { await settleModeAndTarget() }
            return !Task.isCancelled
        }
        func failModelLoadTerminal(_ error: Error) async {
            try? FileManager.default.removeItem(at: url)
            engines.invalidateWarm(engine.id)
            let timedOut = error is DeadlineExceeded
            recordModelLoadFailure(engine.id, timedOut, String(describing: error))
            log.error("model load \(timedOut ? "timed out" : "failed", privacy: .public) (\(engine.id, privacy: .public)): \(error, privacy: .public)")
            guard await settledBeforeFailing() else { return }
            finishError(timedOut ? "Loading the speech model timed out" : "Could not load the speech model")
        }
        let modelWaitStart = DispatchTime.now()
        // A resident model resolves loadOnce() in ~0 ms; a cold load can run seconds (~140 s for a big ANE
        // model). Rather than leave the HUD on "Transcribing" — a lie during a load — name the wait once
        // it exceeds ~1 s. Cancelled on resolution; guarded on machine.state so a cancel can't render it stale.
        let loadingHUD = scheduleLoadingModelHUD()
        do {
            try await loadOnce()
        } catch {
            if Task.isCancelled { loadingHUD.cancel(); try? FileManager.default.removeItem(at: url); return }
            // A genuine 300 s hang is not retried — a second wait is worse than surfacing.
            if error is DeadlineExceeded { loadingHUD.cancel(); await failModelLoadTerminal(error); return }
            // One automatic retry: a cold CoreML/MLX compile can fail transiently right after launch; a
            // fresh reload usually succeeds. invalidateWarm drops the failed task so warm(engine) builds a
            // new one; the HUD stays on `transcribing`, so a recovered transient is invisible. Mirrors the
            // pipeline's one-retry policy (design.md §4.2).
            engines.invalidateWarm(engine.id)
            log.notice("model load failed, retrying once (\(engine.id, privacy: .public)): \(error, privacy: .public)")
            do {
                try await loadOnce()
            } catch {
                loadingHUD.cancel()
                if Task.isCancelled { try? FileManager.default.removeItem(at: url); return }
                await failModelLoadTerminal(error)
                return
            }
        }
        modelLoadedForTesting?()
        loadingHUD.cancel()
        // A load that finished as the cancel landed still returns success; rendering now would re-show a
        // dismissed HUD.
        if Task.isCancelled { try? FileManager.default.removeItem(at: url); return }
        // Flip back to Transcribing for the inference that follows. A no-op (render dedupes) unless the
        // loading-model state was actually shown during a slow load.
        hud.present(.transcribing(mode: currentModeName))
        building.stageMillis[.modelWait] = elapsedMs(since: modelWaitStart)

        let transcribeStart = DispatchTime.now()
        let clipboardSnapshot = startClipboardPrefetch()
        do {
            await awaitSelfTestClearance()
            if Task.isCancelled { try? FileManager.default.removeItem(at: url); return }
            rawFromEngine = try await transcriber.transcribe(
                audioSeconds: audioSeconds ?? 0, biasTerms: recognitionBiasTerms(), engine: engine, url: url, samples: samples,
                reading: reading, recovery: recovery)
            transcriber.resetBusyStreak()
        } catch is SingleFlightDeadline.Busy {
            try? FileManager.default.removeItem(at: url)
            transcriber.noteBusyRejection()
            if Task.isCancelled { return }
            log.error("transcribe rejected — previous transcription still running (\(engine.id, privacy: .public))")
            guard await settledBeforeFailing() else { return }
            finishError("Still finishing the previous dictation")
            return
        } catch is DeadlineExceeded {
            try? FileManager.default.removeItem(at: url)
            // A user cancel cancels this task too; cancel() already handled the terminal state, so a
            // late deadline/error must not stomp the next dictation's HUD/effects/state.
            if Task.isCancelled { return }
            // The deadline landed during the retry: the engine already returned nothing on a take with
            // speech in it, so this is that silent failure — not a timeout to hand the user. The
            // abandoned call keeps the gate closed exactly as it does for any other deadline.
            if let trimmedSeconds = recovery.retryTrimmedSeconds {
                self.transcriber.logRecovery(
                    engine: engine, audioSeconds: audioSeconds ?? 0, reading: reading,
                    decision: Transcriber.RecoveryDecision(
                        attempted: true, outcome: "retry-deadline", trimmedSeconds: trimmedSeconds))
                guard await settledBeforeFailing() else { return }
                finishHeardButNoText(engine: engine)
                return
            }
            log.error("transcribe timed out (\(engine.id, privacy: .public))")
            guard await settledBeforeFailing() else { return }
            finishError("Transcription timed out")
            return
        } catch {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { return }
            log.error("transcribe failed (\(engine.id, privacy: .public)): \(error, privacy: .public)")
            guard await settledBeforeFailing() else { return }
            finishError("Transcription failed")
            return
        }
        try? FileManager.default.removeItem(at: url)
        building.stageMillis[.transcribe] = elapsedMs(since: transcribeStart)
        await clipboardSnapshot?.value
        if transcribesWithoutTheMode {
            if Task.isCancelled { return }
            await settleModeAndTarget()
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

        // The engine produced nothing on a take the VAD model positively heard speech in — recovery either
        // didn't apply or didn't help. Say that, rather than the misleading "No speech detected" that blames
        // the user for the engine's silent failure. Tested on the raw response: an annotation the cleanup
        // above blanked is the engine asserting blank audio, and keeps the ordinary no-speech path.
        if rawFromEngine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let reading, reading.modelUsed, reading.presence == .speech {
            finishHeardButNoText(engine: engine)
            return
        }

        // Fold the commit-time probe in before anything reads the flag. Secure is sticky and only the flag is
        // adopted: bundleId/pid must stay the PRESS-time target, since decideInsertion compares captured
        // against current to detect focus moves.
        let secureAtCommit = await commitSecureProbe.value
        if Task.isCancelled { return }
        if secureAtCommit, capturedSnapshot != nil {
            capturedSnapshot?.isSecureField = true
        }

        if VoiceCommandGrammar.parse(raw) == .help, !(activeMode?.runsVoiceCommands == true && session?.choiceId != nil) {
            finishHelp(mode: activeMode)
            return
        }
        if activeMode?.runsVoiceCommands == true {
            await finishVoiceCommand(heard: raw)
            return
        }
        let route = TakeRouting.phaseB(
            raw: raw, eligible: session?.eligibleModes ?? [], context: session?.routingContext ?? RoutingContext(),
            pressMode: activeMode)
        let routed = route.result
        if route.routedByPhrase {
            session?.modeChoice = .spokenPhrase
            session?.routedPhrase = routed.matchedPhrase
        }
        // Neuter the routed mode BEFORE it drives the rewrite: produceFinalText resolves the connection off
        // this mode, so a Phase-B re-route to a cloud mode from a secure field must be local-only here, not
        // only on the stored activeMode.
        let finalMode = securePolicyApplied(route.mode)
        activeMode = finalMode
        session?.pendingHeardTranscript = raw
        if let finalMode, finalMode.output == .agent {
            await agentTake.finish(routed: routed, heard: raw, mode: finalMode)
            return
        }
        let (final, rewrite, transformed) = await produceFinalText(routed: routed, mode: finalMode)

        // Cancelled during the rewrite: bail before any insert or history write.
        if Task.isCancelled { return }

        await dispatch(
            final, to: finalMode?.answersAloud == true ? .speak : .cursor, heard: raw, transformed: transformed, rewrite: rewrite)
    }

    private enum Destination {
        case cursor
        case agent(id: String, facts: [HistoryEntry.Fact])
        case speak
    }

    // The one place a take's final text goes to its output, for the normal path and the escape hatch alike.
    private func dispatch(
        _ final: FinalText, to destination: Destination, heard: String, transformed: String?, rewrite: RewriteDetails?
    ) async {
        switch (final, destination) {
        case (.abort(let message, let action), _):
            // A selection rewrite that failed (or had nothing to do) leaves the target untouched —
            // a destructive op must never overwrite the user's text on failure.
            log.info("aborted: \(message, privacy: .public)")
            clearRewriteEscapeHatch()
            finishError(message, action: action)
        case (.discard, _):
            clearRewriteEscapeHatch()
            finishDiscarded()
        case (.insert(let text, _, _), .agent(let id, let facts)):
            await agentTake.deliver(id, text: text, heard: heard, transformed: transformed, rewrite: rewrite, facts: facts)
        case (.insert(let text, _, _), .speak):
            finishAnswer(text, heard: heard, rewrite: rewrite)
        case (.insert(let text, let bare, let submit), .cursor):
            await finishInsertion(transcript: text, heard: heard, transformed: transformed, rewrite: rewrite, bare: bare, submitOverride: submit)
        }
    }

    private func finishAnswer(_ answer: String, heard: String, rewrite: RewriteDetails?) {
        clearRewriteEscapeHatch()
        guard settings.features.isEnabled(.askAboutSelection) else { return finishError(Self.answersOff) }
        guard lease().stillWanted() else { return }
        building.fingerprints[.final] = .of(answer)
        if let answers {
            answers.answer(answer, name: currentModeName, since: session?.releasedAt ?? .now())
        } else {
            log.error("answer ready but no speech output is wired")
        }
        finish(
            machine: .finish(.inserted), cue: .success, state: .hidden,
            record: (.answered, nil),
            history: HistoryWrite(heard: heard, transformed: nil, result: answer, insertion: .inserted, rewrite: rewrite, outcome: .answered))
    }

    func noteAnswerFirstAudio(milliseconds: Double) {
        guard lastRecord?.outcome == .answered, lastRecord?.stageMillis[.firstAudio] == nil else { return }
        lastRecord?.stageMillis[.firstAudio] = milliseconds
    }

    var frontReadingGrace: Duration {
        get { agentTake.frontReadingGrace } set { agentTake.frontReadingGrace = newValue }
    }
    var placeNamesGrace: Duration {
        get { agentTake.placeNamesGrace } set { agentTake.placeNamesGrace = newValue }
    }
    var promptBoxConfirmation: Duration {
        get { agentTake.promptBoxConfirmation } set { agentTake.promptBoxConfirmation = newValue }
    }

    static func unconnectedLine(_ meant: [AgentHub.Unconnected]) -> String { AgentTake.unconnectedLine(meant) }

    func finishAgent(
        state: HUDState, outcome: DictationOutcome, heard: String, body: String, transformed: String?,
        rewrite: RewriteDetails?, transitioned: Bool, hideAfter: Double?, summary: String?,
        recorded: String?, facts: [HistoryEntry.Fact], onRecorded: ((HistoryEntry) -> Void)?
    ) -> Bool {
        if !transitioned {
            if !body.isEmpty { lastResult = body }
            guard lease().beginActing() else { return false }
        }
        machine.finish(outcome)
        building.fingerprints[.final] = .of(body)
        let reason = outcome == .inserted ? nil : recorded ?? state.primaryText
        finish(machine: .alreadyTransitioned, cue: outcome == .inserted ? .success : .error, state: state,
               hideAfter: hideAfter ?? (outcome == .inserted ? 2 : 6),
               record: (outcome == .inserted ? .inserted : .failed, reason),
               history: HistoryWrite(
                   heard: heard, transformed: transformed, result: body, insertion: outcome, rewrite: rewrite,
                   failureReason: reason, summary: summary ?? recorded ?? state.primaryText,
                   facts: facts + (SpokenEdit.historyFacts(session?.spokenEdits) ?? []),
                   onRecorded: onRecorded))
        return true
    }

    func recordSpokenReply(_ heard: SpokenResultOutput.Heard) {
        spokenAttempts?.awaitLink(heard.attempt)
        agentOutput.recordSpokenReply(heard, alone: {
            let mode = config.modes.first { $0.id == Mode.codingAgentId }
            guard !(mode?.excludeFromHistory ?? false) else { return nil }
            return (mode?.name ?? Mode.codingAgent.name, settings.history.retentionDays)
        }, then: { [weak self] entry in
            guard let self else { return }
            self.spokenAttempts?.link(heard.attempt, to: entry)
            self.lastHeardReply = (entry, heard.name)
            guard let entry else { return }
            self.lastSpokenReplyEntry = entry
            self.onSpokenReplyRecorded?(heard.attempt, entry)
        })
    }

    func forgetSpokenReplies(_ entries: [String]) -> Bool {
        guard let last = lastSpokenReplyEntry, entries.contains(last) else { return false }
        lastSpokenReplyEntry = nil
        return true
    }

    func recordUnreadReply(_ unread: SpokenResultOutput.Unread, origin: String) {
        agentOutput.recordUnreadReply(unread, origin: origin)
    }

    func showAgentNotice(_ receipt: AgentReceipt, request: String? = nil, conversation: String? = nil) {
        agentOutput.showNotice(receipt, request: request)
        if request != nil, let conversation { agentTake.speakRefusal(receipt, conversation: conversation) }
    }

    func forgetAgentReceipt(request: String) {
        agentOutput.forgetReceipt(request: request)
    }

    var agentNoticeDelayOverride: Duration? {
        get { agentOutput.noticeDelayOverride }
        set { agentOutput.noticeDelayOverride = newValue }
    }

    // The one definition of a take that may still act: not cancelled, its capture intact, still the current
    // take, its feature still on, no voice-command stop since the press, and the machine where acting is allowed.
    func lease(for feature: Feature? = nil, stopsAtPress: Int? = nil) -> TakeLease {
        let identity = session?.identity
        return TakeLease(
            stillWanted: { [weak self] in
                guard let self, !Task.isCancelled, !self.captureWasLost, let identity,
                      self.session?.identity === identity,
                      feature.map(self.settings.features.isEnabled) ?? true,
                      stopsAtPress.map({ $0 == self.commandOutput.stops }) ?? true else { return false }
                return self.machine.state == .transcribing || self.machine.state == .inserting
            },
            beginActing: { [weak self] in
                guard let self, self.machine.beginInserting() else { return false }
                self.hud.relinquishKeyFocus()
                return true
            },
            abortsActuation: { [lossFlag = session?.captureLoss] in lossFlag?.isLost ?? false })
    }

    private func finishInsertion(
        transcript: String, heard: String, transformed: String? = nil, rewrite: RewriteDetails?,
        bare: Bool = false, submitOverride: Mode.Submit? = nil
    ) async {
        clearRewriteEscapeHatch()
        // The route died mid-take, so everything said after it went is simply not in the audio. Inserting
        // the prefix would read as an ordinary success while silently changing what the user said — losing
        // the end of a sentence can invert its meaning — so nothing is inserted and no submit fires. The
        // prefix stays recoverable through "Paste last dictation" instead.
        let lease = lease()
        let request = InsertOutput.Request(
            text: transcript, heard: heard, mode: activeMode, captured: capturedSnapshot,
            trailing: bare ? "" : (activeMode?.trailing ?? .none).suffix(after: transcript),
            submit: session?.stoppedAtLimit == true ? .none : submitOverride ?? activeMode?.submit ?? .none,
            submitOverride: submitOverride, stoppedAtLimit: session?.stoppedAtLimit == true ? limitPhrase : nil,
            paste: clipboardPaste(for: activeMode))
        let (result, report) = await inserter.perform(request, lease: lease) { [weak self] in self?.lastResult = $0 }
        if report.targetCheckMs != nil {
            building.stageMillis[.targetCheck] = report.targetCheckMs
            building.stageMillis[.insert] = report.insertMs
            building.targetBundleId = report.targetBundleId
            building.delivery = report.delivery
            // A rewrite fallback reason already recorded (an LLM 400) is the more surprising cause; the
            // insertion-clipboard reason only fills the slot when nothing else claimed it.
            if building.fallbackReason == nil { building.fallbackReason = report.clipboardReason }
            building.fingerprints[.final] = .of(transcript)
        }
        let outcome: DictationOutcome
        switch result {
        case .preempted:
            return
        case .abandoned:
            if captureWasLost { finishTruncatedCapture(transcript: transcript) }
            return
        case .refused(let message, let action):
            finishError(message, action: action)
            return
        case .done(let done):
            outcome = done
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
        let keptLocal = rewrite?.fellBack == true || session?.rewriteSkippedAtLimit == true
        let recordOutcome: DictationRecord.Outcome
        switch outcome {
        case .noSpeech: recordOutcome = .noSpeech
        case .inserted: recordOutcome = keptLocal ? .localFallback : .inserted
        case .copied: recordOutcome = keptLocal ? .localFallback : .copied
        case .failed: recordOutcome = .failed
        }
        // Built here, while the session is still alive, so modeId survives releaseCapturedPlan.
        let completion = DictationCompletion(
            outcome: outcome, modeId: activeMode?.id, heard: heard, finalText: transcript)
        let textLanded: Bool = switch outcome {
        case .inserted, .copied: true
        case .noSpeech, .failed: false
        }
        let stoppedAtLimit = session?.stoppedAtLimit == true && textLanded
        if textLanded, let effects = session?.replacementEffects {
            reporter.recordUsage(effects: effects, capturedAt: session?.replacementUsageEpoch)
        }
        let completedState: HUDState
        if stoppedAtLimit {
            completedState = .stoppedAtLimit(
                outcome: outcome, limit: limitPhrase, rewriteSkipped: session?.rewriteSkippedAtLimit == true)
        } else if let skippedAfterMs = rewrite?.skippedAfterMs {
            completedState = .rewriteSkipped(outcome: outcome, mode: currentModeName, seconds: skippedAfterMs / 1000)
        } else if rewrite?.fellBack == true {
            completedState = .localFallback(
                outcome: outcome, mode: currentModeName,
                reason: rewrite?.fallbackReason, connectionId: rewrite?.connectionId)
        } else {
            completedState = .complete(
                outcome: outcome, mode: currentModeName, notice: textLanded ? reasoningNotice(for: rewrite) : nil,
                spokenEdits: textLanded ? session?.spokenEdits : nil)
        }
        finish(machine: .alreadyTransitioned, cue: endCue,
               state: completedState,
               hideAfter: completedState.hidesAfterSeconds,
               record: (recordOutcome, nil),
               history: HistoryWrite(heard: heard, transformed: transformed, result: transcript,
                                     insertion: outcome, rewrite: rewrite,
                                     facts: SpokenEdit.historyFacts(session?.spokenEdits)),
               completion: completion)
    }

    // Local history (design.md §4.7): one append per dictation that produced text, unless history is
    // off or the mode opts out. noSpeech is not recorded (nothing was said). Audio and the redaction
    // map are never written; the stored prompt carries tokens, not their originals.
    func waitForHistoryWrites() { reporter.waitForWrites() }

    private var targetMayHoldSecureText: Bool {
        capturedSnapshot?.isSecureField == true || session?.targetUnconfirmed == true
    }

    @discardableResult
    private func recordHistory(
        heard: String, transformed: String?, result: String, insertion: DictationOutcome,
        rewrite: RewriteDetails?, failureReason: String? = nil, reported: String? = nil, confirmWrite: Bool = false,
        commandStillRunning: Bool = false, outcome override: HistoryEntry.Outcome? = nil,
        summary: String? = nil, facts: [HistoryEntry.Fact]? = nil, onRecorded: ((HistoryEntry) -> Void)? = nil
    ) -> Bool {
        // A secure-field dictation is never persisted, regardless of the history setting or the mode —
        // the spoken text is a password (design.md §4.7). An unconfirmed target (focus moved before the
        // secure-aware snapshot could vet the field) is treated the same way (KS-01). The diagnostics record
        // holds only fingerprints (hashes), never the transcript, so it is safe to keep; this guards the
        // verbatim history store.
        guard settings.history.enabled, !(activeMode?.excludeFromHistory ?? false), !targetMayHoldSecureText else { return false }
        // Last line of defense: a password field that stole focus after the commit-time probe is still caught
        // by the inserter, which diverts to a concealed copy. That verdict is the system classifying the text
        // as password-grade — it must veto history too (X-1).
        if case .copied(.secureField) = insertion { return false }
        let rewriteSkipped = session?.rewriteSkippedAtLimit == true
        let keptLocal = rewrite?.fellBack == true || rewriteSkipped
        let base: HistoryEntry.Outcome
        let isCommand = activeMode?.runsVoiceCommands == true
        switch insertion {
        case .noSpeech: return false
        case .inserted: base = isCommand ? (commandStillRunning ? .commandStarted : .command) : keptLocal ? .localFallback : .inserted
        case .copied: base = keptLocal ? .localFallback : .copied
        case .failed: base = isCommand ? .commandFailed : .failed
        }
        let outcome = override ?? base
        var entry = HistoryEntry(
            id: UUID().uuidString, timestamp: Date(), modeName: currentModeName, engine: activeEngine.displayName,
            device: session?.capturedInputDevice,
            heard: heard, transformed: transformed,
            result: result, outcome: outcome,
            cloudInvolved: rewrite != nil, redaction: rewrite?.redaction ?? false,
            contextCategories: rewrite?.contextCategories ?? [],
            connection: rewrite?.connection, model: rewrite?.model, prompt: rewrite?.prompt,
            received: rewrite?.received,
            modeChoice: session?.modeChoice, routedPhrase: session?.routedPhrase,
            triggerKey: session?.triggerDisplay,
            fallbackReason: keptLocal
                ? (rewriteSkipped ? Self.rewriteSkippedAtLimitReason : rewrite?.fallbackReason) : nil,
            stoppedAtLimit: session?.stoppedAtLimit == true ? true : nil,
            failureReason: failureReason, reported: reported)
        entry.reasoning = rewrite?.reasoning?.summary
        entry.summary = summary
        entry.facts = facts
        entry.rewriteSkippedMs = rewrite?.skippedAfterMs.map { Int($0.rounded()) }
        entry.appVersion = DiagnosticsCollector.appVersion()
        entry.osVersion = DiagnosticsCollector.osVersion()
        entry.targetApp = building.targetBundleId
        entry.deliveryAttempted = building.delivery
        let stages = building.stageMillis
        entry.stageMillis = stages.isEmpty
            ? nil : Dictionary(uniqueKeysWithValues: stages.map { ($0.key.rawValue, Int($0.value.rounded())) })
        entry.audioSeconds = building.audioSeconds
        entry.error = building.error
        let candidates = session?.shortcutCandidates ?? []
        entry.shortcutCandidates = candidates.isEmpty ? nil : candidates
        guard reporter.keepsHistory else { return false }
        onRecorded?(entry)
        return reporter.append(entry, retentionDays: settings.history.retentionDays, confirm: confirmWrite)
    }

    private enum FinalText {
        // `bare` ⇒ a whole-utterance replacement: insert verbatim, suppress trim + trailing. `submit`
        // is a `<CR>`-requested Return that overrides the mode's submit for this insert only.
        case insert(String, bare: Bool, submit: Mode.Submit?)
        // leave the target untouched; surface this message, optionally with a repair action
        case abort(String, HUDErrorAction?)
        case discard
    }

    // Defense-in-depth before insert (design.md §4.2): after the LIFO restore pass, no ISSUED nonce should
    // survive — one that does means a token-opacity/restore bug that would paste a literal `⟦SN:VERB:1⟧` or
    // (worse) leak a redacted span. Fail safely and visibly. A sentinel-SHAPED substring that is NOT an
    // issued token is legitimate user content (a clipboard/verbatim value containing the sentinel) and
    // passes through untouched.
    private func guardedInsert(_ text: String, issuedTokens: [String]) -> FinalText {
        if TakeText.leaksIssuedToken(text, issuedTokens: issuedTokens) {
            log.error("insert aborted: unrestored sentinel token survived the restore pass")
            return .abort("Dictation could not be completed — please try again", nil)
        }
        return .insert(text, bare: false, submit: nil)
    }

    // Shown on the completion HUD itself, so a following dictation cannot cancel it unseen.
    private func reasoningNotice(for rewrite: RewriteDetails?) -> String? {
        guard let rewrite, !rewrite.fellBack, let reasoning = rewrite.reasoning,
              let notice = reasoning.notice(service: rewrite.connection, model: rewrite.model),
              noticedReasoning.insert(rewrite.connectionId + "\n" + rewrite.model).inserted else { return nil }
        return notice
    }

    private func produceFinalText(routed: PhaseBResult, mode: Mode?) async -> (FinalText, RewriteDetails?, String?) {
        if mode?.source == .selection {
            if session?.stoppedAtLimit == true {
                let kept = recordHistory(
                    heard: routed.transcript, transformed: nil, result: "", insertion: .failed, rewrite: nil,
                    confirmWrite: true)
                let message = "Stopped at the \(limitPhrase) limit — selection unchanged"
                return (.abort(kept ? message + ". What you said is in History." : message, nil), nil, nil)
            }
            if mode?.answersAloud == true, !settings.features.isEnabled(.askAboutSelection) {
                return (.abort(Self.answersOff, nil), nil, nil)
            }
            let (final, details) = await runOnSelection(instruction: routed.transcript, mode: mode)
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
        var resolved = mode.flatMap { m in connection(for: m).map { (mode: m, connection: $0) } }
        if resolved != nil, session?.stoppedAtLimit == true {
            resolved = nil
            session?.rewriteSkippedAtLimit = true
            building.fallbackReason = "recording limit"
        }
        let pipeline = dictationPipeline(for: mode, willRewrite: resolved != nil)
        let localStart = DispatchTime.now()
        let take = TakeText(transcript, pipeline: pipeline, trimsTrailingPunctuation: mode?.trimTrailingPunctuation ?? false)
        session?.replacementEffects = take.payload.replacementEffects
        session?.spokenEdits = SpokenEdit.summary(take.payload.spokenEdits)
        if take.discarded { return (.discard, nil, nil) }

        // Whole-utterance replacement: one rule owned the entire utterance, so insert its generated
        // value verbatim — bypassing the LLM (the model never sees it; redaction is moot) and the
        // trailing/trim shaping. Detected at the replacements stage and surfaced on the payload.
        if let bare = take.bare {
            building.stageMillis[.localProcess] = elapsedMs(since: localStart)
            building.fingerprints[.localProcessed] = .of(bare.text)
            return (.insert(bare.text, bare: true, submit: bare.submit), nil, bare.text)
        }

        // Locally-processed text (tokens restored, no LLM): the history "middle stage", and what we
        // insert when no rewrite runs or it falls back.
        let localProcessed = take.localText
        building.stageMillis[.localProcess] = elapsedMs(since: localStart)
        building.fingerprints[.localProcessed] = .of(localProcessed)
        // Record the on-device intermediate unconditionally — the local pipeline runs every dictation, so a
        // no-op still leaves an artifact (else history reads as "local was skipped"). Equals `transcript`
        // when nothing changed; the History diff shows "no differences".
        let transformed = localProcessed

        guard let resolved, !take.isBlank else {
            return (guardedInsert(localProcessed, issuedTokens: take.payload.issuedTokens), nil, transformed)
        }
        let result = await rewriteTokenized(
            take, localText: localProcessed, instruction: "", mode: resolved.mode, connection: resolved.connection)
        return (guardedInsert(result.text, issuedTokens: take.payload.issuedTokens), result.details, transformed)
    }

    // Edit-in-place or answer: capture the selection, then rewrite it or answer about it per the spoken
    // instruction. Any failure — no selection, no connection, or a reply that fell back — aborts and leaves
    // the selection untouched. A destructive operation must never clobber the user's text on failure.
    private func runOnSelection(instruction: String, mode: Mode?) async -> (FinalText, RewriteDetails?) {
        guard let mode else { return (.abort("No mode resolved", nil), nil) }
        // Capturing the selection fires a synthetic ⌘C, which the OS drops without Accessibility — so
        // the read silently fails and the abort below would misreport it as "no selection". Name the
        // real cause and offer the fix instead.
        guard accessibilityGranted() else {
            return (.abort("Accessibility is off — \(Branding.appName) can't read the selected text.", .openAccessibilitySettings), nil)
        }
        // The selection-capture ⌘C must reach the target, so drop key focus held for ESC-cancel; the
        // subsequent .rewriting render re-takes it so ESC still cancels the rewrite.
        hud.relinquishKeyFocus()
        let captureStart = DispatchTime.now()
        let captured = await captureSelection(mode.copyKeystroke)
        building.stageMillis[.selection] = elapsedMs(since: captureStart)
        guard let selection = captured, !selection.isEmpty else {
            return (.abort("Select some text first", nil), nil)
        }
        guard let connection = connection(for: mode) else {
            return (.abort("\(mode.name) needs an AI connection", nil), nil)
        }
        // Tokenization is pure CPU and a selection can be a whole document, so it runs off the main actor.
        let liveEdits = mode.commands.liveEdits
        let privacy = mode.commands.privacy
        let trims = mode.trimTrailingPunctuation
        let prepared = await Task.detached(priority: .userInitiated) {
            SelectionText(
                selection: selection, instruction: instruction, liveEdits: liveEdits, privacy: privacy,
                trimsTrailingPunctuation: trims)
        }.value
        if mode.answersAloud, !settings.features.isEnabled(.askAboutSelection) {
            return (.abort(Self.answersOff, nil), nil)
        }
        let result = await rewriteTokenized(
            prepared.take, localText: selection, instruction: prepared.instruction, mode: mode, connection: connection,
            instructionTokens: prepared.instructionTokens)
        let final: FinalText = result.ok
            ? guardedInsert(result.text, issuedTokens: prepared.take.payload.issuedTokens)
            : .abort(
                mode.answersAloud
                    ? Self.answerFailure(cutOff: result.details.cutOff, reason: result.details.fallbackReason)
                    : "Rewrite failed — selection unchanged",
                nil)
        return (final, result.details)
    }

    static let answersOff = "Turn on \u{201C}\(Feature.askAboutSelection.title)\u{201D} in Experimental features to hear answers"
    static func answerFailure(cutOff: Bool, reason: String?) -> String {
        if cutOff { return "The answer was too long and was cut off" }
        return ["Couldn\u{2019}t get an answer.", reason].compactMap { $0 }.joined(separator: " ")
    }

    enum RewriteAgain {
        case rewritten(text: String, details: RewriteDetails)
        case unavailable(String)
    }

    // Asked for from History, after the take is over: no HUD, no insertion, and no context, since the
    // original take's context is never stored and today's screen is not what was dictated into. Redaction
    // stays on when the original take had it, even if the mode has turned it off since.
    func rewriteAgain(_ entry: HistoryEntry) async -> RewriteAgain {
        guard var mode = plan.modes.first(where: { $0.name == entry.modeName }) else {
            return .unavailable("No mode is named \u{201C}\(entry.modeName)\u{201D} now.")
        }
        guard let connection = connection(for: mode) else {
            return .unavailable("\(mode.name) has no AI service now.")
        }
        if entry.redaction { mode.commands.privacy = true }
        let heard = entry.modeChoice == .spokenPhrase
            ? entry.routedPhrase.map { ModeResolver.strippingRoutingPhrase($0, from: entry.heard) } ?? entry.heard
            : entry.heard
        let clipboardRead = OSAllocatedUnfairLock(initialState: false)
        let pipeline = TakeStages.dictation(
            text: plan.postSTTTextStages(for: mode),
            clipboard: { clipboardRead.withLock { $0 = true }; return nil },
            redaction: mode.commands.privacy)
        let take = TakeText(heard, pipeline: pipeline, trimsTrailingPunctuation: mode.trimTrailingPunctuation)
        if clipboardRead.withLock({ $0 }) {
            return .unavailable("It inserted the clipboard, which may have changed since.")
        }
        if take.bare != nil { return .unavailable("A replacement rule took the whole dictation, so nothing is rewritten.") }
        if take.isBlank { return .unavailable("There are no words to rewrite.") }
        let plan = plan
        let result = await rewriter.rewrite(
            take, localText: take.localText, mode: mode, connection: connection,
            request: {
                await RewriteRequestBuilder(
                    mode: mode, content: take.payload.text, instruction: "", issuedTokens: take.payload.issuedTokens,
                    capturedBundleId: nil, capturedPid: nil, plan: plan, connection: connection).build()
            },
            checkpoint: nil, presentsHUD: false)
        guard result.ok else {
            return .unavailable("The AI rewrite failed again: \(result.details.fallbackReason ?? "no reason given").")
        }
        guard !TakeText.leaksIssuedToken(result.text, issuedTokens: take.payload.issuedTokens) else {
            return .unavailable("The rewrite could not be completed.")
        }
        return .rewritten(text: result.text, details: result.details)
    }

    private func connection(for mode: Mode) -> Connection? {
        guard let rewrite = mode.aiRewrite, !rewrite.connection.isEmpty else { return nil }
        guard let connection = plan.connection(id: rewrite.connection) else {
            log.error("rewrite connection '\(rewrite.connection, privacy: .public)' not found in connections.toml")
            return nil
        }
        return connection
    }

    private func rewriteTokenized(
        _ take: TakeText, localText: String, instruction: String, mode: Mode, connection: Connection,
        instructionTokens: [String] = []
    ) async -> (text: String, ok: Bool, details: RewriteDetails) {
        let identity = session?.identity
        building.cloudInvolved = true
        building.connection = connection.name
        building.model = connection.model
        building.redaction = mode.commands.privacy
        building.issuedTokenCount = take.payload.issuedTokens.count
        building.fingerprints[.sentToLLM] = .of(take.payload.text)
        let snapshot = capturedSnapshot
        let plan = plan
        let precedingTextTask = session?.precedingTextTask
        let probe = precedingTextProbe
        let result = await rewriter.rewrite(
            take, localText: localText, mode: mode, connection: connection, instructionTokens: instructionTokens,
            request: {
                // Lists `instructionTokens` too, so the model gets the opaque-marker rule even when the selection
                // itself issued none.
                await RewriteRequestBuilder(
                    mode: mode, content: take.payload.text, instruction: instruction,
                    issuedTokens: take.payload.issuedTokens + instructionTokens,
                    capturedBundleId: snapshot?.bundleId, capturedPid: snapshot?.pid,
                    capturedWindowId: snapshot?.focusedWindowId,
                    plan: plan, connection: connection,
                    precedingTextTask: precedingTextTask, precedingTextProbe: probe).build()
            },
            checkpoint: mode.source == .selection ? nil : { [weak self] point in
                guard let self else { return }
                self.session?.rewriteStartedAt = point.startedAt
                self.session?.pendingLocalTranscript = point.localText
                self.session?.pendingLocalIssuedTokens = point.issuedTokens
                self.session?.pendingLocalRewriteDetails = point.details
                self.scheduleRewriteEscapeHatch(
                    connection: connection, mode: mode, contextCategories: point.details.contextCategories)
            })
        // The reasoning lookup after the reply suspends too: a skip or a newer take landing there owns the record.
        if let finished = result.finished, !Task.isCancelled, let identity, session?.identity === identity {
            building.stageMillis[.rewrite] = finished.milliseconds
            if let output = finished.modelOutput {
                building.fingerprints[.llmOut] = .of(output)
            } else {
                building.fallbackReason = finished.fallbackReason
            }
        }
        return (result.text, result.ok, result.details)
    }

    // Full dictation pipeline (design.md §4.2.1): the frozen plan's compiled text stages (live edits →
    // replacements → numbers → fuzzy), then verbatim (if live edits) sorts BEFORE them so its span is
    // opaque to them, and redaction (if privacy AND a cloud rewrite will run) sorts AFTER them,
    // tokenizing the fully-transformed text just before the LLM. Pipeline sorts by position/order, so
    // append order does not matter. Verbatim/redaction hold per-dictation tokenizers and are built
    // fresh here; the text stages are pure config and reused from the plan.
    func dictationPipeline(for mode: Mode?, willRewrite: Bool) -> Pipeline {
        let text = plan.postSTTTextStages(for: mode)
        logDroppedReturnMarkerRules(in: text, mode: mode)
        // The read is main-actor (NSPasteboard); this pipeline's forward pass runs on the main actor.
        let redaction = (mode?.commands.privacy ?? false) && willRewrite
        if mode?.output == .agent {
            agentClipboard.beginTake()
            return TakeStages.dictation(
                text: text, clip: { [agentClipboard] in MainActor.assumeIsolated { agentClipboard.read() } }, redaction: redaction)
        }
        return TakeStages.dictation(
            text: text,
            clipboard: { [clipboard] in MainActor.assumeIsolated { clipboard() } },
            redaction: redaction)
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

    // Every clipboard paste in the app is assembled here — the single gate for the consumption-driven
    // restore; nothing downstream branches on flag identity.
    func clipboardPaste(for mode: Mode?) -> ClipboardPaste {
        let restoreMs = settings.insertion.clipboardRestoreMs
        let restoreOnRead = settings.features.isEnabled(.consumptionDrivenRestore)
        return mode.map { ClipboardPaste(mode: $0, restoreMs: restoreMs, restoreOnRead: restoreOnRead) }
            ?? ClipboardPaste(restoreMs: restoreMs, restoreOnRead: restoreOnRead)
    }

    func pasteLast() {
        guard let lastResult else { return }
        guard !pasteLastDivertsToClipboard(
            frontmostBundleId: frontmostBundleId(),
            ownBundleId: Bundle.main.bundleIdentifier,
            accessibilityGranted: accessibilityGranted()
        ) else { _ = TextInserter.copyToClipboard(lastResult); return }
        hud.relinquishKeyFocus()
        let paste = clipboardPaste(for: nil)
        Task { await TextInserter.insertViaPaste(lastResult, paste: paste) }
    }

    // Cancellable while arming, recording, or transcribing/rewriting — never mid-insert, where the text is
    // already landing and cancel() would race finishInsertion (conflicting state + double cue). This gates
    // the HUD's ESC monitor, which can only fire while the HUD is key, i.e. NOT while arming — an arming
    // dictation is cancelled by the trigger (handleCommit), the chord-wins abort, a screen lock, or quit.
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

    // The "chord wins" abort from a modifier-only trigger: the key turned out to be part of a chord, so
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
        replayingKeys = true
        Task { @MainActor [weak self, wait = keyReplayWindow] in
            try? await Task.sleep(for: wait)
            guard let self else { return }
            let keys = self.keysTakenByHUD
            self.keysTakenByHUD = []
            self.replayingKeys = false
            guard !keys.isEmpty else { return }
            self.log.info("chord cancel replays \(keys.count, privacy: .public) key event(s)")
            self.replayKeys(keys)
        }
    }

    var replayKeys: @MainActor ([CGEvent]) -> Void = { events in
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        KeyReplay.post(events, to: app.processIdentifier)
    }
    var keyReplayWindow: Duration = .milliseconds(50)
    private var keysTakenByHUD: [CGEvent] = []
    private var replayingKeys = false

    func noteKeyReceivedByHUD(_ event: CGEvent) {
        guard replayingKeys || machine.state == .arming || machine.state == .recording else { return }
        keysTakenByHUD.append(event)
    }

    // The screen locked mid-dictation (lid close / hot corner). Cancel any in-flight capture so the
    // mic stops immediately and its temp WAV is deleted — no locked-screen audio survives.
    func handleSystemSleep() {
        stopVoiceCommandChoice()
    }

    func handleScreenLocked() {
        stopVoiceCommandChoice()
        guard machine.isBusy else { return }
        cancel()
    }

    func insertLocalTranscriptNow() {
        guard let transcript = session?.pendingLocalTranscript, let heard = session?.pendingHeardTranscript,
              machine.state == .transcribing else { return }
        let issuedTokens = session?.pendingLocalIssuedTokens ?? []
        var rewrite = session?.pendingLocalRewriteDetails
        if let start = session?.rewriteStartedAt {
            let elapsed = elapsedMs(since: start)
            rewrite?.skippedAfterMs = elapsed
            building.stageMillis[.rewrite] = elapsed
            building.fallbackReason = "skipped by the user"
        }
        dictationTask?.cancel()
        clearRewriteEscapeHatch()
        let final = guardedInsert(transcript, issuedTokens: issuedTokens)
        if case .abort(let message, let action) = final { return finishError(message, action: action) }
        let destination: Destination
        if activeMode?.output == .agent {
            guard let id = session?.agentDestination else { return finishError("The recipient was lost. Nothing sent.") }
            destination = .agent(id: id, facts: session?.agentFacts ?? [])
        } else {
            destination = .cursor
        }
        let identity = session?.identity
        Task {
            guard let identity, self.session?.identity === identity else { return }
            await self.dispatch(final, to: destination, heard: heard, transformed: transcript, rewrite: rewrite)
        }
    }

    static let loadingModelHUDDelay: Duration = .seconds(1)
    // Test seam. A test that wants to observe the loading HUD would otherwise have to make its fake load
    // outlast this delay, racing two timers — which flakes under CPU contention rather than failing for a
    // real reason. Overriding it lets the delay be ~0 so the state is reached deterministically.
    var loadingModelHUDDelayOverride: Duration?
    var modelLoadedForTesting: (() -> Void)?
    // Test seam for the whole-rewrite deadline, so a test can watch it fire without waiting minutes.
    var rewriteDeadlineSecondsOverride: Double? {
        get { rewriter.deadlineSecondsOverride }
        set { rewriter.deadlineSecondsOverride = newValue }
    }
    static let rewriteEscapeDelay: Duration = .seconds(5)
    var rewriteEscapeDelayOverride: Duration?

    private func scheduleLoadingModelHUD() -> Task<Void, Never> {
        Task { @MainActor [weak self, delay = loadingModelHUDDelayOverride ?? Self.loadingModelHUDDelay] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.machine.state == .transcribing else { return }
            self.hud.present(.loadingModel(mode: self.currentModeName))
        }
    }

    private func scheduleRewriteEscapeHatch(connection: Connection, mode: Mode, contextCategories: [String]) {
        session?.rewriteEscapeTask?.cancel()
        session?.rewriteEscapeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.rewriteEscapeDelayOverride ?? Self.rewriteEscapeDelay)
            guard let self, !Task.isCancelled, self.session?.pendingLocalTranscript != nil,
                  self.machine.state == .transcribing else { return }
            self.hud.present(.rewriting(
                connection: connection.name, mode: mode.name, redacted: mode.commands.privacy,
                contextCategories: contextCategories, offerLocalTranscript: true))
        }
    }

    func clearRewriteEscapeHatch() {
        session?.rewriteEscapeTask?.cancel()
        session?.rewriteEscapeTask = nil
        session?.pendingLocalTranscript = nil
        session?.pendingLocalIssuedTokens = []
        session?.pendingHeardTranscript = nil
        session?.pendingLocalRewriteDetails = nil
        session?.rewriteStartedAt = nil
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
        var failureReason: String?
        var reported: String?
        var commandStillRunning = false
        var outcome: HistoryEntry.Outcome?
        var summary: String?
        var facts: [HistoryEntry.Fact]?
        var onRecorded: ((HistoryEntry) -> Void)?
    }

    // The one terminal tail every dictation exits through. The fixed order is load-bearing: finalizeRecord
    // and recordHistory read session state (activeMode/activeEngine/currentModeName) so they run before
    // releaseCapturedPlan nils the session; the engine is captured before release so eviction targets the
    // engine this dictation used. Every terminal applies the tier, cancels included: handleStart dropped any
    // pending idle eviction, so a terminal that skipped it would pin the model. onBecameIdle fires exactly
    // once (only from releaseCapturedPlan). A caller that already ran its machine transition (finishInsertion) passes .alreadyTransitioned, and one that
    // must report the mode it used builds `completion` before calling in (activeMode is gone after release).
    private func finish(
        machine terminal: MachineTerminal,
        cue: DuringDictationEffects.EndCue?,
        endsQuietly: Bool = false,
        state: HUDState?,
        hideAfter: Double? = nil,
        record: (outcome: DictationRecord.Outcome, error: String?)? = nil,
        history: HistoryWrite? = nil,
        completion: DictationCompletion? = nil
    ) {
        silencer.recordingEnded()
        effects.pressEnded()
        switch terminal {
        case .cancel: machine.cancel()
        case .finish(let outcome): machine.finish(outcome)
        case .alreadyTransitioned: break
        }
        if let cue {
            effects.end(settings.duringDictation, cue: cue)
        } else if endsQuietly {
            effects.end(settings.duringDictation, cue: nil)
        }
        var state = state
        var hideAfter = hideAfter
        var resumedChoice: Int?
        if let id = session?.choiceId, voiceCommands.resumeChoice(id) {
            if let prompt = commandOutput.prompt, prompt.id == id {
                state = .choice(prompt, status: HUDChannel.choiceWaiting(after: state))
                hideAfter = nil
                resumedChoice = id
            } else {
                voiceCommands.dismissChoice(id)
            }
        }
        if let state {
            hud.present(state)
            if let hideAfter { scheduleHide(after: hideAfter) }
        }
        if let resumedChoice { commandOutput.scheduleExpiry(resumedChoice) }
        if let record { finalizeRecord(outcome: record.outcome, error: record.error) }
        if let history {
            recordHistory(heard: history.heard, transformed: history.transformed, result: history.result,
                          insertion: history.insertion, rewrite: history.rewrite,
                          failureReason: history.failureReason, reported: history.reported,
                          commandStillRunning: history.commandStillRunning,
                          outcome: history.outcome, summary: history.summary, facts: history.facts,
                          onRecorded: history.onRecorded)
        }
        if activeMode?.answersAloud == true { answers?.takeEnded() }
        let engineUsed = activeEngine
        releaseCapturedPlan()
        engines.applyEvictionAfterDictation(engine: engineUsed)
        if let completion { onDictationCompleted?(completion) }
    }

    // Terminal for a take whose microphone went away mid-recording. Keeps whatever was transcribed as
    // `lastResult` so the user can still paste it deliberately, and reports the loss rather than dressing a
    // partial take up as a completed dictation.
    func finishTruncatedCapture(transcript: String) {
        if !transcript.isEmpty { lastResult = transcript }
        let message = transcript.isEmpty
            ? "The microphone stopped. Nothing was recorded."
            : "The microphone stopped, so this dictation is incomplete. Use “Paste last dictation” to insert what was captured."
        log.error("capture lost mid-recording — dictation truncated, nothing inserted")
        finish(machine: .finish(.failed), cue: .error, state: .error(message: message, action: nil),
               hideAfter: 8, record: (.failed, "capture lost mid-recording"))
    }

    func finishError(_ message: String, action: HUDErrorAction? = nil) {
        // A take whose microphone died can also fail downstream — empty transcript, timeout, engine error.
        // The mic is the cause the user can act on, so it wins over the symptom.
        if captureWasLost {
            finishTruncatedCapture(transcript: lastResult ?? "")
            return
        }
        // Eviction awaits any abandoned transcribe's settlement via SerializedEngine, so releasing the
        // press-time-warmed model here can't race the in-flight call; without it a transcribe failure/
        // timeout would pin the model resident until quit (no other terminal re-arms the idle check).
        finish(machine: .finish(.failed), cue: .error, state: .error(message: message, action: action),
               hideAfter: action == nil ? 2 : 8, record: (.failed, message))
    }

    private func finishHelp(mode: Mode?) {
        finish(machine: .finish(.inserted), cue: nil, endsQuietly: true, state: .help(spokenHelp(for: mode)), record: (.command, nil))
        guard hud.lastPresented?.spokenHelp != nil else { return }
        help.shown()
    }

    private func spokenHelp(for mode: Mode?) -> SpokenHelp {
        let stages = plan.postSTTTextStages(for: mode)
        let title = mode?.name ?? currentModeName ?? "Dictation"
        if mode?.source == .selection { return .selection(title: title, answers: mode?.answersAloud == true) }
        if mode?.runsVoiceCommands == true {
            let commands = config.voiceCommands
            return SpokenHelp.voiceCommands(
                title: title, apps: runningAppNames(), places: commands.places, scripts: commands.scripts, stages: stages)
        }
        if mode?.output == .agent {
            let id = session?.agentRecipient?.id ?? agents?.current
            return SpokenHelp.codingAgent(
                title: title, recipient: id.flatMap { agents?.handle(of: $0) }, example: agents?.recordingOrder.first?.handle,
                readsReplies: spokenUpdates?.readsReplies == true, canRepeat: spokenUpdates?.hasReplyToRepeat == true,
                stages: stages)
        }
        return SpokenHelp.dictation(
            title: title, stages: stages, current: mode?.id, eligible: session?.eligibleModes ?? [],
            context: session?.routingContext ?? RoutingContext())
    }

    var canClearHUD: Bool {
        !isBusy && voiceCommands.pendingChoice == nil && hud.lastPresented?.isPassive != false
    }

    func clearPassiveHUD() {
        guard canClearHUD else { return }
        hideTask?.cancel()
        help.release()
        if let shown = hud.lastPresented, shown != .hidden { hud.present(.hidden) }
    }

    private func scheduleHide(after seconds: Double = 2) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, !isBusy, voiceCommands.pendingChoice == nil else { return }
            if settingsReplacedPending { return announceSettingsReplaced() }
            hud.present(.hidden)
        }
    }
}

extension DictationController: VoiceCommandHost {
    var isArming: Bool { machine.state == .arming }
    var takeStarts: Int { dictationStarts }
    var answeringChoiceId: Int? { session?.choiceId }
    var voiceCommandsEnabled: Bool { settings.features.isEnabled(.voiceCommands) }
    var voiceCommandsAvailable: Bool {
        voiceCommandsEnabled && config.modes.contains { $0.runsVoiceCommands && $0.enabled }
    }
    var savedCommands: VoiceCommandConfig { config.voiceCommands }
    var voiceCommandShortcut: String? {
        plan.modes.first { $0.runsVoiceCommands }?.triggerKeys.first(where: \.startsDictation)
            .flatMap { try? KeyDescriptor(parsing: $0.key) }?.displayString
    }
    func cancelTake() { cancel() }
    func whenIdle(_ work: @escaping () -> Void) { runWhenIdle(work) }
    func hide(after seconds: Double) { scheduleHide(after: seconds) }
    func alert(_ cue: DuringDictationEffects.EndCue) { effects.alert(settings.duringDictation, cue: cue) }
}

extension DictationController: EngineKeeperHost {
    var isCapturingAudio: Bool { machine.isCapturingAudio }
    var engineSettings: Settings { settings }
    var warmupPlan: ResolvedConfig { plan }
    var activeProviderEngine: any SpeechEngine { provider.active }
    func releaseWarmCapture() { audio.releaseWarm() }
}

extension DictationController: AgentTakeHost {
    var codingAgentsEnabled: Bool { settings.features.isEnabled(.codingAgents) }
    var takeIdentity: AnyObject? { session?.identity }
    var takeMode: Mode? { activeMode }
    var eligibleModes: [Mode]? { session?.eligibleModes }
    var takePlan: ResolvedConfig { plan }
    var captureOrigin: VoiceCommandOrigin? { capturedSnapshot.flatMap(Self.origin) }
    var stoppedAtLimit: Bool { session?.stoppedAtLimit == true }
    var voiceCommandStopsAtPress: Int? { session?.voiceCommandStopsAtPress }
    var spokenEdits: String? {
        get { session?.spokenEdits } set { session?.spokenEdits = newValue }
    }
    var agentSnapshot: AgentSnapshot? {
        get { session?.agentSnapshot } set { session?.agentSnapshot = newValue }
    }
    var agentRecipient: AgentRecipient.Frozen? {
        get { session?.agentRecipient } set { session?.agentRecipient = newValue }
    }
    var agentFrontCutoff: ContinuousClock.Instant? { session?.agentFrontCutoff }
    func noteAgentDestination(_ id: String, facts: [HistoryEntry.Fact]) {
        session?.agentDestination = id
        session?.agentFacts = facts
    }
    func redrawRecordingHUD() {
        if case .recording = machine.state {
            hud.present(recordingHUD(level: max(0, lastRenderedLevel)))
        }
    }
    func rememberResult(_ text: String) { lastResult = text }
    func rewriteAndDeliver(_ routed: PhaseBResult, mode: Mode, to id: String, facts: [HistoryEntry.Fact], heard: String) async {
        let (final, rewrite, transformed) = await produceFinalText(routed: routed, mode: mode)
        if Task.isCancelled { return }
        await dispatch(final, to: .agent(id: id, facts: facts), heard: heard, transformed: transformed, rewrite: rewrite)
    }
    func cancelQuietly() {
        if machine.isBusy { finish(machine: .cancel, cue: .cancel, state: .hidden) }
    }
}
