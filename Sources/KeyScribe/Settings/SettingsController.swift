import AppKit
import SwiftUI
import KeyScribeKit

typealias Settings = KeyScribeKit.Settings

// A live problem that lights the menu-bar error dot and flags the Settings pane that fixes it
// (ui_design.md §6). `detect` is the single mapping from raw signals → problems, shared by the menu
// badge and the Settings sidebar so they never disagree.
enum SettingsProblem: Equatable, CaseIterable {
    case malformedConfig
    case microphonePermission
    case accessibilityPermission
    case accessibilityNeedsRelaunch
    case activeEngineUnavailable
    case aiConnectionMissing
    case aiConnectionTestFailed
    case aiConnectionMisconfigured
    case modeNeedsAIService
    case modeUsesFailedConnection
    case hotkeyConflict

    var pane: SettingsDestination {
        switch self {
        case .malformedConfig: .advanced
        case .microphonePermission, .accessibilityPermission, .accessibilityNeedsRelaunch: .permissions
        case .activeEngineUnavailable: .speechModels
        case .aiConnectionMissing, .aiConnectionTestFailed, .aiConnectionMisconfigured: .aiServices
        case .modeNeedsAIService, .modeUsesFailedConnection: .modes
        case .hotkeyConflict: .general
        }
    }

    // The single mapping from raw signals → problems. We never *passively* probe a provider to judge
    // a connection (privacy invariant, and a missing key is legitimate for a local/no-auth endpoint).
    // The authoritative AI health signal is a **user-initiated Test Connection that failed**;
    // `aiConnectionMisconfigured` is the structural check (no model / no base URL) that needs no call.
    static func detect(
        hasConfigError: Bool, microphoneGranted: Bool,
        accessibilityGranted: Bool,
        accessibilityTapActive: Bool = true,
        activeEngineUsable: Bool = true,
        aiConnectionMissing: Bool = false, aiConnectionTestFailed: Bool = false,
        aiConnectionMisconfigured: Bool = false, modeNeedsAIService: Bool = false,
        modeUsesFailedConnection: Bool = false,
        hotkeyConflict: Bool = false
    ) -> [SettingsProblem] {
        var problems: [SettingsProblem] = []
        if hasConfigError { problems.append(.malformedConfig) }
        if !microphoneGranted { problems.append(.microphonePermission) }
        if !accessibilityGranted { problems.append(.accessibilityPermission) }
        else if !accessibilityTapActive { problems.append(.accessibilityNeedsRelaunch) }
        if !activeEngineUsable { problems.append(.activeEngineUnavailable) }
        if aiConnectionMissing { problems.append(.aiConnectionMissing) }
        if aiConnectionTestFailed { problems.append(.aiConnectionTestFailed) }
        if aiConnectionMisconfigured { problems.append(.aiConnectionMisconfigured) }
        if modeNeedsAIService { problems.append(.modeNeedsAIService) }
        if modeUsesFailedConnection { problems.append(.modeUsesFailedConnection) }
        if hotkeyConflict { problems.append(.hotkeyConflict) }
        return problems
    }
}

// The selected pane, lifted out of the view so the controller can drive it — opening Settings deep
// to a pane (e.g. History's "Manage Vocabulary…") just sets this before the window shows.
@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var destination: SettingsDestination? = .general
}

@MainActor
final class SettingsProblemModel: ObservableObject {
    @Published var flaggedPanes: Set<SettingsDestination> = []
    // The 2s poll calls this on every tick; only republish when the set actually changes so unchanged
    // ticks don't re-render the whole split view.
    func update(_ problems: [SettingsProblem]) {
        let panes = Set(problems.map(\.pane))
        if panes != flaggedPanes { flaggedPanes = panes }
    }
}

@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel
    private let speechModels: SpeechModelsModel
    private let dictionary: DictionarySettingsModel
    private let replacements: ReplacementsSettingsModel
    private let modes: ModesSettingsModel
    private let aiServices: AIServiceSettingsModel
    private let problems = SettingsProblemModel()
    private let navigation = SettingsNavigationModel()
    private let detectProblems: () -> [SettingsProblem]
    private let accessibilityTapActive: () -> Bool
    private let onRelaunch: () -> Void
    // Shared with the recorders (via the environment) and the app, which suspends the global hotkey
    // monitor while a recorder is capturing so the chord can't fire an existing shortcut.
    let recordingState = HotkeyRecordingState()

    init(
        settings: Settings, speechModels: SpeechModelsModel,
        onChange: @escaping (Settings) -> Void, onReload: @escaping () -> Void,
        onResetHUDPosition: @escaping () -> Void,
        detectProblems: @escaping () -> [SettingsProblem],
        accessibilityTapActive: @escaping () -> Bool = { true },
        onRelaunch: @escaping () -> Void = {},
        onEraseAllData: @escaping () -> Void = {}
    ) {
        self.detectProblems = detectProblems
        self.accessibilityTapActive = accessibilityTapActive
        self.onRelaunch = onRelaunch
        model = SettingsModel(
            settings: settings, onChange: onChange, onReload: onReload,
            onResetHUDPosition: onResetHUDPosition, onEraseAllData: onEraseAllData)
        self.speechModels = speechModels
        dictionary = DictionarySettingsModel(supportDir: KeyScribePaths.supportDir)
        replacements = ReplacementsSettingsModel(supportDir: KeyScribePaths.supportDir)
        modes = ModesSettingsModel(
            modesDir: KeyScribePaths.modesDir, supportDir: KeyScribePaths.supportDir)
        aiServices = AIServiceSettingsModel(supportDir: KeyScribePaths.supportDir)
        super.init()
    }

    func update(settings: Settings) {
        model.apply(settings)
        speechModels.syncActive(settings.stt.engine)
        speechModels.syncDictionaryRecovery(settings.stt.dictionaryRecoveryEngines)
    }

    func refreshProblems() { problems.update(detectProblems()) }

    // Connections whose last user-run Test Connection failed — the authoritative "this AI service is
    // broken" signal that drives the error badge (AppDelegate.currentProblems reads it).
    var failedConnectionIds: Set<String> { aiServices.failedTestIds }

    func present(_ destination: SettingsDestination? = nil) {
        refreshProblems()
        if let destination { navigation.destination = destination }
        if let window {
            if !window.isVisible { AppActivationPolicy.pushRegular() }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = SettingsRootView(
            general: model, speechModels: speechModels, dictionary: dictionary,
            replacements: replacements, aiServices: aiServices, modes: modes,
            problems: problems, navigation: navigation, recordingState: recordingState,
            refresh: { [weak self] in self?.refreshProblems() },
            accessibilityTapActive: accessibilityTapActive, onRelaunch: onRelaunch)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(Branding.appName) Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.collectionBehavior = .fullScreenNone
        window.setContentSize(NSSize(width: 940, height: 640))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        AppActivationPolicy.pushRegular()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        AppActivationPolicy.popRegular()
    }
}

struct SettingsRootView: View {
    @ObservedObject var general: SettingsModel
    @ObservedObject var speechModels: SpeechModelsModel
    @ObservedObject var dictionary: DictionarySettingsModel
    @ObservedObject var replacements: ReplacementsSettingsModel
    @ObservedObject var aiServices: AIServiceSettingsModel
    @ObservedObject var modes: ModesSettingsModel
    @ObservedObject var problems: SettingsProblemModel
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject var recordingState: HotkeyRecordingState
    let refresh: () -> Void
    var accessibilityTapActive: () -> Bool = { true }
    var onRelaunch: () -> Void = {}

    private func shadowedHotkeys() -> Set<String> {
        var ordered = modes.modes.map {
            HotkeyConflicts.Registrant(
                id: $0.id, key: $0.triggerKeys.first?.key ?? "", enabled: $0.enabled)
        }
        ordered.append(.init(id: GlobalHotkey.vocabularyId, key: general.addVocabularyShortcut))
        ordered.append(.init(id: GlobalHotkey.pasteLastId, key: general.pasteLastShortcut))
        return HotkeyConflicts.shadowed(ordered)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsDestination.allCases, selection: $navigation.destination) { destination in
                HStack {
                    Label(destination.title, systemImage: destination.symbol)
                    Spacer()
                    if problems.flaggedPanes.contains(destination) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                            .accessibilityLabel("Needs attention")
                    }
                }
                .tag(destination)
            }
            .disabled(recordingState.isRecording)
            .navigationTitle("Settings")
            .frame(minWidth: 180)
            // Permissions are granted out-of-process; poll while the window is open so a flag clears
            // as soon as the user fixes the problem (mirrors the Permissions pane's own poll).
            .task {
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } detail: {
            switch navigation.destination ?? .general {
            case .general:
                let shadowed = shadowedHotkeys()
                GeneralSettingsView(
                    model: general,
                    vocabularyShadowed: shadowed.contains(GlobalHotkey.vocabularyId),
                    pasteLastShadowed: shadowed.contains(GlobalHotkey.pasteLastId))
            case .speechModels:
                SpeechModelsView(model: speechModels)
            case .vocabulary:
                VocabularySettingsView(dictionary: dictionary, replacements: replacements)
            case .aiServices:
                AIServiceSettingsView(model: aiServices)
            case .modes:
                ModesSettingsView(model: modes, brokenConnectionIds: aiServices.failedTestIds)
            case .permissions:
                PermissionsSettingsView(
                    accessibilityTapActive: accessibilityTapActive, onRelaunch: onRelaunch)
            case .advanced:
                AdvancedSettingsView(model: general)
            }
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 520, idealHeight: 640)
        .environmentObject(recordingState)
    }
}

enum SettingsDestination: CaseIterable, Hashable, Identifiable {
    case general
    case speechModels
    case vocabulary
    case aiServices
    case modes
    case permissions
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .speechModels: "Speech Models"
        case .vocabulary: "Vocabulary"
        case .aiServices: "AI Services"
        case .modes: "Modes"
        case .permissions: "Permissions"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .speechModels: "waveform"
        case .vocabulary: "text.book.closed"
        case .aiServices: "wand.and.stars"
        case .modes: "square.stack.3d.up"
        case .permissions: "lock"
        case .advanced: "slider.horizontal.3"
        }
    }
}

private struct AdvancedSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmingErase = false

    var body: some View {
        Form {
            Section("Configuration") {
                Button("Reveal Config in Finder") { model.revealConfig() }
                Button("Reload Configuration") { model.reload() }
                Text("Config edits are detected automatically. A malformed file is surfaced as an error rather than silently ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dictation HUD") {
                Button("Reset HUD Position") { model.resetHUDPosition() }
                Text("Drag the HUD to flick it to any edge or corner; it stays there. Reset returns it to the bottom center.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Erase Data") {
                Button("Erase All \(Branding.appName) Data…", role: .destructive) { confirmingErase = true }
                Text("Permanently deletes your modes, settings, AI services, saved keys, and dictation history, then restarts \(Branding.appName). Downloaded speech models and system permissions are kept. This cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .alert("Erase all \(Branding.appName) data?", isPresented: $confirmingErase) {
            Button("Erase All Data", role: .destructive) { model.eraseAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your modes, settings, AI services, saved keys, and dictation history, and restarts \(Branding.appName). Downloaded speech models and system permissions are kept. This cannot be undone.")
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var sounds: Bool { didSet { persist() } }
    @Published var keepDisplayAwake: Bool { didSet { persist() } }
    @Published var muteSystemAudio: Bool { didSet { persist() } }
    @Published var loadOnLogin: Bool { didSet { persist() } }
    @Published var historyEnabled: Bool { didSet { persist() } }
    @Published var retentionDays: Int { didSet { persist() } }
    @Published var eviction: String { didSet { persist() } }
    @Published var addVocabularyShortcut: String { didSet { persist() } }
    @Published var pasteLastShortcut: String { didSet { persist() } }
    // Empty string = follow the system default input; any other value is a CoreAudio device UID.
    @Published var inputDeviceUID: String { didSet { persist() } }
    // The friendly name last seen for `inputDeviceUID`, so a disconnected preferred device still reads as
    // itself in the picker. Refreshed from the live device whenever one is connected (here and at startup).
    private var storedInputDeviceName: String?

    struct InputDeviceOption: Identifiable, Equatable {
        let id: String
        let label: String
        let connected: Bool
    }

    // Picker rows: "Follow macOS Input" first, then every connected input device. If the saved preference
    // points at a device that is not currently connected, append a trailing disabled row (labeled with the
    // last-seen name) so the picker can still render the current selection instead of silently snapping.
    var inputDeviceOptions: [InputDeviceOption] {
        var options = [InputDeviceOption(id: "", label: "Follow macOS Input", connected: true)]
        let live = AudioInputDevices.available()
        options += live.map { InputDeviceOption(id: $0.uid, label: $0.name, connected: true) }
        if !inputDeviceUID.isEmpty, !live.contains(where: { $0.uid == inputDeviceUID }) {
            let name = storedInputDeviceName ?? "Preferred device"
            options.append(InputDeviceOption(id: inputDeviceUID, label: "\(name) (not connected)", connected: false))
        }
        return options
    }

    var microphoneStatusText: String {
        Self.microphoneStatusText(
            inputDeviceUID: inputDeviceUID,
            storedInputDeviceName: storedInputDeviceName,
            liveDevices: AudioInputDevices.available(),
            systemDefault: AudioInputDevices.systemDefaultInput())
    }

    nonisolated static func microphoneStatusText(
        inputDeviceUID: String,
        storedInputDeviceName: String?,
        liveDevices: [AudioInputDevices.Device],
        systemDefault: AudioInputDevices.Device?
    ) -> String {
        let systemName = systemDefault?.name ?? "No macOS input"
        guard !inputDeviceUID.isEmpty else {
            return systemDefault == nil ? "No macOS input available." : "Using macOS input: \(systemName)."
        }
        if let selected = liveDevices.first(where: { $0.uid == inputDeviceUID }) {
            guard let systemDefault, systemDefault.uid != selected.uid else {
                return "Preferred: \(selected.name)."
            }
            return "Preferred: \(selected.name). macOS input is \(systemDefault.name)."
        }
        let preferredName = storedInputDeviceName ?? "Preferred microphone"
        return systemDefault == nil
            ? "\(preferredName) unavailable. No macOS input available."
            : "\(preferredName) unavailable. Using macOS input: \(systemName)."
    }

    var evictions: [(id: String, label: String)] {
        [
            ("fastest", "Fastest — keep model in memory"),
            ("balanced", "Balanced — free memory after \(Self.idleLabel(settings.stt.evictionIdleSeconds)) idle"),
            ("frugal", "Frugal — free memory after each dictation"),
        ]
    }

    var evictionFooter: String {
        let info = SpeechModelCatalog.entry(for: settings.stt.engine)
        return EvictionCopy.footer(
            policy: Eviction(rawValue: eviction) ?? .fastest,
            modelName: info?.displayName ?? "the active model",
            bytes: info?.approxDownloadBytes ?? 0,
            systemManaged: info?.systemManaged ?? false,
            idleLabel: Self.idleLabel(settings.stt.evictionIdleSeconds))
    }

    static func idleLabel(_ seconds: Int?) -> String {
        let s = seconds ?? Int(EvictionPolicy.defaultIdleSeconds)
        if s % 3600 == 0 { return "\(s / 3600) hr" }
        if s % 60 == 0 { return "\(s / 60) min" }
        return "\(s) sec"
    }

    private var settings: Settings
    private let onChange: (Settings) -> Void
    private let onReload: () -> Void
    private let onResetHUDPosition: () -> Void
    private let onEraseAllData: () -> Void
    private var loading = false

    init(
        settings: Settings, onChange: @escaping (Settings) -> Void,
        onReload: @escaping () -> Void, onResetHUDPosition: @escaping () -> Void,
        onEraseAllData: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.onChange = onChange
        self.onReload = onReload
        self.onResetHUDPosition = onResetHUDPosition
        self.onEraseAllData = onEraseAllData
        sounds = settings.duringDictation.sounds
        keepDisplayAwake = settings.duringDictation.keepDisplayAwake
        muteSystemAudio = settings.duringDictation.muteSystemAudio
        loadOnLogin = settings.loadOnLogin
        historyEnabled = settings.history.enabled
        retentionDays = settings.history.retentionDays
        eviction = settings.stt.eviction.rawValue
        addVocabularyShortcut = settings.shortcuts.addVocabulary
        pasteLastShortcut = settings.shortcuts.pasteLastDictation
        inputDeviceUID = settings.audio.inputDeviceUID ?? ""
        storedInputDeviceName = settings.audio.inputDeviceName
    }

    func apply(_ settings: Settings) {
        loading = true
        self.settings = settings
        sounds = settings.duringDictation.sounds
        keepDisplayAwake = settings.duringDictation.keepDisplayAwake
        muteSystemAudio = settings.duringDictation.muteSystemAudio
        loadOnLogin = settings.loadOnLogin
        historyEnabled = settings.history.enabled
        retentionDays = settings.history.retentionDays
        eviction = settings.stt.eviction.rawValue
        addVocabularyShortcut = settings.shortcuts.addVocabulary
        pasteLastShortcut = settings.shortcuts.pasteLastDictation
        inputDeviceUID = settings.audio.inputDeviceUID ?? ""
        storedInputDeviceName = settings.audio.inputDeviceName
        loading = false
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([KeyScribePaths.supportDir])
    }

    func reload() { onReload() }

    func resetHUDPosition() { onResetHUDPosition() }

    func eraseAllData() { onEraseAllData() }

    private func persist() {
        guard !loading else { return }
        settings.duringDictation = .init(muteSystemAudio: muteSystemAudio, keepDisplayAwake: keepDisplayAwake, sounds: sounds)
        settings.loadOnLogin = loadOnLogin
        settings.history = .init(enabled: historyEnabled, retentionDays: retentionDays)
        settings.stt.eviction = Eviction(rawValue: eviction) ?? .balanced
        settings.shortcuts = .init(
            addVocabulary: addVocabularyShortcut,
            pasteLastDictation: pasteLastShortcut)
        if inputDeviceUID.isEmpty {
            storedInputDeviceName = nil
        } else if let live = AudioInputDevices.available().first(where: { $0.uid == inputDeviceUID }) {
            storedInputDeviceName = live.name
        }
        settings.audio = .init(
            inputDeviceUID: inputDeviceUID.isEmpty ? nil : inputDeviceUID,
            inputDeviceName: inputDeviceUID.isEmpty ? nil : storedInputDeviceName)
        onChange(settings)
    }
}
