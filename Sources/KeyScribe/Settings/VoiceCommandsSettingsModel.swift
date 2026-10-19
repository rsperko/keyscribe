import AppKit
import SwiftUI
import KeyScribeKit

@MainActor
final class VoiceCommandsSettingsModel: ObservableObject {
    @Published private(set) var places: [VoiceCommandPlace] = []
    @Published private(set) var scripts: [VoiceCommandScript] = []
    @Published private(set) var loadError: String?
    @Published private(set) var tryResult: TryResult?
    @Published private(set) var appChoices: [VoiceCommandCatalog.App] = []
    @Published private(set) var shortcutChoices: ShortcutChoices = .loading

    enum ShortcutChoices: Equatable {
        case loading
        case loaded([VoiceCommandShortcut])
        case unavailable
    }

    struct TryResult: Equatable {
        let heard: String
        let summary: String
        let detail: String
        let resolved: Bool
        var readAs: String? = nil
        var asksChoice = false
    }

    struct CurrentTab: Equatable {
        let url: String
        let title: String
        let browserBundleId: String
    }

    var previousApp: () -> NSRunningApplication? = { nil }
    let notices: VoiceCommandNotices

    private let repository: ConfigRepository
    private let system: LiveVoiceCommandSystem
    private var tryTask: Task<Void, Never>?
    private var lastTried = ""

    init(repository: ConfigRepository, system: LiveVoiceCommandSystem = .shared) {
        self.repository = repository
        self.system = system
        notices = VoiceCommandNotices(supportDir: repository.supportDir)
        reload()
        repository.addChangeObserver { [weak self] in self?.reload() }
    }

    func reload() {
        switch VoiceCommandStore.load(supportDir: repository.supportDir) {
        case .absent:
            places = []
            scripts = []
            loadError = nil
        case .loaded(let config):
            places = config.places
            scripts = config.scripts
            loadError = nil
        case .failed(let error):
            loadError = "\(VoiceCommandStore.fileName) could not be read (\(Self.describe(error))). Fix or remove the file to edit places and actions here."
        }
        if !lastTried.isEmpty { tryIt(lastTried) }
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
        let originalKey = originalName.map(VoiceCommandText.key)
        if nameTaken(place.name, except: originalKey) { return "Another place or action already uses this name." }
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

    func scriptIssue(_ script: VoiceCommandScript, replacing originalName: String?) -> String? {
        guard loadError == nil else { return loadError }
        if let issue = script.issue { return issue }
        let originalKey = originalName.map(VoiceCommandText.key)
        if nameTaken(script.name, except: originalKey) { return "Another place or action already uses this name." }
        return nil
    }

    func saveScript(_ script: VoiceCommandScript, replacing originalName: String?) -> String? {
        if let issue = scriptIssue(script, replacing: originalName) { return issue }
        let originalKey = originalName.map(VoiceCommandText.key)
        do {
            try repository.mutateVoiceCommands { config in
                if let originalKey, let index = config.scripts.firstIndex(where: { VoiceCommandText.key($0.name) == originalKey }) {
                    config.scripts[index] = script
                } else {
                    config.scripts.append(script)
                }
            }
            reload()
            return nil
        } catch {
            return "Could not save: \(error.localizedDescription)"
        }
    }

    func deleteScript(named name: String) -> String? {
        let key = VoiceCommandText.key(name)
        do {
            try repository.mutateVoiceCommands { config in
                config.scripts.removeAll { VoiceCommandText.key($0.name) == key }
            }
            reload()
            return nil
        } catch {
            return "Could not delete: \(error.localizedDescription)"
        }
    }

    static func programIssue(_ program: String) -> String? {
        let trimmed = program.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { return nil }
        let path = ScriptLauncher.expandedPath(trimmed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return "No file is at this path yet." }
        if isDirectory.boolValue || !FileManager.default.isExecutableFile(atPath: path) {
            return "This file is not executable. Make it executable (chmod +x) so it can run."
        }
        return nil
    }

    func nameTaken(_ name: String, except originalKey: String?) -> Bool {
        let key = VoiceCommandText.key(name)
        guard key != originalKey else { return false }
        return (places.map(\.name) + scripts.map(\.name)).contains { VoiceCommandText.key($0) == key }
    }

    func sharedNameAdvisory(for place: VoiceCommandPlace, replacing originalName: String?) -> String? {
        VoiceCommandConfig(places: places, scripts: scripts).sharedNameAdvisory(for: place, replacing: originalName)
    }

    func sharedNameAdvisory(for script: VoiceCommandScript, replacing originalName: String?) -> String? {
        VoiceCommandConfig(places: places, scripts: scripts).sharedNameAdvisory(for: script, replacing: originalName)
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

    func loadShortcutChoices() async {
        shortcutChoices = (await system.shortcuts()).map(ShortcutChoices.loaded) ?? .unavailable
    }

    func shortcutIsMissing(_ shortcut: VoiceCommandShortcut) -> Bool {
        guard case .loaded(let choices) = shortcutChoices else { return false }
        return !choices.contains { choice in
            shortcut.identifier.map { $0 == choice.identifier } ?? (choice.name == shortcut.name)
        }
    }

    func appName(_ bundleId: String) -> String {
        system.appName(forBundleId: bundleId) ?? bundleId
    }

    func tryIt(_ text: String) {
        tryTask?.cancel()
        let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastTried = heard
        guard !heard.isEmpty else { tryResult = nil; return }
        let places = places
        let scripts = scripts
        tryTask = Task { [weak self, system] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let readAs = self?.readAs(heard) else { return }
            let runner = VoiceCommandRunner(system: system)
            let resolution = await runner.resolve(readAs, places: places, scripts: scripts)
            guard !Task.isCancelled, let self else { return }
            self.tryResult = Self.describe(
                resolution, heard: heard, readAs: readAs, appName: { system.appName(forBundleId: $0) })
        }
    }

    func readAs(_ heard: String) -> String {
        repository.resolved.voiceCommandText(heard: heard)
    }

    static func describe(
        _ resolution: VoiceCommandResolution, heard: String, readAs: String, appName: (String) -> String?
    ) -> TryResult {
        var result = describe(resolution, heard: heard, appName: appName)
        if readAs != heard { result.readAs = readAs }
        return result
    }

    static func describe(_ resolution: VoiceCommandResolution, heard: String, appName: (String) -> String?) -> TryResult {
        switch resolution {
        case .action(let action):
            return TryResult(heard: heard, summary: action.summary(appName: appName), detail: action.detail(appName: appName), resolved: true)
        case .notACommand:
            return TryResult(heard: heard, summary: "Not a command", detail: "Say \u{201C}switch to\u{201D} or \u{201C}open\u{201D} an app or place, \u{201C}run\u{201D} a script or shortcut, or \u{201C}go back\u{201D}.", resolved: false)
        case .scriptNotFound(let target):
            return TryResult(heard: heard, summary: "No matching action", detail: VoiceCommandRunner.notFoundMessage(target), resolved: false)
        case .noMatch(let target):
            return TryResult(heard: heard, summary: "No match", detail: "No running or installed app, and no place, is called \u{201C}\(target)\u{201D}.", resolved: false)
        case .ambiguous(let choice):
            guard choice.isOffered else {
                return TryResult(heard: heard, summary: "Too many matches", detail: choice.tooManyMessage, resolved: false)
            }
            let rows = choice.candidates.enumerated().map { index, candidate in
                "\(index + 1). \(candidate.name) (\(candidate.detail(appName: appName, among: choice.candidates)))"
            }
            return TryResult(
                heard: heard, summary: "Would ask \u{201C}\(choice.title)\u{201D}",
                detail: "When spoken, this command would ask you to choose: " + rows.joined(separator: "  "),
                resolved: false, asksChoice: true)
        case .unavailable(let name):
            return TryResult(heard: heard, summary: "Not available", detail: VoiceCommandRunner.unavailableMessage(name), resolved: false)
        case .scriptNeedsText(let name):
            return TryResult(heard: heard, summary: "Needs more words", detail: VoiceCommandRunner.needsTextMessage(script: name), resolved: false)
        case .needsTabs:
            return TryResult(heard: heard, summary: "Could not read browser tabs", detail: "", resolved: false)
        case .browserNotAllowed(let browser):
            return TryResult(heard: heard, summary: "Not allowed to control the browser",
                             detail: VoiceCommandRunner.notAllowedMessage(browser: appName(browser) ?? browser), resolved: false)
        }
    }
}
