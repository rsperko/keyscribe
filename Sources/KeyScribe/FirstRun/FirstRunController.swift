import AppKit
import KeyScribeKit
import SwiftUI

@MainActor
final class FirstRunController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: FirstRunModel
    private let onComplete: () -> Void
    private var finished = false

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
            deleteAPIKey: deleteAPIKey,
            testConnection: testConnection, onComplete: onComplete)
        super.init()
        model.onReadyToDictate = onReadyToDictate
        model.onRelaunch = onRelaunch
        model.tapActive = tapActive
    }

    func noteDictation(_ completion: DictationCompletion) { model.noteDictation(completion) }

    func present() {
        let hosting = NSHostingController(rootView: FirstRunView(model: model))
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
        // applicationDidFinishLaunching, so the activate above is a no-op and the wizard stays hidden. Re-
        // assert once the launch settles, with orderFrontRegardless so it surfaces even if activation is denied.
        Task { @MainActor [weak self] in
            guard let window = self?.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    // Single teardown for both finish and manual close: stop the permission poll (its task strongly retains
    // the model, so without this a window closed on the permissions step keeps the onboarding graph alive
    // doing 1 Hz work forever) and run onComplete once. Idempotent — finish closes the window, re-entering
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

    struct PlaygroundLesson: Identifiable, Equatable {
        let modeId: String
        let title: String
        let invocation: String
        let hint: String
        var id: String { modeId }
    }

    struct LessonOutcome: Equatable {
        let before: String
        let after: String
    }

    @Published var step: Step = .intro
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
    @Published private(set) var aiSetupError: String?
    @Published private(set) var aiTesting = false

    let catalog = EngineRegistry.availableCatalog
    var appleSpeechAvailable: Bool { catalog.contains { $0.id == "apple" } }
    let permissionsOnly: Bool
    private let download: (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void
    private let selectEngine: (String) -> Void
    private let repository: ConfigRepository
    private var supportDir: URL { repository.supportDir }
    private var modesDir: URL { repository.modesDir }
    private let saveAPIKey: (String, String) -> Bool
    private let deleteAPIKey: (String) -> Void
    private let testConnection: (Connection) async -> ConnectionTestState
    private let listModels: (Connection, String?) async throws -> [String]
    private var pendingConnectionId: String?
    private let starterModeIdsEnabledOnFirstAIConnection: Set<String> = ["polish", "edit-selection"]
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
        permissionsOnly: Bool = false,
        resumeOnboarding: Bool = false,
        repository: ConfigRepository,
        saveAPIKey: @escaping (String, String) -> Bool = { KeychainStore.set($1, for: $0) && KeychainStore.has($0) },
        deleteAPIKey: @escaping (String) -> Void = { KeychainStore.delete($0) },
        testConnection: @escaping (Connection) async -> ConnectionTestState = { await ConnectionTester().test($0) },
        listModels: @escaping (Connection, String?) async throws -> [String] = {
            try await HTTPModelLister().listModels(for: $0, apiKey: $1)
        },
        onComplete: @escaping () -> Void
    ) {
        self.selectedEngineId = initialEngineId
        self.download = download
        self.selectEngine = selectEngine
        self.permissionsOnly = permissionsOnly
        self.repository = repository
        self.saveAPIKey = saveAPIKey
        self.deleteAPIKey = deleteAPIKey
        self.testConnection = testConnection
        self.listModels = listModels
        self.onComplete = onComplete
        refreshStatuses()
        if permissionsOnly {
            step = .permissions
            startPolling()
        } else if resumeOnboarding {
            // Relaunched from the permissions funnel: `continueFromPermissions` saw a dead modifier tap (a
            // fresh Accessibility grant is cached as denied until relaunch). Grants are proven (Continue is
            // gated on them); this fresh process reads them and starts the tap. Resume at the AI-service step
            // (ui_design §2 steps 4–5), not the permissions-only Done, which ended onboarding early (P2-21).
            step = .aiService
        }
    }

    // Accessibility verdicts are cached for the process lifetime, so a fresh grant takes effect only on
    // relaunch. The nuclear setup flow ends by relaunching into itself.
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
                // Wizard closed mid-download → don't switch the engine after a user-perceived cancel (P1-9
                // class). The install finishes; only the switch + step advance are gated.
                guard !Task.isCancelled else { downloading = false; return }
                selectEngine(id)
                downloading = false
                step = .permissions
            } catch {
                downloadError = "Download failed. Check your connection and try again."
                downloading = false
            }
        }
    }

    // ui_design.md §2: onboarding ends after one real successful dictation, not after typing.
    func noteDictation(_ completion: DictationCompletion) {
        guard case .inserted = completion.outcome else { return }
        trialSucceeded = true
        guard step == .playground else { return }
        let completedModeId = completion.modeId ?? (activePlaygroundLessonId == Mode.directId ? Mode.directId : nil)
        guard let modeId = completedModeId,
              playgroundLessons.contains(where: { $0.modeId == modeId }) else { return }
        completedLessons[modeId] = LessonOutcome(before: completion.heard, after: completion.finalText)
        finishedPlaygroundLessonIds.insert(modeId)
    }

    func enterPlayground() {
        playgroundLessons = buildPlaygroundLessons()
        guard !playgroundLessons.isEmpty else { finish(); return }
        completedLessons = [:]
        finishedPlaygroundLessonIds = []
        playgroundText = ""
        activePlaygroundLessonId = playgroundLessons.first?.modeId
        step = .playground
    }

    private func buildPlaygroundLessons() -> [PlaygroundLesson] {
        let connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        let modes = ModeStore.loadAll(in: modesDir)
        let rewriteLessons: [PlaygroundLesson] = Self.playgroundLessonOrder.compactMap { seedId in
            guard let mode = modes.first(where: { $0.seedId == seedId }), mode.enabled,
                  let connection = mode.aiRewrite?.connection, !connection.isEmpty,
                  connections.contains(where: { $0.id == connection }),
                  let invocation = Self.invocation(for: mode) else { return nil }
            return PlaygroundLesson(
                modeId: mode.id, title: mode.name, invocation: invocation,
                hint: Self.playgroundHints[seedId] ?? "")
        }
        guard !rewriteLessons.isEmpty else { return [] }
        return [
            PlaygroundLesson(
                modeId: Mode.directId,
                title: "Dictation",
                invocation: "Hold Fn (Globe) and speak",
                hint: "Say one sentence. Try saying \"insert new line\" in the middle to add a line break."),
        ] + rewriteLessons
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

    func skipAISetup() {
        step = .tryIt
    }

    func changeAIProvider(from _: Connection.Provider, to provider: Connection.Provider) {
        aiDraft.changeProvider(
            to: provider,
            defaultOpenAICompatibleAuth: .apiKey,
            hasStoredKey: false,
            updateDefaultName: true)
    }

    private static let playgroundLessonOrder = ["polish", "edit-selection"]

    private static let playgroundHints: [String: String] = [
        "polish": "Try: \"Um I think we should maybe send the notes tomorrow because the meeting moved.\" Then hold Right Option and speak.",
        "edit-selection": "The sentence above is selected for you. Hold Right Command and say \"make this shorter.\"",
    ]

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

    // Let the system consent dialog drive the grant action. Opening System Settings here can steal focus
    // from the consent dialog; the row has a separate deep-link for manual repair.
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

    // These tasks strongly retain the model and mutate config on completion (connect writes the connection +
    // enables modes; download switches the engine). Cancelling on teardown keeps a closed wizard from
    // silently connecting an AI service or switching the STT engine after the user walked away.
    func stopPolling() {
        pollTask?.cancel(); pollTask = nil
        setupTask?.cancel(); setupTask = nil
        downloadTask?.cancel(); downloadTask = nil
    }

    // Held in setupTask so the in-flight test/write can be cancelled when the wizard closes (see
    // createAIService's post-test guard); a bare detached Task would let a slow test mutate config after a
    // user-perceived cancel.
    func connect() {
        setupTask?.cancel()
        setupTask = Task { @MainActor [weak self] in await self?.createAIService() }
    }

    var allPermissionsGranted: Bool {
        micStatus == .granted && axStatus == .granted
    }

    // Leaving the permissions step. `onReadyToDictate` retries the modifier-key tap; if the just-granted
    // Accessibility verdict was cached as denied at launch the tap stays dead and the trial step (only
    // triggered by that tap) can't complete — funnel to a relaunch instead.
    func continueFromPermissions() {
        onReadyToDictate()
        if tapActive() {
            step = .aiService
        } else {
            needsRelaunch = true
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
        let existing = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        let name = aiDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = pendingConnectionId ?? ConnectionStore.newID(for: name, existing: existing.map(\.id))
        pendingConnectionId = id
        let keyRef = "keyscribe.llm.\(id)"
        let connection = aiDraft.connection(id: id, keyRef: keyRef)
        let key = aiDraft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if connection.authMethod == .apiKey, key.isEmpty {
            aiSetupError = "API key is required."
            return
        }
        if connection.authMethod == .apiKey, !saveAPIKey(keyRef, key) {
            aiSetupError = "Could not save the API key."
            return
        }
        aiTesting = true
        let result = await testConnection(connection)
        aiTesting = false
        // Wizard may have closed while the test was in flight (connect()'s task cancelled in stopPolling).
        // Don't write the connection or enable modes after a user-perceived cancel, and drop the key saved
        // before the test so it doesn't strand under an unreferenced id.
        if Task.isCancelled {
            if connection.authMethod == .apiKey { deleteAPIKey(keyRef) }
            return
        }
        if case .failed(let message) = result {
            if connection.authMethod == .apiKey { deleteAPIKey(keyRef) }
            aiSetupError = "Connection test failed: \(message)"
            return
        }
        do {
            try repository.upsertConnection(connection)
        } catch {
            if connection.authMethod == .apiKey { deleteAPIKey(keyRef) }
            aiSetupError = "Could not save the AI service: \(error.localizedDescription)"
            return
        }
        let unlinked = connectStarterModes(to: id)
        if !unlinked.isEmpty {
            aiSetupError = "Connected \(name), but could not link \(unlinked.joined(separator: ", ")). You can link them in Settings."
            return
        }
        enterPlayground()
    }

    private func aiDraftConnection() -> Connection {
        let id = pendingConnectionId ?? "new-ai-service"
        return aiDraft.connection(id: id, keyRef: "keyscribe.llm.\(id)")
    }

    private func modesToConnect() -> [Mode] {
        let connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        return ModeStore.loadAll(in: modesDir).filter { mode in
            guard let seedId = mode.seedId, starterModeIdsEnabledOnFirstAIConnection.contains(seedId),
                  let rewrite = mode.aiRewrite else { return false }
            return rewrite.connection.isEmpty || !connections.contains { $0.id == rewrite.connection }
        }
    }

    private func connectStarterModes(to connectionId: String) -> [String] {
        var failed: [String] = []
        for var mode in modesToConnect() {
            guard var rewrite = mode.aiRewrite else { continue }
            rewrite.connection = connectionId
            mode.aiRewrite = rewrite
            mode.enabled = true
            do { try repository.writeMode(mode) }
            catch { failed.append(mode.name) }
        }
        return failed
    }
}

enum Permission {
    case microphone
    case accessibility
}
