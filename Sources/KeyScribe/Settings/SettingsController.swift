import AppKit
import SwiftUI
import KeyScribeKit

typealias Settings = KeyScribeKit.Settings

// A live problem that lights the menu-bar error dot and flags the Settings pane that fixes it
// (ui_design.md §6). `detect` is the single signals→problems mapping, shared by the menu badge and the
// Settings sidebar so they never disagree.
enum SettingsProblem: Equatable, CaseIterable {
    case malformedConfig
    case microphonePermission
    case accessibilityPermission
    case accessibilityNeedsRelaunch
    case activeEngineUnavailable
    case modelSelfTestFailed
    case aiConnectionTestFailed
    case aiConnectionMisconfigured
    case modeNeedsAIService
    case modeUsesFailedConnection
    case hotkeyConflict

    var pane: SettingsDestination {
        switch self {
        case .malformedConfig: .advanced
        case .microphonePermission, .accessibilityPermission, .accessibilityNeedsRelaunch: .permissions
        case .activeEngineUnavailable, .modelSelfTestFailed: .speechModels
        case .aiConnectionTestFailed, .aiConnectionMisconfigured: .aiServices
        case .modeNeedsAIService, .modeUsesFailedConnection: .modes
        case .hotkeyConflict: .general
        }
    }

    // We never passively probe a provider to judge a connection (privacy invariant; a missing key is fine
    // for a local/no-auth endpoint). The authoritative AI health signal is a user-initiated Test Connection
    // that failed; `aiConnectionMisconfigured` is the structural check (no model / no base URL).
    static func detect(
        hasConfigError: Bool, microphoneGranted: Bool,
        accessibilityGranted: Bool,
        accessibilityTapActive: Bool = true,
        activeEngineUsable: Bool = true,
        modelSelfTestFailed: Bool = false,
        aiConnectionTestFailed: Bool = false,
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
        if modelSelfTestFailed { problems.append(.modelSelfTestFailed) }
        if aiConnectionTestFailed { problems.append(.aiConnectionTestFailed) }
        if aiConnectionMisconfigured { problems.append(.aiConnectionMisconfigured) }
        if modeNeedsAIService { problems.append(.modeNeedsAIService) }
        if modeUsesFailedConnection { problems.append(.modeUsesFailedConnection) }
        if hotkeyConflict { problems.append(.hotkeyConflict) }
        return problems
    }
}

// The selected pane, lifted out of the view so the controller can drive it (deep-opening to a pane just
// sets this before the window shows).
@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var destination: SettingsDestination? = .general
}

@MainActor
final class SettingsProblemModel: ObservableObject {
    @Published var flaggedPanes: Set<SettingsDestination> = []
    // Only republish when the set changes, so unchanged poll ticks don't re-render the whole split view.
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
    private let history: HistoryPaneModel
    private let problems = SettingsProblemModel()
    private let navigation = SettingsNavigationModel()
    private let detectProblems: () -> [SettingsProblem]
    private let accessibilityTapActive: () -> Bool
    private let onRelaunch: () -> Void
    // The app to hand focus back to for History's "Paste Result" — the Settings window is key while the
    // pane is up. Tracked only while the History pane is selected and the window is visible.
    private var historyPreviousApp: NSRunningApplication?
    private var historyActivationObserver: NSObjectProtocol?
    private var loadedHistorySignature: String?
    // Permissions are granted out-of-process; poll while the window is open so a flag clears as soon as the
    // user fixes it. Owned here (not a view `.task`) because the window is retained (`isReleasedWhenClosed
    // = false`) — a view-owned task would never cancel and would run for the process lifetime.
    private var problemPollTask: Task<Void, Never>?
    // Shared with the recorders and the app, which suspends the global hotkey monitor while a recorder is
    // capturing so the chord can't fire an existing shortcut.
    let recordingState = HotkeyRecordingState()

    init(
        settings: Settings, speechModels: SpeechModelsModel, repository: ConfigRepository,
        historyStore: HistoryStore,
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
        dictionary = DictionarySettingsModel(repository: repository)
        replacements = ReplacementsSettingsModel(repository: repository)
        modes = ModesSettingsModel(repository: repository)
        aiServices = AIServiceSettingsModel(repository: repository)
        history = HistoryPaneModel(
            store: historyStore,
            addDictionaryWord: { repository.addDictionaryWord($0) },
            addReplacement: { repository.addReplacement(heard: $0, replace: $1) },
            openSettings: { _ in })
        super.init()
        history.openSettings = { [weak self] destination in self?.navigation.destination = destination }
        history.copyText = { TextInserter.copyToClipboard($0) }
        history.pasteText = { [weak self] in self?.pasteHistoryResult($0) }
        // "Create a mode with this service": make a disabled mode wired to the connection and route to Modes.
        aiServices.onCreateModeWithConnection = { [weak self] connectionId in
            guard let self else { return }
            self.modes.createWithConnection(connectionId: connectionId)
            self.navigation.destination = .modes
        }
    }

    func update(settings: Settings) {
        model.apply(settings)
        speechModels.syncActive(settings.stt.engine)
        speechModels.syncSTT(settings.stt)
    }

    func refreshProblems() { problems.update(detectProblems()) }

    // For callers that already ran detection (the menu badge), so it doesn't run back-to-back.
    func refreshProblems(_ detected: [SettingsProblem]) { problems.update(detected) }

    // Connections whose last user-run Test Connection failed — drives the error badge.
    var failedConnectionIds: Set<String> { aiServices.failedTestIds }

    func present(_ destination: SettingsDestination? = nil) {
        refreshProblems()
        startProblemPoll()
        if let destination { navigation.destination = destination }
        if let window {
            if !window.isVisible { AppActivationPolicy.pushRegular() }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = SettingsRootView(
            general: model, speechModels: speechModels, dictionary: dictionary,
            replacements: replacements, aiServices: aiServices, modes: modes, history: history,
            problems: problems, navigation: navigation, recordingState: recordingState,
            accessibilityTapActive: accessibilityTapActive, onRelaunch: onRelaunch,
            onHistoryPaneChange: { [weak self] active in self?.handleHistoryPaneChange(active: active) })
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
        problemPollTask?.cancel()
        problemPollTask = nil
        // "Navigated away" equals "closed" for retained transcript state (phase 8e memory/privacy invariant).
        handleHistoryPaneChange(active: false)
        AppActivationPolicy.popRegular()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Dictations may have landed (or retention changed) while Settings was open in the background — the
        // signature-gated reload is cheap, so re-check when the window regains focus while History is showing.
        if navigation.destination == .history { reloadHistoryIfNeeded() }
    }

    // Reload on entering the History pane; release on leaving (both the memory/privacy invariant: no parsed
    // transcripts retained while History is not on screen). Also drives the previousApp tracking observer.
    private func handleHistoryPaneChange(active: Bool) {
        if active {
            historyPreviousApp = NSWorkspace.shared.frontmostApplication
            registerHistoryActivationObserver()
            reloadHistoryIfNeeded()
        } else {
            removeHistoryActivationObserver()
            history.releaseForClose()
            loadedHistorySignature = nil
        }
    }

    private func reloadHistoryIfNeeded() {
        let signature = history.storeSignature()
        guard signature != loadedHistorySignature else { return }
        history.reload()
        loadedHistorySignature = signature
    }

    private func registerHistoryActivationObserver() {
        guard historyActivationObserver == nil else { return }
        let selfBundleId = Bundle.main.bundleIdentifier
        historyActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Track only while the History pane is selected and the window is visible, so switching panes
                // does not keep re-seeding previousApp.
                guard let self, self.navigation.destination == .history, self.window?.isVisible == true,
                      let app = NSWorkspace.shared.frontmostApplication,
                      app.bundleIdentifier != selfBundleId else { return }
                self.historyPreviousApp = app
            }
        }
    }

    private func removeHistoryActivationObserver() {
        if let historyActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(historyActivationObserver)
        }
        historyActivationObserver = nil
    }

    // History's "Paste Result": the Settings window is key while the pane reads, so hand focus back to the
    // last real app and paste there. Order the Settings window out (through the activation policy), paste,
    // then close on success or re-present + flash on failure — mirroring the old History-window dance.
    private func pasteHistoryResult(_ text: String) {
        guard let target = historyPreviousApp,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            TextInserter.copyToClipboard(text)
            history.flash("No target app to paste into — copied to clipboard instead.")
            return
        }
        window?.orderOut(nil)
        Task { @MainActor in
            guard await TextInserter.pasteReturning(to: target, text: text) else {
                TextInserter.copyToClipboard(text)
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                history.flash("Could not return to the app — copied to clipboard instead.")
                return
            }
            window?.close()
        }
    }

    private func startProblemPoll() {
        problemPollTask?.cancel()
        problemPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.refreshProblems()
            }
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var general: SettingsModel
    @ObservedObject var speechModels: SpeechModelsModel
    @ObservedObject var dictionary: DictionarySettingsModel
    @ObservedObject var replacements: ReplacementsSettingsModel
    @ObservedObject var aiServices: AIServiceSettingsModel
    @ObservedObject var modes: ModesSettingsModel
    @ObservedObject var history: HistoryPaneModel
    @ObservedObject var problems: SettingsProblemModel
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject var recordingState: HotkeyRecordingState
    var accessibilityTapActive: () -> Bool = { true }
    var onRelaunch: () -> Void = {}
    var onHistoryPaneChange: (Bool) -> Void = { _ in }

    // Global action shortcuts as double-fire rivals for the mode-trigger overlap warning (a chord like
    // ⌃⌥⇧V subsumes a right-Option trigger). Read from the live `general` model so editing refreshes the
    // warning; filtered through the SAME shadow/chord gate as runtime registration so the warning never
    // names a shortcut that won't fire (a shadowed one is re-attributed to the mode that shadows it).
    private var actionShortcutRivals: [TriggerKeyConflicts.RivalBinding] {
        TriggerKeyConflicts.liveActionRivals([
            .init(id: GlobalHotkey.vocabularyId, key: general.addVocabularyShortcut,
                  label: "the Add to Vocabulary shortcut"),
            .init(id: GlobalHotkey.pasteLastId, key: general.pasteLastShortcut,
                  label: "the Paste Last Dictation shortcut"),
        ], shadowed: shadowedHotkeys())
    }

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
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(problems.flaggedPanes.contains(destination)
                    ? "\(destination.title), needs attention"
                    : destination.title)
                .accessibilityIdentifier(AccessibilityID.Settings.Sidebar.id(for: destination))
                .tag(destination)
            }
            .disabled(recordingState.isRecording)
            .navigationTitle("Settings")
            .frame(minWidth: 180)
        } detail: {
            switch navigation.destination ?? .general {
            case .general:
                let shadowed = shadowedHotkeys()
                GeneralSettingsView(
                    model: general,
                    vocabularyShadowed: shadowed.contains(GlobalHotkey.vocabularyId),
                    pasteLastShadowed: shadowed.contains(GlobalHotkey.pasteLastId),
                    directMode: modes.modes.first(where: { $0.id == Mode.directId }),
                    allModes: modes.modes,
                    actionShortcuts: actionShortcutRivals,
                    onUpdatePlainDictation: { modes.update($0) })
            case .speechModels:
                SpeechModelsView(model: speechModels, settings: general)
            case .vocabulary:
                VocabularySettingsView(dictionary: dictionary, replacements: replacements)
            case .aiServices:
                AIServiceSettingsView(model: aiServices)
            case .modes:
                ModesSettingsView(model: modes, brokenConnectionIds: aiServices.failedTestIds,
                                  actionShortcuts: actionShortcutRivals)
            case .history:
                HistoryPaneView(model: history, settings: general)
            case .permissions:
                PermissionsSettingsView(
                    accessibilityTapActive: accessibilityTapActive, onRelaunch: onRelaunch)
            case .advanced:
                AdvancedSettingsView(model: general)
            }
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 520, idealHeight: 640)
        .environmentObject(recordingState)
        .onAppear { if navigation.destination == .history { onHistoryPaneChange(true) } }
        .onChange(of: navigation.destination) { old, new in
            if new == .history { onHistoryPaneChange(true) }
            else if old == .history { onHistoryPaneChange(false) }
        }
    }
}

enum SettingsDestination: CaseIterable, Hashable, Identifiable {
    case general
    case speechModels
    case vocabulary
    case aiServices
    case modes
    case history
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
        case .history: "History"
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
        case .history: "clock"
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
                    .accessibilityIdentifier(AccessibilityID.Settings.Advanced.revealConfig)
                Button("Reload Configuration") { model.reload() }
                    .accessibilityIdentifier(AccessibilityID.Settings.Advanced.reloadConfig)
                Text("Config edits are detected automatically. A malformed file is surfaced as an error rather than silently ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dictation HUD") {
                Button("Reset HUD Position") { model.resetHUDPosition() }
                    .accessibilityIdentifier(AccessibilityID.Settings.Advanced.resetHUDPosition)
                Text("Drag the HUD to flick it to any edge or corner; it stays there. Reset returns it to the bottom center.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !Feature.allCases.isEmpty {
                Section("Experimental Features") {
                    ForEach(Feature.allCases, id: \.self) { feature in
                        Toggle(isOn: model.binding(for: feature)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                Text(feature.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.Settings.Advanced.feature(feature.id))
                    }
                    Text("Opt in to features still under development. They default off and may change or be removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Erase Data") {
                Button("Erase All \(Branding.appName) Data…", role: .destructive) { confirmingErase = true }
                    .accessibilityIdentifier(AccessibilityID.Settings.Advanced.eraseAllData)
                Text("Permanently deletes your modes, settings, AI services, saved keys, and dictation history, then restarts \(Branding.appName). Downloaded speech models and system permissions are kept. This cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .alert("Erase all \(Branding.appName) data?", isPresented: $confirmingErase) {
            Button("Erase All Data", role: .destructive) { model.eraseAllData() }
                .accessibilityIdentifier(AccessibilityID.Settings.Advanced.eraseConfirmConfirm)
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(AccessibilityID.Settings.Advanced.eraseConfirmCancel)
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
    // Feature-flag enabled state, keyed by Feature.id, populated for every Feature.allCases. One toggle each.
    @Published var featureStates: [String: Bool] { didSet { persist() } }
    // Empty string = follow the system default input; any other value is a CoreAudio device UID.
    @Published var inputDeviceUID: String { didSet { persist() } }
    // Name last seen for `inputDeviceUID`, so a disconnected preferred device still reads as itself in the
    // picker. Refreshed from the live device whenever one is connected.
    private var storedInputDeviceName: String?

    struct InputDeviceOption: Identifiable, Equatable {
        let id: String
        let label: String
        let connected: Bool
    }

    // Picker rows: "Follow macOS Input" first, then every connected input device. If the saved preference
    // points at a disconnected device, append a trailing disabled row (last-seen name) so the picker renders
    // the current selection instead of silently snapping.
    var inputDeviceOptions: [InputDeviceOption] {
        var options = [InputDeviceOption(id: "", label: "Use Mac’s current input", connected: true)]
        let live = currentAudioSnapshot().devices
        options += live.map { InputDeviceOption(id: $0.uid, label: $0.name, connected: true) }
        if !inputDeviceUID.isEmpty, !live.contains(where: { $0.uid == inputDeviceUID }) {
            let name = storedInputDeviceName ?? "Preferred device"
            options.append(InputDeviceOption(id: inputDeviceUID, label: "\(name) (not connected)", connected: false))
        }
        return options
    }

    var microphoneStatusText: String {
        let snapshot = currentAudioSnapshot()
        return Self.microphoneStatusText(
            inputDeviceUID: inputDeviceUID,
            storedInputDeviceName: storedInputDeviceName,
            liveDevices: snapshot.devices,
            systemDefault: snapshot.systemDefault)
    }

    nonisolated static func microphoneStatusText(
        inputDeviceUID: String,
        storedInputDeviceName: String?,
        liveDevices: [AudioInputDevices.Device],
        systemDefault: AudioInputDevices.Device?
    ) -> String {
        let systemName = systemDefault?.name ?? "No Mac input"
        guard !inputDeviceUID.isEmpty else {
            return systemDefault == nil ? "No Mac input available." : "Using your Mac’s input: \(systemName)."
        }
        if let selected = liveDevices.first(where: { $0.uid == inputDeviceUID }) {
            guard let systemDefault, systemDefault.uid != selected.uid else {
                return "Using \(selected.name)."
            }
            return "Using \(selected.name). Your Mac’s input is \(systemDefault.name)."
        }
        let preferredName = storedInputDeviceName ?? "Selected microphone"
        return systemDefault == nil
            ? "\(preferredName) is unavailable. No Mac input available."
            : "\(preferredName) is unavailable. Using your Mac’s input: \(systemName)."
    }

    var evictions: [(id: String, label: String)] {
        [
            ("fastest", "Fastest — keep model and mic ready"),
            ("balanced", "Balanced — release after \(Self.idleLabel(settings.stt.evictionIdleSeconds)) idle"),
            ("frugal", "Frugal — load only when dictating"),
        ]
    }

    var evictionSummary: String {
        let label = evictions.first { $0.id == eviction }?.label ?? "Fastest"
        let shortLabel = label.components(separatedBy: " — ").first ?? label
        return shortLabel == "Fastest" ? "Fastest start-up" : shortLabel
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
    private var audioSnapshot: (loadedAt: Date, devices: [AudioInputDevices.Device], systemDefault: AudioInputDevices.Device?)?
    private static let audioSnapshotTTL: TimeInterval = 1
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
        featureStates = Self.featureStates(from: settings.features)
    }

    static func featureStates(from features: Settings.Features) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0.id, features.isEnabled($0)) })
    }

    func binding(for feature: Feature) -> Binding<Bool> {
        Binding(
            get: { self.featureStates[feature.id] ?? false },
            set: { self.featureStates[feature.id] = $0 })
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
        featureStates = Self.featureStates(from: settings.features)
        loading = false
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([KeyScribePaths.supportDir])
    }

    func reload() { onReload() }

    func resetHUDPosition() { onResetHUDPosition() }

    func eraseAllData() { onEraseAllData() }

    private func currentAudioSnapshot() -> (devices: [AudioInputDevices.Device], systemDefault: AudioInputDevices.Device?) {
        let now = Date()
        if let audioSnapshot, now.timeIntervalSince(audioSnapshot.loadedAt) < Self.audioSnapshotTTL {
            return (audioSnapshot.devices, audioSnapshot.systemDefault)
        }
        let fresh = (loadedAt: now, devices: AudioInputDevices.available(), systemDefault: AudioInputDevices.systemDefaultInput())
        audioSnapshot = fresh
        return (fresh.devices, fresh.systemDefault)
    }

    private func persist() {
        guard !loading else { return }
        settings.duringDictation = .init(muteSystemAudio: muteSystemAudio, keepDisplayAwake: keepDisplayAwake, sounds: sounds)
        settings.loadOnLogin = loadOnLogin
        settings.history = .init(enabled: historyEnabled, retentionDays: retentionDays)
        settings.stt.eviction = Eviction(rawValue: eviction) ?? .fastest
        settings.shortcuts = .init(
            addVocabulary: addVocabularyShortcut,
            pasteLastDictation: pasteLastShortcut)
        if inputDeviceUID.isEmpty {
            storedInputDeviceName = nil
        } else if let live = currentAudioSnapshot().devices.first(where: { $0.uid == inputDeviceUID }) {
            storedInputDeviceName = live.name
        }
        settings.audio = .init(
            inputDeviceUID: inputDeviceUID.isEmpty ? nil : inputDeviceUID,
            inputDeviceName: inputDeviceUID.isEmpty ? nil : storedInputDeviceName)
        var features = Settings.Features()
        for feature in Feature.allCases {
            features.setEnabled(featureStates[feature.id] ?? false, for: feature)
        }
        settings.features = features
        onChange(settings)
    }
}
