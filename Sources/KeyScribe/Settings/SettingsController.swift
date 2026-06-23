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
    case inputMonitoringPermission
    case accessibilityPermission
    case activeEngineUnavailable
    case aiConnectionMissing
    case aiConnectionTestFailed
    case aiConnectionMisconfigured
    case modeUsesFailedConnection
    case hotkeyConflict

    var pane: SettingsDestination {
        switch self {
        case .malformedConfig: .advanced
        case .microphonePermission, .inputMonitoringPermission, .accessibilityPermission: .permissions
        case .activeEngineUnavailable: .speechModels
        case .aiConnectionMissing, .aiConnectionTestFailed, .aiConnectionMisconfigured: .aiServices
        case .modeUsesFailedConnection: .modes
        case .hotkeyConflict: .general
        }
    }

    // The single mapping from raw signals → problems. We never *passively* probe a provider to judge
    // a connection (privacy invariant, and a missing key is legitimate for a local/no-auth endpoint).
    // The authoritative AI health signal is a **user-initiated Test Connection that failed**;
    // `aiConnectionMisconfigured` is the structural check (no model / no base URL) that needs no call.
    static func detect(
        hasConfigError: Bool, microphoneGranted: Bool,
        inputMonitoringGranted: Bool, accessibilityGranted: Bool,
        activeEngineUsable: Bool = true,
        aiConnectionMissing: Bool = false, aiConnectionTestFailed: Bool = false,
        aiConnectionMisconfigured: Bool = false, modeUsesFailedConnection: Bool = false,
        hotkeyConflict: Bool = false
    ) -> [SettingsProblem] {
        var problems: [SettingsProblem] = []
        if hasConfigError { problems.append(.malformedConfig) }
        if !microphoneGranted { problems.append(.microphonePermission) }
        if !inputMonitoringGranted { problems.append(.inputMonitoringPermission) }
        if !accessibilityGranted { problems.append(.accessibilityPermission) }
        if !activeEngineUsable { problems.append(.activeEngineUnavailable) }
        if aiConnectionMissing { problems.append(.aiConnectionMissing) }
        if aiConnectionTestFailed { problems.append(.aiConnectionTestFailed) }
        if aiConnectionMisconfigured { problems.append(.aiConnectionMisconfigured) }
        if modeUsesFailedConnection { problems.append(.modeUsesFailedConnection) }
        if hotkeyConflict { problems.append(.hotkeyConflict) }
        return problems
    }
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
final class SettingsController {
    private var window: NSWindow?
    private let model: SettingsModel
    private let speechModels: SpeechModelsModel
    private let dictionary: DictionarySettingsModel
    private let replacements: ReplacementsSettingsModel
    private let modes: ModesSettingsModel
    private let aiServices: AIServiceSettingsModel
    private let problems = SettingsProblemModel()
    private let detectProblems: () -> [SettingsProblem]
    // Shared with the recorders (via the environment) and the app, which suspends the global hotkey
    // monitor while a recorder is capturing so the chord can't fire an existing shortcut.
    let recordingState = HotkeyRecordingState()

    init(
        settings: Settings, speechModels: SpeechModelsModel,
        onChange: @escaping (Settings) -> Void, onReload: @escaping () -> Void,
        detectProblems: @escaping () -> [SettingsProblem]
    ) {
        self.detectProblems = detectProblems
        model = SettingsModel(settings: settings, onChange: onChange, onReload: onReload)
        self.speechModels = speechModels
        dictionary = DictionarySettingsModel(supportDir: KeyScribePaths.supportDir)
        replacements = ReplacementsSettingsModel(supportDir: KeyScribePaths.supportDir)
        let general = model
        modes = ModesSettingsModel(
            modesDir: KeyScribePaths.modesDir, supportDir: KeyScribePaths.supportDir,
            defaultModeId: { general.currentDefaultModeId },
            onSetDefault: { general.setDefaultMode($0) })
        aiServices = AIServiceSettingsModel(supportDir: KeyScribePaths.supportDir)
    }

    func update(settings: Settings) {
        model.apply(settings)
        speechModels.syncActive(settings.stt.engine)
    }

    func refreshProblems() { problems.update(detectProblems()) }

    // Connections whose last user-run Test Connection failed — the authoritative "this AI service is
    // broken" signal that drives the error badge (AppDelegate.currentProblems reads it).
    var failedConnectionIds: Set<String> { aiServices.failedTestIds }

    func present() {
        refreshProblems()
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = SettingsRootView(
            general: model, speechModels: speechModels, dictionary: dictionary,
            replacements: replacements, aiServices: aiServices, modes: modes,
            problems: problems, recordingState: recordingState,
            refresh: { [weak self] in self?.refreshProblems() })
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "KeyScribe Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 940, height: 640))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
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
    @ObservedObject var recordingState: HotkeyRecordingState
    let refresh: () -> Void
    @State private var destination: SettingsDestination? = .general

    // Precedence order for the app-wide hotkey namespace: Modes (routing order) then the two globals.
    // The losers of any chord collision are "shadowed" — flagged with a red dot, and suppressed at
    // dispatch so the higher-precedence owner fires. No rejection; first match in this order wins.
    private func shadowedHotkeys() -> Set<String> {
        var ordered = modes.modes.map {
            HotkeyConflicts.Registrant(
                id: $0.id, key: $0.triggerKeys.first?.key ?? "", enabled: $0.enabled)
        }
        ordered.append(.init(id: GlobalHotkey.dictionaryId, key: general.addDictionaryShortcut))
        ordered.append(.init(id: GlobalHotkey.replacementId, key: general.addReplacementShortcut))
        return HotkeyConflicts.shadowed(ordered)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsDestination.allCases, selection: $destination) { destination in
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
            switch destination ?? .general {
            case .general:
                let shadowed = shadowedHotkeys()
                GeneralSettingsView(
                    model: general,
                    dictionaryShadowed: shadowed.contains(GlobalHotkey.dictionaryId),
                    replacementShadowed: shadowed.contains(GlobalHotkey.replacementId))
            case .speechModels:
                SpeechModelsView(model: speechModels)
            case .vocabulary:
                VocabularySettingsView(dictionary: dictionary, replacements: replacements)
            case .aiServices:
                AIServiceSettingsView(model: aiServices)
            case .modes:
                ModesSettingsView(model: modes, brokenConnectionIds: aiServices.failedTestIds)
            case .permissions:
                PermissionsSettingsView()
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

    var body: some View {
        Form {
            Section("Configuration") {
                Button("Reveal Config in Finder") { model.revealConfig() }
                Button("Reload Configuration") { model.reload() }
                Text("Config edits are detected automatically. A malformed file is surfaced as an error rather than silently ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
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
    @Published var addDictionaryShortcut: String { didSet { persist() } }
    @Published var addReplacementShortcut: String { didSet { persist() } }

    var evictions: [(id: String, label: String)] {
        [
            ("fastest", "Fastest — keep model in memory"),
            ("balanced", "Balanced — free memory after \(Self.idleLabel(settings.stt.evictionIdleSeconds)) idle"),
            ("frugal", "Frugal — free memory after each dictation"),
        ]
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
    private var loading = false

    init(settings: Settings, onChange: @escaping (Settings) -> Void, onReload: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
        self.onReload = onReload
        sounds = settings.duringDictation.sounds
        keepDisplayAwake = settings.duringDictation.keepDisplayAwake
        muteSystemAudio = settings.duringDictation.muteSystemAudio
        loadOnLogin = settings.loadOnLogin
        historyEnabled = settings.history.enabled
        retentionDays = settings.history.retentionDays
        eviction = settings.stt.eviction.rawValue
        addDictionaryShortcut = settings.shortcuts.addDictionaryEntry
        addReplacementShortcut = settings.shortcuts.addReplacement
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
        addDictionaryShortcut = settings.shortcuts.addDictionaryEntry
        addReplacementShortcut = settings.shortcuts.addReplacement
        loading = false
    }

    var currentDefaultModeId: String { settings.defaultModeId }

    func setDefaultMode(_ id: String) {
        guard settings.defaultModeId != id else { return }
        settings.defaultModeId = id
        onChange(settings)
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([KeyScribePaths.supportDir])
    }

    func reload() { onReload() }

    private func persist() {
        guard !loading else { return }
        settings.duringDictation = .init(muteSystemAudio: muteSystemAudio, keepDisplayAwake: keepDisplayAwake, sounds: sounds)
        settings.loadOnLogin = loadOnLogin
        settings.history = .init(enabled: historyEnabled, retentionDays: retentionDays)
        settings.stt = .init(
            engine: settings.stt.engine,
            eviction: Eviction(rawValue: eviction) ?? .balanced,
            evictionIdleSeconds: settings.stt.evictionIdleSeconds)
        settings.shortcuts = .init(
            addDictionaryEntry: addDictionaryShortcut, addReplacement: addReplacementShortcut)
        onChange(settings)
    }
}
