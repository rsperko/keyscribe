import AppKit
import KeyScribeKit
import SwiftUI

@MainActor
final class FirstRunController {
    private var window: NSWindow?
    private let model: FirstRunModel
    private let onComplete: () -> Void

    init(
        initialEngineId: String,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void,
        selectEngine: @escaping (String) -> Void,
        onReadyToDictate: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        model = FirstRunModel(
            initialEngineId: initialEngineId, download: download,
            selectEngine: selectEngine, onComplete: onComplete)
        model.onReadyToDictate = onReadyToDictate
    }

    // Bridges a real dictation outcome from the live pipeline into the trial gate.
    func noteDictation(_ outcome: DictationOutcome) { model.noteDictation(outcome) }

    func present() {
        let hosting = NSHostingController(rootView: FirstRunView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to KeyScribe"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        model.onComplete = { [weak self] in
            self?.window?.close()
            self?.window = nil
            self?.onComplete()
        }
    }
}

@MainActor
final class FirstRunModel: ObservableObject {
    enum Step { case intro, model, permissions, tryIt }

    @Published var step: Step = .intro
    @Published var downloading = false
    @Published var downloadProgress: Double = 0
    @Published var modelReady = false
    @Published var downloadError: String?
    @Published var micStatus: PermissionStatus = .notDetermined
    @Published var inputStatus: PermissionStatus = .notDetermined
    @Published var axStatus: PermissionStatus = .notDetermined
    @Published var trialText = ""
    @Published var trialSucceeded = false
    @Published var selectedEngineId: String

    let catalog = SpeechModelCatalog.all
    private let download: (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void
    private let selectEngine: (String) -> Void
    var onComplete: () -> Void
    var onReadyToDictate: () -> Void = {}
    private var pollTask: Task<Void, Never>?

    init(
        initialEngineId: String,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void,
        selectEngine: @escaping (String) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.selectedEngineId = initialEngineId
        self.download = download
        self.selectEngine = selectEngine
        self.onComplete = onComplete
        refreshStatuses()
    }

    var selectedInfo: SpeechModelInfo? { SpeechModelCatalog.entry(for: selectedEngineId) }

    func beginDownload() {
        downloading = true
        downloadError = nil
        let id = selectedEngineId
        Task {
            do {
                try await download(id) { progress in
                    Task { @MainActor in self.downloadProgress = progress.fraction }
                }
                selectEngine(id)
                modelReady = true
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

    func requestInputMonitoring() {
        Permissions.requestInputMonitoring()
        Permissions.openSettings(.inputMonitoring)
        refreshStatuses()
    }

    func requestAccessibility() {
        _ = Permissions.accessibilityStatus(prompt: true)
        Permissions.openSettings(.accessibility)
        refreshStatuses()
    }

    func refreshStatuses() {
        micStatus = Permissions.microphoneStatus()
        inputStatus = Permissions.inputMonitoringStatus()
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
        micStatus == .granted && inputStatus == .granted && axStatus == .granted
    }

    var nextPermission: Permission {
        if micStatus != .granted { return .microphone }
        if inputStatus != .granted { return .inputMonitoring }
        return .accessibility
    }

    func finish() {
        stopPolling()
        onComplete()
    }
}

enum Permission {
    case microphone
    case inputMonitoring
    case accessibility
}
