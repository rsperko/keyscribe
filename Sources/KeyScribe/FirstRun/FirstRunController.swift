import AppKit
import KeyScribeKit
import SwiftUI

@MainActor
final class FirstRunController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: FirstRunModel
    private let onComplete: () -> Void
    private var finished = false
    // Suspends the global hotkey monitor while the trial's ShortcutWell captures, so holding a modifier to
    // record it never starts a dictation mid-capture (AppDelegate wires `onChange` to `hotkey.isSuspended`).
    let recordingState = HotkeyRecordingState()

    init(
        initialEngineId: String,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void,
        selectEngine: @escaping (String) -> Void,
        onReadyToDictate: @escaping () -> Void,
        permissionsOnly: Bool = false,
        resumeOnboarding: Bool = false,
        repository: ConfigRepository,
        saveAPIKey: @escaping (String, String) -> Bool = { KeychainStore.set($1, for: $0) && KeychainStore.has($0) },
        deleteAPIKey: @escaping (String) -> Void = { KeychainStore.delete($0) },
        readAPIKey: @escaping (String) -> String? = { KeychainStore.get($0) },
        testConnection: @escaping (Connection) async -> ConnectionTestState = { await ConnectionTester().test($0) },
        onRelaunch: @escaping () -> Void = {},
        tapActive: @escaping () -> Bool = { true },
        onComplete: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        model = FirstRunModel(
            initialEngineId: initialEngineId, download: download,
            selectEngine: selectEngine, permissionsOnly: permissionsOnly,
            resumeOnboarding: resumeOnboarding,
            repository: repository, saveAPIKey: saveAPIKey,
            deleteAPIKey: deleteAPIKey, readAPIKey: readAPIKey,
            testConnection: testConnection, onComplete: onComplete)
        super.init()
        model.onReadyToDictate = onReadyToDictate
        model.onRelaunch = onRelaunch
        model.tapActive = tapActive
    }

    func noteDictation(_ completion: DictationCompletion) { model.noteDictation(completion) }

    func present() {
        let hosting = NSHostingController(
            rootView: FirstRunView(model: model).environmentObject(recordingState))
        let window = NSWindow(contentViewController: hosting)
        window.title = model.permissionsOnly ? "Set Up Permissions" : "Welcome to \(Branding.appName)"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 500))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        AppActivationPolicy.pushRegular()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        model.onComplete = { [weak self] in self?.complete() }
        // The permission relaunch spawns this in the background while System Settings is frontmost. A
        // background-launched .accessory app usually can't take focus from inside
        // applicationDidFinishLaunching, so the activate above is a no-op and the wizard stays hidden —
        // re-assert once the launch settles, with orderFrontRegardless so it surfaces even if activation
        // is denied.
        Task { @MainActor [weak self] in
            guard let window = self?.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    // Single teardown for both finish and manual close. Stopping the permission poll matters: its task
    // strongly retains the model, so without this a window closed on the permissions step keeps the
    // onboarding graph alive doing 1 Hz work forever. Idempotent — finish closes the window, re-entering
    // here via windowWillClose.
    private func complete() {
        guard !finished else { return }
        finished = true
        model.stopPolling()
        window?.delegate = nil
        let closing = window
        window = nil
        closing?.close()
        AppActivationPolicy.popRegular()
        onComplete()
    }

    func windowWillClose(_ notification: Notification) { complete() }
}

@MainActor
final class FirstRunModel: ObservableObject {
    enum Step { case intro, model, permissions, tryIt, aiService, playground }

    // Playground shares the last dot with the AI step — it is that step's reward, not a sixth obligation.
    // The indicator is hidden entirely in the permissions-only flow.
    static let stepCount = 5
    var stepIndex: Int {
        switch step {
        case .intro: return 0
        case .model: return 1
        case .permissions: return 2
        case .tryIt: return 3
        case .aiService, .playground: return 4
        }
    }

    struct PlaygroundLesson: Identifiable, Equatable {
        let modeId: String
        let title: String
        let invocation: String
        let hint: String
        var triggerKey: String?
        var id: String { modeId }
    }

    struct LessonOutcome: Equatable {
        let before: String
        let after: String
    }

    @Published var step: Step = .intro {
        didSet {
            if step == .tryIt || step == .playground { refreshDirectTrigger() }
        }
    }
    @Published var downloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var micStatus: PermissionStatus = .notDetermined
    @Published var axStatus: PermissionStatus = .notDetermined
    @Published var trialText = ""
    @Published var trialSucceeded = false
    @Published var playgroundText = ""
    @Published private(set) var playgroundLessons: [PlaygroundLesson] = []
    @Published private(set) var completedLessons: [String: LessonOutcome] = [:]
    @Published private(set) var finishedPlaygroundLessonIds: Set<String> = []
    @Published private(set) var activePlaygroundLessonId: String?
    @Published private(set) var playgroundReseedToken = 0
    @Published var selectedEngineId: String
    @Published var aiDraft = AIConnectionDraft()
    @Published var aiOfferExpanded = false
    @Published private(set) var aiSetupError: String?
    @Published private(set) var aiTesting = false
    @Published private(set) var directTrigger: KeyDescriptor?
    @Published private(set) var directTriggerStyle: String?
    @Published private(set) var triggerSaveError: String?
    private var rememberedTriggerStyle: String?
    private var rememberedTriggerThreshold: Int?

    let catalog = EngineRegistry.availableCatalog
    var appleSpeechAvailable: Bool { catalog.contains { $0.id == "apple" } }
    let permissionsOnly: Bool
    private let download: (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void
    // Removes a partially-downloaded model's files when a download fails or is cancelled, so the next
    // attempt starts clean instead of choking on (or silently trusting) half-written weights. Guarded on
    // the model not already being installed so a completed prior install is never wiped.
    private let cleanupFailedDownload: (String) -> Void
    private let selectEngine: (String) -> Void
    private let repository: ConfigRepository
    private var supportDir: URL { repository.supportDir }
    private var modesDir: URL { repository.modesDir }
    private let saveAPIKey: (String, String) -> Bool
    private let deleteAPIKey: (String) -> Void
    private let readAPIKey: (String) -> String?
    private let testConnection: (Connection) async -> ConnectionTestState
    private let listModels: (Connection, String?) async throws -> [String]
    private var pendingConnectionId: String?
    private static let headlineSeedIds = ["polish", "edit-selection"]
    var onComplete: () -> Void
    var onReadyToDictate: () -> Void = {}
    var onRelaunch: () -> Void = {}
    var tapActive: () -> Bool = { true }
    @Published var needsRelaunch = false
    private var pollTask: Task<Void, Never>?
    private(set) var setupTask: Task<Void, Never>?
    private(set) var downloadTask: Task<Void, Never>?

    var aiServiceName: String {
        get { aiDraft.name }
        set { aiDraft.name = newValue }
    }

    var aiProvider: Connection.Provider {
        get { aiDraft.provider }
        set { aiDraft.provider = newValue }
    }

    var aiModel: String {
        get { aiDraft.model }
        set { aiDraft.model = newValue }
    }

    var aiBaseURL: String {
        get { aiDraft.baseURL }
        set { aiDraft.baseURL = newValue }
    }

    var aiAuthMethod: Connection.AuthMethod {
        get { aiDraft.authMethod }
        set { aiDraft.authMethod = newValue }
    }

    var aiAPIKey: String {
        get { aiDraft.apiKey }
        set { aiDraft.apiKey = newValue }
    }

    var aiTokenCommand: String {
        get { aiDraft.tokenCommand }
        set { aiDraft.tokenCommand = newValue }
    }

    var aiModelDiscoveryError: String? { aiDraft.modelDiscoveryError }

    init(
        initialEngineId: String,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void,
        selectEngine: @escaping (String) -> Void,
        cleanupFailedDownload: @escaping (String) -> Void = { id in
            guard !ModelInstallStore.installedIds().contains(id) else { return }
            ModelInstallStore.removeFiles(for: id)
        },
        permissionsOnly: Bool = false,
        resumeOnboarding: Bool = false,
        repository: ConfigRepository,
        saveAPIKey: @escaping (String, String) -> Bool = { KeychainStore.set($1, for: $0) && KeychainStore.has($0) },
        deleteAPIKey: @escaping (String) -> Void = { KeychainStore.delete($0) },
        readAPIKey: @escaping (String) -> String? = { KeychainStore.get($0) },
        testConnection: @escaping (Connection) async -> ConnectionTestState = { await ConnectionTester().test($0) },
        listModels: @escaping (Connection, String?) async throws -> [String] = {
            try await HTTPModelLister().listModels(for: $0, apiKey: $1)
        },
        onComplete: @escaping () -> Void
    ) {
        self.selectedEngineId = initialEngineId
        self.download = download
        self.cleanupFailedDownload = cleanupFailedDownload
        self.selectEngine = selectEngine
        self.permissionsOnly = permissionsOnly
        self.repository = repository
        self.saveAPIKey = saveAPIKey
        self.deleteAPIKey = deleteAPIKey
        self.readAPIKey = readAPIKey
        self.testConnection = testConnection
        self.listModels = listModels
        self.onComplete = onComplete
        refreshStatuses()
        refreshDirectTrigger()
        if permissionsOnly {
            step = .permissions
            startPolling()
        } else if resumeOnboarding {
            // Relaunched from the permissions funnel: `continueFromPermissions` saw a dead modifier tap (a
            // fresh Accessibility grant is cached as denied until relaunch). Grants are proven (Continue is
            // gated on them); this fresh process reads them and starts the tap. Resume at the trial, whose
            // modifier tap the relaunch was meant to revive — the AI offer follows it.
            step = .tryIt
        }
    }

    // Accessibility verdicts are cached for the process lifetime, so a fresh grant takes effect only on
    // relaunch — this ends the setup flow by relaunching into itself.
    func relaunch() {
        stopPolling()
        onRelaunch()
    }

    var selectedInfo: SpeechModelInfo? { SpeechModelCatalog.entry(for: selectedEngineId) }

    func skipModelDownload() {
        if catalog.contains(where: { $0.id == "apple" && $0.systemManaged }) {
            selectEngine("apple")
        }
        step = .permissions
    }

    func beginDownload() {
        downloading = true
        downloadError = nil
        downloadProgress = 0
        let id = selectedEngineId
        downloadTask = Task {
            do {
                try await download(id) { progress in
                    // Coalesce to whole-percent changes: the SDK emits progress faster than the bar needs,
                    // and each publish re-renders the install view.
                    Task { @MainActor in
                        guard Int(progress.fraction * 100) != Int(self.downloadProgress * 100) else { return }
                        self.downloadProgress = progress.fraction
                    }
                }
                // Wizard closed mid-download → don't switch the engine after a user-perceived cancel. The
                // install finishes; only the switch + step advance are gated.
                guard !Task.isCancelled else { downloading = false; return }
                selectEngine(id)
                downloading = false
                step = .permissions
            } catch {
                // A failed or cancelled download leaves partial weights on disk. Left behind, they wedge
                // the next attempt (the SDK may trust or trip over them), and there is no delete affordance
                // for a model that was never marked installed — the "can't recover without switching
                // models" trap. Wipe them so retry is clean.
                cleanupFailedDownload(id)
                downloadError = "Download failed. Check your connection and try again."
                downloading = false
            }
        }
    }

    // ui_design.md §2: onboarding ends after one real successful DICTATION, not after typing in the field.
    func noteDictation(_ completion: DictationCompletion) {
        guard case .inserted = completion.outcome else { return }
        trialSucceeded = true
        guard step == .playground else { return }
        guard let modeId = completion.modeId,
              playgroundLessons.contains(where: { $0.modeId == modeId }) else { return }
        completedLessons[modeId] = LessonOutcome(before: completion.heard, after: completion.finalText)
        finishedPlaygroundLessonIds.insert(modeId)
    }

    func enterPlayground() {
        playgroundLessons = buildPlaygroundLessons()
        guard !playgroundLessons.isEmpty else { finish(); return }
        completedLessons = [:]
        finishedPlaygroundLessonIds = []
        playgroundText = Self.polishExample
        activePlaygroundLessonId = playgroundLessons.first?.modeId
        step = .playground
    }

    private func buildPlaygroundLessons() -> [PlaygroundLesson] {
        let connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        let modes = ModeStore.loadAll(in: modesDir)
        return Self.playgroundLessonOrder.compactMap { seedId in
            guard let mode = modes.first(where: { $0.seedId == seedId }), mode.enabled,
                  let connection = mode.aiRewrite?.connection, !connection.isEmpty,
                  connections.contains(where: { $0.id == connection }),
                  let invocation = Self.invocation(for: mode) else { return nil }
            return PlaygroundLesson(
                modeId: mode.id, title: mode.name, invocation: invocation,
                hint: Self.playgroundHint(for: mode), triggerKey: mode.triggerKeys.first?.key)
        }
    }

    func advancePlayground() {
        guard let activePlaygroundLessonId,
              let index = playgroundLessons.firstIndex(where: { $0.modeId == activePlaygroundLessonId }) else {
            finish()
            return
        }
        finishedPlaygroundLessonIds.insert(activePlaygroundLessonId)
        let nextIndex = playgroundLessons.index(after: index)
        guard nextIndex < playgroundLessons.endIndex else {
            self.activePlaygroundLessonId = nil
            return
        }
        self.activePlaygroundLessonId = playgroundLessons[nextIndex].modeId
        preparePlaygroundTextIfNeeded(for: playgroundLessons[nextIndex].modeId)
    }

    func openPlaygroundLesson(_ id: String) {
        guard playgroundLessons.contains(where: { $0.modeId == id }) else { return }
        activePlaygroundLessonId = id
        preparePlaygroundTextIfNeeded(for: id)
    }

    func isLastPlaygroundLesson(_ id: String) -> Bool {
        playgroundLessons.last?.modeId == id
    }

    func finishWithoutAI() {
        finish()
    }

    // Trial "Continue" and "Skip for now" both land on the AI offer — its own Finish is one click, so
    // nobody is ever more than two clicks from done and the AI step is never skipped invisibly.
    func continueFromTrial() {
        step = .aiService
    }

    private static let playgroundLessonOrder = ["polish", "edit-selection"]
    static let polishExample = "um I think we should maybe send the notes tomorrow because the meeting moved"
    static let polishExamplePolished = "The meeting moved, so let's send the notes tomorrow."
    private static var polishExampleSpoken: String {
        polishExample.prefix(1).uppercased() + polishExample.dropFirst() + "."
    }

    private static func playgroundHint(for mode: Mode) -> String {
        let start: String
        if let key = mode.triggerKeys.first?.key, let descriptor = try? KeyDescriptor(parsing: key) {
            start = "hold \(descriptor.displayString)"
        } else if let phrase = mode.triggerPhrases.first {
            start = "end your sentence with \"\(phrase)\""
        } else {
            start = "use this mode"
        }
        switch mode.seedId {
        case "polish":
            return "Try: \"\(polishExampleSpoken)\" Then \(start) and speak."
        case "edit-selection":
            let startCapitalized = start.prefix(1).uppercased() + start.dropFirst()
            return "The sentence above is selected for you. \(startCapitalized) and say \"make this shorter.\""
        default:
            return ""
        }
    }

    private func preparePlaygroundTextIfNeeded(for lessonId: String) {
        guard lessonId == "edit-selection" else { return }
        playgroundText = "We need to review the long meeting notes, identify the open questions, and decide the next steps before Friday."
        playgroundReseedToken &+= 1
    }

    private static func invocation(for mode: Mode) -> String? {
        if let key = mode.triggerKeys.first?.key, let descriptor = try? KeyDescriptor(parsing: key) {
            return "Hold \(descriptor.displayString) and speak"
        }
        if let phrase = mode.triggerPhrases.first {
            return "End your sentence with \"\(phrase)\""
        }
        return nil
    }

    func requestMicrophone() {
        Task {
            _ = await Permissions.requestMicrophone()
            refreshStatuses()
        }
    }

    // Opening System Settings here can steal focus from the system consent dialog, so let the dialog drive
    // the grant; the row has a separate deep-link for manual repair.
    func requestAccessibility() {
        _ = Permissions.accessibilityStatus(prompt: true)
        refreshStatuses()
    }

    func openAccessibilitySettings() {
        Permissions.openSettings(.accessibility)
    }

    func openMicrophoneSettings() {
        Permissions.openSettings(.microphone)
    }

    func refreshStatuses() {
        micStatus = Permissions.microphoneStatus()
        axStatus = Permissions.accessibilityStatus()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refreshStatuses()
            }
        }
    }

    // These tasks strongly retain the model and mutate config on completion (connect writes the connection
    // + enables modes; download switches the engine). Cancelling on teardown keeps a closed wizard from
    // silently connecting an AI service or switching the STT engine after the user walked away.
    func stopPolling() {
        pollTask?.cancel(); pollTask = nil
        setupTask?.cancel(); setupTask = nil
        downloadTask?.cancel(); downloadTask = nil
    }

    // Held in setupTask so the in-flight test/write can be cancelled when the wizard closes (see
    // createAIService's post-test guard) — a bare detached Task would let a slow test mutate config after
    // a user-perceived cancel.
    func connect() {
        setupTask?.cancel()
        setupTask = Task { @MainActor [weak self] in await self?.createAIService() }
    }

    var allPermissionsGranted: Bool {
        micStatus == .granted && axStatus == .granted
    }

    // `onReadyToDictate` retries the modifier-key tap; if the just-granted Accessibility verdict was
    // cached as denied at launch, the tap stays dead and the trial step (only triggered by that tap) can't
    // complete — funnel to a relaunch instead.
    func continueFromPermissions() {
        onReadyToDictate()
        if tapActive() {
            step = .tryIt
        } else {
            needsRelaunch = true
        }
    }

    var directTriggerDisplay: String { directTrigger?.displayString ?? "Fn (Globe)" }

    // Cached so the trial's instruction sentence and keycap read the resolved trigger without a disk read
    // per render. `loadAll` touches disk, so this runs on entry to the trial/playground (via `step`'s
    // didSet) and after a rebind — never from view code.
    func refreshDirectTrigger() {
        let trigger = ModeStore.loadAll(in: modesDir).first { $0.id == Mode.directId }?.triggerKeys.first
        if let key = trigger?.key {
            directTrigger = try? KeyDescriptor(parsing: key)
        } else {
            directTrigger = nil
        }
        directTriggerStyle = trigger?.pressStyle
    }

    var directTriggerBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.directTrigger?.canonical ?? "" },
            set: { [weak self] in self?.setDirectTrigger($0) })
    }

    // Rewrites `_direct.toml` through the same repository owner Modes uses, so the rebind goes live
    // immediately (configRepository.onChange rebuilds the hotkey monitor). Preserves an existing entry's
    // press style / tap threshold, mirroring ModeTriggerRow.
    func setDirectTrigger(_ key: String) {
        triggerSaveError = nil
        guard var mode = ModeStore.loadAll(in: modesDir).first(where: { $0.id == Mode.directId }) else { return }
        if key.isEmpty {
            if let existing = mode.triggerKeys.first {
                rememberedTriggerStyle = existing.pressStyle
                rememberedTriggerThreshold = existing.tapThresholdMs
            }
            mode.triggerKeys = []
        } else {
            let existing = mode.triggerKeys.first
            mode.triggerKeys = [.init(
                key: key,
                pressStyle: existing?.pressStyle ?? rememberedTriggerStyle ?? "hold-or-tap",
                tapThresholdMs: existing?.tapThresholdMs ?? rememberedTriggerThreshold ?? 250)]
        }
        do {
            try repository.writeMode(mode)
            refreshDirectTrigger()
        } catch {
            triggerSaveError = "Could not save the shortcut."
        }
    }

    var nextPermission: Permission {
        if micStatus != .granted { return .microphone }
        return .accessibility
    }

    func finish() {
        stopPolling()
        onComplete()
    }

    var aiCanConnect: Bool {
        aiDraft.canConnectForSetup
    }

    func fetchAIModels() async {
        aiDraft.modelDiscoveryState = .loading
        do {
            let models = try await listModels(aiDraftConnection(), aiDraft.requestAPIKey)
            aiDraft.applyFetchedModels(models)
        } catch {
            let message = (error as? ProviderTransportError)?.description ?? error.localizedDescription
            aiDraft.modelDiscoveryState = .failed("Could not fetch models: \(message)")
        }
    }

    func createAIService() async {
        aiSetupError = nil
        // Delegate the test-then-save-with-rollback to the shared connector so onboarding and Settings can
        // never diverge. The FirstRun-specific work (linking the headline rewrite modes, entering the
        // playground) stays here.
        let connector = AIServiceConnector(
            repository: repository, saveAPIKey: saveAPIKey, deleteAPIKey: deleteAPIKey,
            readAPIKey: readAPIKey, testConnection: testConnection)
        aiTesting = true
        let result = await connector.connect(draft: aiDraft, reusingId: pendingConnectionId)
        aiTesting = false
        pendingConnectionId = result.allocatedId
        let connection: Connection
        switch result.outcome {
        case .cancelled:
            return
        case .failed(let message):
            aiSetupError = message
            return
        case .connected(let c):
            connection = c
        }
        let unlinked = connectStarterModes(to: connection.id)
        if !unlinked.isEmpty {
            aiSetupError = "Connected \(connection.name), but could not link \(unlinked.joined(separator: ", ")). You can link them in Settings."
            return
        }
        enterPlayground()
    }

    private func aiDraftConnection() -> Connection {
        let id = pendingConnectionId ?? "new-ai-service"
        return aiDraft.connection(id: id, keyRef: "keyscribe.llm.\(id)")
    }

    private var ledgerDir: URL { supportDir.appendingPathComponent("lkg", isDirectory: true) }

    // On the first AI connection, wire up the two headline rewrite modes so the playground can demo them.
    // On a legacy install their files exist (seeded starters) → link + enable in place. On a fresh install
    // they don't exist yet (templates-only) → materialize the template as a `.seed` (keeps seedId, so the
    // playground's seedId lookup and future seed updates both keep working) wired to the new connection.
    private func connectStarterModes(to connectionId: String) -> [String] {
        var failed: [String] = []
        for seedId in Self.headlineSeedIds {
            let onDisk = ModeStore.loadAll(in: modesDir)
            let connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
            if var mode = onDisk.first(where: { $0.seedId == seedId }) {
                guard var rewrite = mode.aiRewrite else { continue }
                let linked = !rewrite.connection.isEmpty && connections.contains { $0.id == rewrite.connection }
                // Already wired to a live connection: leave it exactly as the user has it — don't repoint
                // it at the new service or re-enable a starter they deliberately turned off.
                guard !linked else { continue }
                rewrite.connection = connectionId
                mode.aiRewrite = rewrite
                mode.enabled = true
                do { try repository.writeMode(mode) }
                catch { failed.append(mode.name) }
            } else if let template = ModeStore.templates().first(where: { $0.id == seedId }),
                      case .seed(var mode) = ModeTemplateInstantiation.materialize(
                        template: template, existing: onDisk, connections: connections) {
                mode.aiRewrite?.connection = connectionId
                mode.enabled = true
                do {
                    try repository.writeMode(mode)
                    ModeStore.recordMaterializedSeed(mode, ledgerDir: ledgerDir)
                } catch { failed.append(mode.name) }
            }
        }
        return failed
    }
}

enum Permission {
    case microphone
    case accessibility
}
