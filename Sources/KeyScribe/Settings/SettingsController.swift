import AppKit
import SwiftUI
import KeyScribeKit

typealias Settings = KeyScribeKit.Settings

@MainActor
final class SettingsController {
    private var window: NSWindow?
    private let model: SettingsModel
    private let speechModels: SpeechModelsModel
    private let dictionary: DictionarySettingsModel
    private let replacements: ReplacementsSettingsModel
    private let modes: ModesSettingsModel
    private let aiServices: AIServiceSettingsModel

    init(
        settings: Settings, speechModels: SpeechModelsModel,
        onChange: @escaping (Settings) -> Void, onReload: @escaping () -> Void
    ) {
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

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = SettingsRootView(
            general: model, speechModels: speechModels, dictionary: dictionary,
            replacements: replacements, aiServices: aiServices, modes: modes)
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
    @State private var destination: SettingsDestination? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsDestination.allCases, selection: $destination) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationTitle("Settings")
            .frame(minWidth: 180)
        } detail: {
            switch destination ?? .general {
            case .general:
                GeneralSettingsView(model: general)
            case .speechModels:
                SpeechModelsView(model: speechModels)
            case .vocabulary:
                VocabularySettingsView(dictionary: dictionary, replacements: replacements)
            case .aiServices:
                AIServiceSettingsView(model: aiServices)
            case .modes:
                ModesSettingsView(model: modes)
            case .permissions:
                PermissionsSettingsView()
            case .advanced:
                AdvancedSettingsView(model: general)
            }
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 520, idealHeight: 640)
    }
}

private enum SettingsDestination: CaseIterable, Hashable, Identifiable {
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

    static let evictions: [(id: String, label: String)] = [
        ("fastest", "Fastest — keep model in memory"),
        ("balanced", "Balanced — free memory after a pause"),
        ("frugal", "Frugal — free memory after each dictation"),
    ]

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
        onChange(settings)
    }
}
