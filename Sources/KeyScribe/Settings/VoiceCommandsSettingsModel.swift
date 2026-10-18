import AppKit
import SwiftUI
import KeyScribeKit

@MainActor
final class VoiceCommandsSettingsModel: ObservableObject {
    @Published private(set) var places: [VoiceCommandPlace] = []
    @Published private(set) var loadError: String?
    @Published private(set) var tryResult: TryResult?
    @Published private(set) var appChoices: [VoiceCommandCatalog.App] = []

    struct TryResult: Equatable {
        let heard: String
        let summary: String
        let detail: String
        let resolved: Bool
    }

    struct CurrentTab: Equatable {
        let url: String
        let title: String
        let browserBundleId: String
    }

    var previousApp: () -> NSRunningApplication? = { nil }

    private let repository: ConfigRepository
    private let system: LiveVoiceCommandSystem
    private var tryTask: Task<Void, Never>?

    init(repository: ConfigRepository, system: LiveVoiceCommandSystem = .shared) {
        self.repository = repository
        self.system = system
        reload()
        repository.addChangeObserver { [weak self] in self?.reload() }
    }

    func reload() {
        switch VoiceCommandStore.load(supportDir: repository.supportDir) {
        case .absent:
            places = []
            loadError = nil
        case .loaded(let config):
            places = config.places
            loadError = nil
        case .failed(let error):
            loadError = "\(VoiceCommandStore.fileName) could not be read (\(Self.describe(error))). Fix or remove the file to edit places here."
        }
    }

    private static func describe(_ error: ConfigError) -> String {
        switch error {
        case .missingSchemaVersion: "missing schema_version"
        case .newerSchemaVersion: "it was saved by a newer version"
        case .invalid(let message): message
        }
    }

    func save(_ place: VoiceCommandPlace, replacing originalName: String?) -> String? {
        guard loadError == nil else { return loadError }
        if let issue = place.issue { return issue }
        let key = VoiceCommandText.key(place.name)
        let originalKey = originalName.map(VoiceCommandText.key)
        if places.contains(where: { VoiceCommandText.key($0.name) == key && VoiceCommandText.key($0.name) != originalKey }) {
            return "Another place already uses this name."
        }
        do {
            try repository.mutateVoiceCommands { config in
                if let originalKey, let index = config.places.firstIndex(where: { VoiceCommandText.key($0.name) == originalKey }) {
                    config.places[index] = place
                } else {
                    config.places.append(place)
                }
            }
            reload()
            return nil
        } catch {
            return "Could not save: \(error.localizedDescription)"
        }
    }

    func delete(named name: String) -> String? {
        let key = VoiceCommandText.key(name)
        do {
            try repository.mutateVoiceCommands { config in
                config.places.removeAll { VoiceCommandText.key($0.name) == key }
            }
            reload()
            return nil
        } catch {
            return "Could not delete: \(error.localizedDescription)"
        }
    }

    var currentApp: VoiceCommandCatalog.App? {
        guard let app = previousApp(), let bundleId = app.bundleIdentifier, bundleId != Bundle.main.bundleIdentifier else {
            return nil
        }
        return VoiceCommandCatalog.App(name: app.localizedName ?? bundleId, bundleId: bundleId)
    }

    func currentTab() async -> CurrentTab? {
        guard let app = currentApp, system.isBrowser(app.bundleId),
              let tab = await system.frontTab(ofBrowser: app.bundleId) else { return nil }
        return CurrentTab(url: tab.url, title: tab.title, browserBundleId: app.bundleId)
    }

    var browsers: [VoiceCommandCatalog.App] {
        appChoices.filter { system.isBrowser($0.bundleId) }
    }

    func loadAppChoices() async {
        var seen = Set<String>()
        let all = system.runningApps() + (await system.installedApps())
        appChoices = all.filter { seen.insert($0.bundleId).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func appName(_ bundleId: String) -> String {
        system.appName(forBundleId: bundleId) ?? bundleId
    }

    func tryIt(_ text: String) {
        tryTask?.cancel()
        let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { tryResult = nil; return }
        let places = places
        tryTask = Task { [weak self, system] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let runner = VoiceCommandRunner(system: system)
            let resolution = await runner.resolve(heard, places: places)
            guard !Task.isCancelled, let self else { return }
            self.tryResult = Self.describe(resolution, heard: heard, appName: { system.appName(forBundleId: $0) })
        }
    }

    static func describe(_ resolution: VoiceCommandResolution, heard: String, appName: (String) -> String?) -> TryResult {
        switch resolution {
        case .action(let action):
            return TryResult(heard: heard, summary: action.summary(appName: appName), detail: action.detail(appName: appName), resolved: true)
        case .notACommand:
            return TryResult(heard: heard, summary: "Not a command", detail: "Start with \u{201C}switch to\u{201D}, \u{201C}go to\u{201D}, \u{201C}open\u{201D}, or \u{201C}focus\u{201D}, or say \u{201C}go back\u{201D}.", resolved: false)
        case .noMatch(let target):
            return TryResult(heard: heard, summary: "No match", detail: "No running or installed app, and no place, is called \u{201C}\(target)\u{201D}.", resolved: false)
        case .ambiguous(let names):
            return TryResult(heard: heard, summary: "More than one match", detail: "\(names.joined(separator: ", ")). Say more of the name, or give one a place nickname.", resolved: false)
        case .needsTabs:
            return TryResult(heard: heard, summary: "Could not read browser tabs", detail: "", resolved: false)
        }
    }
}
