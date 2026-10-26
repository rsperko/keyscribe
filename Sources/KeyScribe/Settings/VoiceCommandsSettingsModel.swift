import AppKit
import SwiftUI
import KeyScribeKit

@MainActor
final class VoiceCommandsSettingsModel: ObservableObject {
    @Published private(set) var commands: [VoiceCommand] = []
    @Published private(set) var fileNotice: PaneNotice?
    @Published private(set) var tryResult: TryResult?
    @Published private(set) var browserChoices: BrowserChoices = .loading
    @Published private(set) var shortcutChoices: ShortcutChoices = .loading
    @Published var requestedSidebarCommand = false

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
    private var revision = 0
    private var sidebarExampleCache: (place: VoiceCommandPlace, items: SidebarListing, revision: Int, example: SidebarExample?)?

    init(repository: ConfigRepository, system: LiveVoiceCommandSystem = .shared) {
        self.repository = repository
        self.system = system
        notices = VoiceCommandNotices(supportDir: repository.supportDir)
        reload()
        repository.addChangeObserver { [weak self] in self?.reload() }
    }

    func reload() {
        revision += 1
        switch VoiceCommandStore.load(supportDir: repository.supportDir) {
        case .absent:
            commands = []
            fileNotice = nil
        case .loaded(let config):
            commands = config.commands
            fileNotice = nil
        case .failed(let error):
            let relativePath = VoiceCommandStore.fileName
            fileNotice = .unreadableFile(
                relativePath, error: error,
                file: repository.supportDir.appendingPathComponent(relativePath),
                stillRunning: PaneNotice.stillRunning(
                    repository.runningState(of: relativePath),
                    working: "Your commands keep working as they were.",
                    off: "Your commands are off until it’s fixed."),
                here: "Commands can’t be changed here until then.")
        }
        if !lastTried.isEmpty { tryIt(lastTried) }
    }

    var hasUnreadableFile: Bool { fileNotice != nil }

    var places: [VoiceCommandPlace] { saved.places }

    var scripts: [VoiceCommandScript] { saved.scripts }

    private var unreadableFileIssue: String? {
        fileNotice.map { _ in "Fix \(VoiceCommandStore.fileName) before changing commands here." }
    }

    func save(_ place: VoiceCommandPlace, replacing originalName: String?) -> String? {
        if let unreadableFileIssue { return unreadableFileIssue }
        if let issue = place.issue { return issue }
        if nameTaken(place.name, except: place.id) { return Self.nameTakenMessage }
        return store(.place(place), editing: originalName != nil)
    }

    private func store(_ command: VoiceCommand, editing: Bool) -> String? {
        do {
            try repository.mutateVoiceCommands { config in
                let index = config.commands.firstIndex(where: { $0.id == command.id })
                switch (index, editing) {
                case (let index?, true): config.commands[index] = command
                case (nil, true): throw StaleEdit()
                case (_?, false): throw NameTaken()
                case (nil, false): config.commands.append(command)
                }
            }
            reload()
            return nil
        } catch is StaleEdit {
            reload()
            return Self.staleEditMessage
        } catch is NameTaken {
            return Self.nameTakenMessage
        } catch {
            return "Could not save: \(error.localizedDescription)"
        }
    }

    func scriptIssue(_ script: VoiceCommandScript) -> String? {
        if let unreadableFileIssue { return unreadableFileIssue }
        if let issue = script.issue { return issue }
        if let refusal = script.executionRefusal(resolvedProgram: ScriptLauncher.resolvedPath(script.program)) {
            return "Program: \(refusal)"
        }
        if nameTaken(script.name, except: script.id) { return Self.nameTakenMessage }
        return nil
    }

    func saveScript(_ script: VoiceCommandScript, replacing originalName: String?) -> String? {
        if let issue = scriptIssue(script) { return issue }
        return store(.script(script), editing: originalName != nil)
    }

    private struct StaleEdit: Error {}
    private struct NameTaken: Error {}

    static let nameTakenMessage = "Another command already uses this name."

    func linkAppName(_ url: String) -> String? {
        guard let link = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let app = NSWorkspace.shared.urlForApplication(toOpen: link),
              let bundleId = Bundle(url: app)?.bundleIdentifier
        else { return nil }
        return system.appName(forBundleId: bundleId) ?? bundleId
    }

    static let staleEditMessage = "This command was deleted elsewhere, so your edit was not saved."

    func delete(id: String) -> String? {
        do {
            try repository.mutateVoiceCommands { config in
                config.commands.removeAll { $0.id == id }
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

    func nameTaken(_ name: String, except id: String) -> Bool {
        let key = VoiceCommandText.key(name)
        return commands.contains { $0.id != id && VoiceCommandText.key($0.name) == key }
    }

    var saved: VoiceCommandConfig { VoiceCommandConfig(commands: commands) }

    func conflicts(for candidate: VoiceCommandCandidate) -> [String] {
        saved.conflicts(for: candidate)
    }

    func example(for candidate: VoiceCommandCandidate) -> VoiceCommandExample {
        VoiceCommandExample.make(
            for: candidate, among: saved, readAs: readAs,
            appName: { [system] in system.appName(forBundleId: $0) })
    }

    typealias SidebarExample = (heard: String, item: VoiceCommandCatalog.SidebarItem)

    // Each search resolves against a whole sidebar, so it runs once per input and reload rather than on every
    // render; `revision` moves with every config change, because a saved command or replacement can take the phrase.
    func sidebarExample(for place: VoiceCommandPlace, items: SidebarListing) -> SidebarExample? {
        if let cached = sidebarExampleCache, cached.place == place, cached.items == items, cached.revision == revision {
            return cached.example
        }
        let example = VoiceCommandExample.sidebarExample(for: place, items: items, among: saved, readAs: readAs)
        sidebarExampleCache = (place, items, revision, example)
        return example
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

    var sidebarSearchEnabled: Bool { repository.sidebarSearchEnabled }

    func checkSidebar(of bundleId: String) async -> VoiceCommandRunner.SidebarCheck {
        await VoiceCommandRunner.checkSidebar(of: bundleId, system: system)
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
        let sidebars = repository.sidebarSearchEnabled
        tryTask = Task { [weak self, system] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let readAs = self?.readAs(heard) else { return }
            let runner = VoiceCommandRunner(system: system)
            let resolution = await runner.resolve(readAs, places: places, scripts: scripts)
            guard !Task.isCancelled, let self else { return }
            self.tryResult = Self.describe(
                resolution, heard: heard, readAs: readAs, sidebars: sidebars, appName: { system.appName(forBundleId: $0) })
        }
    }

    func readAs(_ heard: String) -> String {
        repository.resolved.voiceCommandText(heard: heard)
    }

    static func describe(
        _ resolution: VoiceCommandResolution, heard: String, readAs: String, sidebars: Bool = false,
        appName: (String) -> String?
    ) -> TryResult {
        var result = describe(resolution, heard: heard, sidebars: sidebars, appName: appName)
        if readAs != heard { result.readAs = readAs }
        return result
    }

    static func describe(
        _ resolution: VoiceCommandResolution, heard: String, sidebars: Bool = false, appName: (String) -> String?
    ) -> TryResult {
        switch resolution {
        case .action(let action):
            return TryResult(heard: heard, summary: action.summary(appName: appName), detail: action.detail(appName: appName), resolved: true)
        case .notACommand:
            return TryResult(heard: heard, summary: "Not a command", detail: VoiceCommandRunner.notACommandHint, resolved: false)
        case .scriptNotFound(let target):
            return TryResult(heard: heard, summary: "No matching action", detail: VoiceCommandRunner.notFoundMessage(target), resolved: false)
        case .noMatch(let target):
            return TryResult(heard: heard, summary: "No match", detail: VoiceCommandRunner.noMatchMessage(target), resolved: false)
        case .noTabMatch(let target, let browser):
            return TryResult(heard: heard, summary: "No matching tab",
                             detail: VoiceCommandRunner.noTabMatchMessage(target, browser: browser.map { appName($0) ?? $0 }), resolved: false)
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
        case .takesNoText(let name):
            return TryResult(heard: heard, summary: "Too many words", detail: VoiceCommandRunner.takesNoTextMessage(name), resolved: false)
        case .needsTabs:
            return TryResult(heard: heard, summary: "Could not read browser tabs", detail: "", resolved: false)
        case .sidebarUnreadable(let app, .turnedOff) where sidebars:
            return TryResult(heard: heard, summary: "Looks in \(appName(app) ?? app)\u{2019}s sidebar",
                             detail: "The preview does not read sidebars. Use Show Available Items in this command\u{2019}s editor to see what it can open.",
                             resolved: false)
        case .sidebarUnreadable(_, .turnedOff):
            return TryResult(heard: heard, summary: "Turned off", detail: VoiceCommandRunner.sidebarTurnedOffMessage, resolved: false)
        case .needsSidebar(let app), .sidebarUnreadable(let app, _):
            return TryResult(heard: heard, summary: "Could not read the sidebar",
                             detail: "\(appName(app) ?? app)\u{2019}s sidebar could not be checked.", resolved: false)
        case .noSidebarMatch(let target, let app):
            return TryResult(heard: heard, summary: "No matching entry",
                             detail: VoiceCommandRunner.noSidebarMatchMessage(target, app: appName(app) ?? app), resolved: false)
        case .browserNotAllowed(let browser):
            return TryResult(heard: heard, summary: "Not allowed to control the browser",
                             detail: VoiceCommandRunner.notAllowedMessage(browser: appName(browser) ?? browser), resolved: false)
        }
    }
}
