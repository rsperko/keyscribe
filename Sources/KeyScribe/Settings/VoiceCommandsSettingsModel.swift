import AppKit
import SwiftUI
import KeyScribeKit

@MainActor
final class VoiceCommandsSettingsModel: ObservableObject {
    @Published private(set) var places: [VoiceCommandPlace] = []
    @Published private(set) var scripts: [VoiceCommandScript] = []
    @Published private(set) var fileNotice: PaneNotice?
    @Published private(set) var tryResult: TryResult?
    @Published private(set) var browserChoices: BrowserChoices = .loading
    @Published private(set) var shortcutChoices: ShortcutChoices = .loading

    enum BrowserChoices: Equatable {
        case loading
        case loaded(browsers: [VoiceCommandCatalog.App], tabBrowsers: Set<String>)
    }

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
            fileNotice = nil
        case .loaded(let config):
            places = config.places
            scripts = config.scripts
            fileNotice = nil
        case .failed(let error):
            let relativePath = VoiceCommandStore.fileName
            fileNotice = .unreadableFile(
                relativePath, error: error,
                file: repository.supportDir.appendingPathComponent(relativePath),
                stillRunning: PaneNotice.stillRunning(
                    repository.runningState(of: relativePath),
                    working: "Your places and actions keep working as they were.",
                    off: "Your places and actions are off until it’s fixed."),
                here: "Places and actions can’t be changed here until then.")
        }
        if !lastTried.isEmpty { tryIt(lastTried) }
    }

    var hasUnreadableFile: Bool { fileNotice != nil }

    private var unreadableFileIssue: String? {
        fileNotice.map { _ in "Fix \(VoiceCommandStore.fileName) before changing places and actions here." }
    }

    func save(_ place: VoiceCommandPlace, replacing originalName: String?) -> String? {
        if let unreadableFileIssue { return unreadableFileIssue }
        if let issue = place.issue { return issue }
        let originalKey = originalName.map(VoiceCommandText.key)
        if nameTaken(place.name, except: originalKey) { return "Another place or action already uses this name." }
        do {
            try repository.mutateVoiceCommands { config in
                if let originalKey {
                    guard let index = config.places.firstIndex(where: { VoiceCommandText.key($0.name) == originalKey }) else {
                        throw StaleEdit()
                    }
                    config.places[index] = place
                } else {
                    config.places.append(place)
                }
            }
            reload()
            return nil
        } catch is StaleEdit {
            reload()
            return Self.staleEditMessage(kind: "place")
        } catch {
            return "Could not save: \(error.localizedDescription)"
        }
    }

    func scriptIssue(_ script: VoiceCommandScript, replacing originalName: String?) -> String? {
        if let unreadableFileIssue { return unreadableFileIssue }
        if let issue = script.issue { return issue }
        if let refusal = script.executionRefusal(resolvedProgram: ScriptLauncher.resolvedPath(script.program)) {
            return "Program: \(refusal)"
        }
        let originalKey = originalName.map(VoiceCommandText.key)
        if nameTaken(script.name, except: originalKey) { return "Another place or action already uses this name." }
        return nil
    }

    func saveScript(_ script: VoiceCommandScript, replacing originalName: String?) -> String? {
        if let issue = scriptIssue(script, replacing: originalName) { return issue }
        let originalKey = originalName.map(VoiceCommandText.key)
        do {
            try repository.mutateVoiceCommands { config in
                if let originalKey {
                    guard let index = config.scripts.firstIndex(where: { VoiceCommandText.key($0.name) == originalKey }) else {
                        throw StaleEdit()
                    }
                    config.scripts[index] = script
                } else {
                    config.scripts.append(script)
                }
            }
            reload()
            return nil
        } catch is StaleEdit {
            reload()
            return Self.staleEditMessage(kind: "action")
        } catch {
            return "Could not save: \(error.localizedDescription)"
        }
    }

    private struct StaleEdit: Error {}

    static func staleEditMessage(kind: String) -> String {
        "This \(kind) was renamed or deleted elsewhere, so your edit was not saved."
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
        return InstalledApps.app(forBundleId: bundleId) ?? AppNaming.app(bundleId: bundleId, names: [app.localizedName])
    }

    func currentTab(of app: VoiceCommandCatalog.App) async -> CurrentTab? {
        let scan = await system.installedSnapshot()
        guard !Task.isCancelled, scan.tabBrowsers.contains(app.bundleId),
              let tab = await system.frontTab(ofBrowser: app.bundleId) else { return nil }
        return CurrentTab(url: tab.url, title: tab.title, browserBundleId: app.bundleId)
    }

    var browsers: [VoiceCommandCatalog.App] {
        guard case .loaded(let browsers, _) = browserChoices else { return [] }
        return browsers
    }

    var isCheckingBrowsers: Bool { browserChoices == .loading }

    func canCaptureTab(of bundleId: String) -> Bool {
        guard case .loaded(_, let tabBrowsers) = browserChoices else { return false }
        return tabBrowsers.contains(bundleId)
    }

    func loadBrowserChoices() async {
        let scan = await system.installedSnapshot()
        let loaded = BrowserChoices.loaded(browsers: scan.browsers, tabBrowsers: scan.tabBrowsers)
        if browserChoices != loaded { browserChoices = loaded }
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
            return TryResult(heard: heard, summary: "Not a command", detail: VoiceCommandRunner.notACommandHint, resolved: false)
        case .scriptNotFound(let target):
            return TryResult(heard: heard, summary: "No matching action", detail: VoiceCommandRunner.notFoundMessage(target), resolved: false)
        case .noMatch(let target):
            return TryResult(heard: heard, summary: "No match", detail: VoiceCommandRunner.noMatchMessage(target), resolved: false)
        case .needsWindows, .windowsIncomplete:
            return TryResult(heard: heard, summary: "Could not check all windows", detail: VoiceCommandRunner.windowsIncompleteMessage, resolved: false)
        case .windowsNeedAccessibility:
            return TryResult(heard: heard, summary: "Accessibility is off", detail: VoiceCommandRunner.windowsNeedAccessibilityMessage, resolved: false)
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
