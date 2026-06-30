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
        supportDir: URL = KeyScribePaths.supportDir,
        modesDir: URL = KeyScribePaths.modesDir,
        saveAPIKey: @escaping (String, String) -> Bool = { KeychainStore.set($1, for: $0) && KeychainStore.has($0) },
        testConnection: @escaping (Connection) async -> ConnectionTestState = { await ConnectionTester().test($0) },
        onRelaunch: @escaping () -> Void = {},
        tapActive: @escaping () -> Bool = { true },
        onComplete: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        model = FirstRunModel(
            initialEngineId: initialEngineId, download: download,
            selectEngine: selectEngine, permissionsOnly: permissionsOnly,
            supportDir: supportDir, modesDir: modesDir, saveAPIKey: saveAPIKey,
            testConnection: testConnection, onComplete: onComplete)
        super.init()
        model.onReadyToDictate = onReadyToDictate
        model.onRelaunch = onRelaunch
        model.tapActive = tapActive
    }

    // Bridges a real dictation outcome from the live pipeline into the trial gate.
    func noteDictation(_ outcome: DictationOutcome) { model.noteDictation(outcome) }

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
        // The permission relaunch spawns this instance in the background while System Settings is still
        // frontmost. A background-launched .accessory app usually cannot take focus from inside
        // applicationDidFinishLaunching, so the activate above is a no-op and the wizard stays hidden
        // behind the frontmost app — looking, to the user, like it never reappeared. Re-assert once the
        // launch settles, with orderFrontRegardless so the window surfaces even if activation is denied.
        Task { @MainActor [weak self] in
            guard let window = self?.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    // Single teardown for both the finish-the-flow path and a manual window close: stop the permission
    // poll (its task strongly retains the model, so without this a window closed on the permissions step
    // keeps the whole onboarding graph alive doing 1 Hz work for the process lifetime) and run onComplete
    // once. Idempotent — the normal finish closes the window, which re-enters here via windowWillClose.
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
    enum Step { case intro, model, permissions, tryIt, aiService, aiServiceComplete }

    @Published var step: Step = .intro
    @Published var downloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var micStatus: PermissionStatus = .notDetermined
    @Published var axStatus: PermissionStatus = .notDetermined
    @Published var trialText = ""
    @Published var trialSucceeded = false
    @Published var selectedEngineId: String
    @Published var aiServiceName = Connection.Provider.openai.defaultName
    @Published var aiProvider: Connection.Provider = .openai
    @Published var aiModel = Connection.Provider.openai.defaultModel
    @Published var aiBaseURL = ""
    @Published var aiAuthMethod: Connection.AuthMethod = .apiKey
    @Published var aiAPIKey = ""
    @Published var aiTokenCommand = ""
    @Published private(set) var aiAvailableModels: [String] = []
    @Published private(set) var aiModelDiscoveryError: String?
    @Published private(set) var aiFetchingModels = false
    @Published private(set) var aiSetupError: String?
    @Published private(set) var aiTesting = false

    let catalog = EngineRegistry.availableCatalog
    var appleSpeechAvailable: Bool { catalog.contains { $0.id == "apple" } }
    let permissionsOnly: Bool
    private let download: (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void
    private let selectEngine: (String) -> Void
    private let supportDir: URL
    private let modesDir: URL
    private let saveAPIKey: (String, String) -> Bool
    private let testConnection: (Connection) async -> ConnectionTestState
    private let listModels: (Connection, String?) async throws -> [String]
    private var pendingConnectionId: String?
    private let starterModeIdsEnabledOnFirstAIConnection: Set<String> = ["polish", "message", "email", "edit-selection"]
    var onComplete: () -> Void
    var onReadyToDictate: () -> Void = {}
    var onRelaunch: () -> Void = {}
    var tapActive: () -> Bool = { true }
    @Published var needsRelaunch = false
    private var pollTask: Task<Void, Never>?

    init(
        initialEngineId: String,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void,
        selectEngine: @escaping (String) -> Void,
        permissionsOnly: Bool = false,
        supportDir: URL = KeyScribePaths.supportDir,
        modesDir: URL = KeyScribePaths.modesDir,
        saveAPIKey: @escaping (String, String) -> Bool = { KeychainStore.set($1, for: $0) && KeychainStore.has($0) },
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
        self.supportDir = supportDir
        self.modesDir = modesDir
        self.saveAPIKey = saveAPIKey
        self.testConnection = testConnection
        self.listModels = listModels
        self.onComplete = onComplete
        refreshStatuses()
        if permissionsOnly {
            step = .permissions
            startPolling()
        }
    }

    // Accessibility verdicts are cached for the process lifetime, so a fresh grant only takes effect
    // on relaunch. The nuclear setup flow ends by relaunching into itself.
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
        Task {
            do {
                try await download(id) { progress in
                    // Coalesce to whole-percent changes: the SDK can emit progress far faster than the
                    // bar needs, and each publish re-renders the install view.
                    Task { @MainActor in
                        guard Int(progress.fraction * 100) != Int(self.downloadProgress * 100) else { return }
                        self.downloadProgress = progress.fraction
                    }
                }
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
    func noteDictation(_ outcome: DictationOutcome) {
        if case .inserted = outcome { trialSucceeded = true }
    }

    func requestMicrophone() {
        Task {
            _ = await Permissions.requestMicrophone()
            refreshStatuses()
        }
    }

    // The system consent dialog is the single grant action: its "Open System Settings" button does the
    // navigation and registers KeyScribe in the Accessibility list. Do NOT also open System Settings here —
    // a second window stealing focus leaves the consent dialog stranded behind it, which the user then has
    // to dismiss with "Deny" after granting. The deep-link is the row's separate "Open System Settings"
    // button instead (used when a prior denial means the prompt no longer fires).
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

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    var allPermissionsGranted: Bool {
        micStatus == .granted && axStatus == .granted
    }

    // Leaving the permissions step. `onReadyToDictate` retries the modifier-key tap in this process; if
    // the just-granted Accessibility verdict was cached as denied at launch the tap stays dead, so the
    // trial step (its only trigger is that tap) can't be completed — funnel to a relaunch instead.
    func continueFromPermissions() {
        onReadyToDictate()
        if tapActive() {
            step = .tryIt
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

    var aiModeNames: [String] {
        modesToConnect().map(\.name)
    }

    var aiCanConnect: Bool {
        let name = aiServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || model.isEmpty { return false }
        return aiCredentialReady
    }

    var aiCanFetchModels: Bool {
        aiCredentialReady
    }

    var aiModelFetchDisabledReason: String? {
        guard !aiFetchingModels, !aiCanFetchModels else { return nil }
        return aiCredentialDisabledReason(action: "fetching models")
    }

    private var aiCredentialReady: Bool {
        let base = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if aiProvider == .openaiCompatible, base.isEmpty { return false }
        switch aiEffectiveAuthMethod {
        case .none:
            return true
        case .apiKey:
            return !aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .tokenCommand:
            return !aiTokenCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func aiCredentialDisabledReason(action: String) -> String? {
        let base = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if aiProvider == .openaiCompatible, base.isEmpty {
            return "Base URL is required before \(action)."
        }
        switch aiEffectiveAuthMethod {
        case .none:
            return nil
        case .apiKey:
            return aiProvider == .openaiCompatible
                ? "Enter an API key or choose No Auth before \(action)."
                : "API key is required before \(action)."
        case .tokenCommand:
            return "Token command is required before \(action)."
        }
    }

    var aiEffectiveAuthMethod: Connection.AuthMethod {
        if aiProvider != .openaiCompatible, aiAuthMethod == .none { return .apiKey }
        return aiAuthMethod
    }

    private var aiRequestAPIKey: String? {
        guard aiEffectiveAuthMethod == .apiKey else { return nil }
        let key = aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func fetchAIModels() async {
        aiModelDiscoveryError = nil
        aiFetchingModels = true
        defer { aiFetchingModels = false }
        do {
            let models = try await listModels(aiDraftConnection(), aiRequestAPIKey)
            aiAvailableModels = models
            if !models.isEmpty && !models.contains(aiModel.trimmingCharacters(in: .whitespacesAndNewlines)) {
                aiModel = models[0]
            }
        } catch {
            let message = (error as? ModelListError)?.description ?? error.localizedDescription
            aiModelDiscoveryError = "Could not fetch models: \(message)"
        }
    }

    func resetAIModelDiscovery() {
        aiAvailableModels = []
        aiModelDiscoveryError = nil
    }

    func createAIService() async {
        aiSetupError = nil
        let existing = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        let name = aiServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reuse the id across retries so a failure after the connection is written doesn't accumulate
        // duplicate connections on the next attempt.
        let id = pendingConnectionId ?? ConnectionStore.newID(for: name, existing: existing.map(\.id))
        pendingConnectionId = id
        let keyRef = "keyscribe.llm.\(id)"
        let connection = aiConnection(id: id, keyRef: keyRef)
        let key = aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if connection.authMethod == .apiKey, key.isEmpty {
            aiSetupError = "API key is required."
            return
        }
        if connection.authMethod == .apiKey, !saveAPIKey(keyRef, key) {
            aiSetupError = "Could not save the API key to the Keychain."
            return
        }
        aiTesting = true
        let result = await testConnection(connection)
        aiTesting = false
        if case .failed(let message) = result {
            aiSetupError = "Connection test failed: \(message)"
            return
        }
        do {
            let others = existing.filter { $0.id != id }
            try ConnectionStore.write(ConnectionSet(connections: others + [connection]), to: supportDir)
        } catch {
            aiSetupError = "Could not save the AI service: \(error.localizedDescription)"
            return
        }
        let unlinked = connectStarterModes(to: id)
        if !unlinked.isEmpty {
            aiSetupError = "Connected \(name), but could not link \(unlinked.joined(separator: ", ")). You can link them in Settings."
            return
        }
        step = .aiServiceComplete
    }

    private func aiDraftConnection() -> Connection {
        let id = pendingConnectionId ?? "new-ai-service"
        return aiConnection(id: id, keyRef: "keyscribe.llm.\(id)")
    }

    private func aiConnection(id: String, keyRef: String) -> Connection {
        let authMethod = aiEffectiveAuthMethod
        let command = aiTokenCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        var connection = Connection(
            id: id,
            name: aiServiceName.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: aiProvider,
            model: aiModel.trimmingCharacters(in: .whitespacesAndNewlines),
            keyRef: keyRef,
            authMethod: authMethod,
            tokenCommand: authMethod == .tokenCommand && !command.isEmpty ? command : nil)
        if aiProvider == .openaiCompatible {
            connection.baseUrl = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return connection
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
            do { try ModeStore.write(mode, to: modesDir) }
            catch { failed.append(mode.name) }
        }
        return failed
    }
}

enum Permission {
    case microphone
    case accessibility
}
