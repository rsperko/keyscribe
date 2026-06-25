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
        onRelaunch: @escaping () -> Void = {},
        onComplete: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        model = FirstRunModel(
            initialEngineId: initialEngineId, download: download,
            selectEngine: selectEngine, permissionsOnly: permissionsOnly, onComplete: onComplete)
        super.init()
        model.onReadyToDictate = onReadyToDictate
        model.onRelaunch = onRelaunch
    }

    // Bridges a real dictation outcome from the live pipeline into the trial gate.
    func noteDictation(_ outcome: DictationOutcome) { model.noteDictation(outcome) }

    func present() {
        let hosting = NSHostingController(rootView: FirstRunView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = model.permissionsOnly ? "Set Up Permissions" : "Welcome to KeyScribe"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        AppActivationPolicy.pushRegular()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        model.onComplete = { [weak self] in self?.complete() }
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
    enum Step { case intro, model, permissions, tryIt }

    @Published var step: Step = .intro
    @Published var downloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var micStatus: PermissionStatus = .notDetermined
    @Published var axStatus: PermissionStatus = .notDetermined
    @Published var trialText = ""
    @Published var trialSucceeded = false
    @Published var selectedEngineId: String

    let catalog = SpeechModelCatalog.all
    let permissionsOnly: Bool
    private let download: (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void
    private let selectEngine: (String) -> Void
    var onComplete: () -> Void
    var onReadyToDictate: () -> Void = {}
    var onRelaunch: () -> Void = {}
    private var pollTask: Task<Void, Never>?

    init(
        initialEngineId: String,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void,
        selectEngine: @escaping (String) -> Void,
        permissionsOnly: Bool = false,
        onComplete: @escaping () -> Void
    ) {
        self.selectedEngineId = initialEngineId
        self.download = download
        self.selectEngine = selectEngine
        self.permissionsOnly = permissionsOnly
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

    func requestAccessibility() {
        _ = Permissions.accessibilityStatus(prompt: true)
        Permissions.openSettings(.accessibility)
        refreshStatuses()
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

    var nextPermission: Permission {
        if micStatus != .granted { return .microphone }
        return .accessibility
    }

    func finish() {
        stopPolling()
        onComplete()
    }
}

enum Permission {
    case microphone
    case accessibility
}
