import AppKit
import KeyScribeKit

struct VoiceCommandOrigin: Equatable, Sendable {
    let bundleId: String
}

enum VoiceCommandOutcome: Equatable, Sendable {
    case done(summary: String)
    case failed(message: String)
    case abandoned
}

enum TabFocusResult: Equatable, Sendable {
    case focused
    case gone
    case noResponse
}

@MainActor
protocol VoiceCommandSystem: AnyObject {
    var ownBundleId: String? { get }
    func runningApps() -> [VoiceCommandCatalog.App]
    func installedApps() async -> [VoiceCommandCatalog.App]
    func browserTabs(in browser: String?) async -> [VoiceCommandCatalog.Tab]?
    func appName(forBundleId bundleId: String) -> String?
    func isRunning(bundleId: String) -> Bool
    func isInstalled(bundleId: String) -> Bool
    func openApp(bundleId: String) async -> Bool
    func focusTab(_ tab: VoiceCommandCatalog.Tab) async -> TabFocusResult
    func openURL(_ url: String, browser: String?) async -> Bool
}

@MainActor
protocol VoiceCommandRunning: AnyObject {
    func run(
        transcript: String, places: [VoiceCommandPlace], origin: VoiceCommandOrigin?,
        stillWanted: @MainActor () -> Bool
    ) async -> VoiceCommandOutcome
}

@MainActor
final class VoiceCommandRunner: VoiceCommandRunning {
    private let system: VoiceCommandSystem
    private(set) var backTarget: VoiceCommandOrigin?

    init(system: VoiceCommandSystem = LiveVoiceCommandSystem.shared) {
        self.system = system
    }

    func resolve(_ transcript: String, places: [VoiceCommandPlace]) async -> VoiceCommandResolution {
        let grammarOnly = VoiceCommandResolver.resolve(transcript, catalog: VoiceCommandCatalog())
        if grammarOnly == .notACommand || grammarOnly == .action(.goBack) { return grammarOnly }
        var catalog = VoiceCommandCatalog(
            places: places, runningApps: system.runningApps(), installedApps: await system.installedApps())
        let first = VoiceCommandResolver.resolve(transcript, catalog: catalog)
        guard case .needsTabs(let browser) = first else { return first }
        guard let tabs = await system.browserTabs(in: browser) else { return first }
        catalog.tabs = tabs
        return VoiceCommandResolver.resolve(transcript, catalog: catalog)
    }

    func run(
        transcript: String, places: [VoiceCommandPlace], origin: VoiceCommandOrigin?,
        stillWanted: @MainActor () -> Bool = { true }
    ) async -> VoiceCommandOutcome {
        let resolution = await resolve(transcript, places: places)
        guard stillWanted() else { return .abandoned }
        return await run(resolution, origin: origin, stillWanted: stillWanted)
    }

    func run(
        _ resolution: VoiceCommandResolution, origin: VoiceCommandOrigin?,
        stillWanted: @MainActor () -> Bool = { true }
    ) async -> VoiceCommandOutcome {
        let origin = origin.flatMap { $0.bundleId == system.ownBundleId ? nil : $0 }
        switch resolution {
        case .notACommand:
            return .failed(message: "Not a command. Say \u{201C}switch to\u{201D} an app or place, or \u{201C}go back\u{201D}.")
        case .noMatch(let target):
            return .failed(message: "No app or place called \u{201C}\(target)\u{201D}.")
        case .ambiguous(let names):
            return .failed(message: "More than one match: \(names.joined(separator: ", ")). Say more of the name.")
        case .needsTabs:
            return .failed(message: "The browser did not answer in time, so nothing was opened.")
        case .action(let action):
            return await execute(action, origin: origin, stillWanted: stillWanted)
        }
    }

    private func execute(
        _ action: VoiceCommandAction, origin: VoiceCommandOrigin?, stillWanted: @MainActor () -> Bool
    ) async -> VoiceCommandOutcome {
        let summary = action.summary(appName: system.appName(forBundleId:))
        let succeeded: Bool
        switch action {
        case .goBack:
            guard let back = backTarget, system.isRunning(bundleId: back.bundleId) else {
                return .failed(message: "Nothing to go back to.")
            }
            succeeded = await system.openApp(bundleId: back.bundleId)
            if succeeded { backTarget = origin }
            return succeeded
                ? .done(summary: system.appName(forBundleId: back.bundleId) ?? summary)
                : .failed(message: "Could not go back.")
        case .app(let app):
            succeeded = await system.openApp(bundleId: app.bundleId)
        case .place(_, .app(let bundleId)):
            succeeded = await system.openApp(bundleId: bundleId)
        case .place(let place, .tab(let tab)):
            let focus = await system.focusTab(tab)
            guard focus == .noResponse || stillWanted() else { return .abandoned }
            switch focus {
            case .focused:
                succeeded = await system.openApp(bundleId: tab.browserBundleId)
            case .noResponse:
                let browser = system.appName(forBundleId: tab.browserBundleId) ?? "The browser"
                return .failed(message: "\(browser) did not respond, so \(place.name) was not opened again.")
            case .gone:
                guard case .url(let url) = place.target else { return .failed(message: "Could not switch to \(summary).") }
                if let refusal = browserRefusal(place.browser, place: place) { return refusal }
                succeeded = await system.openURL(url, browser: place.browser)
            }
        case .place(let place, .openURL(let url, let browser)):
            if let refusal = browserRefusal(browser, place: place) { return refusal }
            succeeded = await system.openURL(url, browser: browser)
        }
        guard succeeded else { return .failed(message: "Could not switch to \(summary).") }
        if let origin { backTarget = origin }
        return .done(summary: summary)
    }

    private func browserRefusal(_ browser: String?, place: VoiceCommandPlace) -> VoiceCommandOutcome? {
        guard let browser, !system.isInstalled(bundleId: browser) else { return nil }
        return .failed(message: "The browser chosen for \(place.name) is not installed.")
    }
}

@MainActor
final class LiveVoiceCommandSystem: VoiceCommandSystem {
    static let shared = LiveVoiceCommandSystem()

    private var installedCache: (apps: [VoiceCommandCatalog.App], loadedAt: Date)?
    private static let installedTTL: TimeInterval = 60
    private static let scripts = DeadlineQueue(label: "com.keyscribe.voice-commands.applescript")
    private static let tabReadDeadline: TimeInterval = 1.5
    private static let focusDeadline: TimeInterval = 2

    var ownBundleId: String? { Bundle.main.bundleIdentifier }

    func runningApps() -> [VoiceCommandCatalog.App] {
        InstalledApps.running()
            .filter { $0.bundleId != ownBundleId }
            .map { VoiceCommandCatalog.App(name: $0.name, bundleId: $0.bundleId) }
    }

    func installedApps() async -> [VoiceCommandCatalog.App] {
        if let installedCache, Date().timeIntervalSince(installedCache.loadedAt) < Self.installedTTL {
            return installedCache.apps
        }
        let own = ownBundleId
        let apps = await Task.detached(priority: .userInitiated) {
            Self.scanInstalledApps(in: Self.applicationRoots, excluding: own)
        }.value
        installedCache = (apps, Date())
        return apps
    }

    nonisolated private static let applicationRoots = [
        URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    nonisolated static func scanInstalledApps(in roots: [URL], excluding own: String?) -> [VoiceCommandCatalog.App] {
        let fm = FileManager.default
        func children(of dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        func isFolder(_ url: URL) -> Bool {
            url.pathExtension.isEmpty && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        var seen = Set<String>()
        var apps: [VoiceCommandCatalog.App] = []
        for root in roots {
            let entries = children(of: root)
            let candidates = entries + entries.filter(isFolder).flatMap(children(of:))
            for url in candidates where url.pathExtension == "app" {
                guard let bundleId = Bundle(url: url)?.bundleIdentifier, bundleId != own,
                      seen.insert(bundleId).inserted else { continue }
                apps.append(VoiceCommandCatalog.App(name: url.deletingPathExtension().lastPathComponent, bundleId: bundleId))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func appName(forBundleId bundleId: String) -> String? {
        InstalledApps.name(forBundleId: bundleId)
    }

    func isRunning(bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    func isInstalled(bundleId: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    func openApp(bundleId: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            Log.context.error("voice command: could not open \(bundleId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func openURL(_ url: String, browser: String?) async -> Bool {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            if let browser {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) else {
                    Log.context.error("voice command: browser \(browser, privacy: .public) is not installed")
                    return false
                }
                _ = try await NSWorkspace.shared.open([target], withApplicationAt: app, configuration: configuration)
            } else {
                _ = try await NSWorkspace.shared.open(target, configuration: configuration)
            }
            return true
        } catch {
            Log.context.error("voice command: could not open a URL: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func browserTabs(in browser: String?) async -> [VoiceCommandCatalog.Tab]? {
        let browsers = Self.runningBrowsers().filter { browser == nil || $0 == browser }
        guard !browsers.isEmpty else { return [] }
        guard case .finished(let tabs) = await Self.scripts.run(within: Self.tabReadDeadline, {
            browsers.flatMap { Self.readTabs(of: $0) }
        }) else {
            Log.context.error("voice command: the browser tabs could not be read in time")
            return nil
        }
        return tabs
    }

    func focusTab(_ tab: VoiceCommandCatalog.Tab) async -> TabFocusResult {
        switch await Self.scripts.run(within: Self.focusDeadline, { BrowserScripting.focus(tab) }) {
        case .expired:
            Log.context.error("voice command: \(tab.browserBundleId, privacy: .public) did not answer the tab focus in time")
            return .noResponse
        case .finished(false):
            return .gone
        case .finished(true):
            return .focused
        }
    }

    func frontTab(ofBrowser bundleId: String) async -> (url: String, title: String)? {
        guard isRunning(bundleId: bundleId), Self.httpsHandlers.contains(bundleId),
              case .finished(let tab) = await Self.scripts.run(within: Self.tabReadDeadline, {
                  BrowserScripting.frontTab(of: bundleId).map { FrontTab(url: $0.url, title: $0.title) }
              }), let tab else { return nil }
        return (tab.url, tab.title)
    }

    private struct FrontTab: Sendable {
        let url: String
        let title: String
    }

    func isBrowser(_ bundleId: String) -> Bool { Self.httpsHandlers.contains(bundleId) }

    private static func runningBrowsers() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return httpsHandlers.filter { running.contains($0) }.sorted()
    }

    nonisolated private static func readTabs(of bundleId: String) -> [VoiceCommandCatalog.Tab] {
        BrowserScripting.tabs(of: bundleId)
    }

    private static let httpsHandlers: Set<String> = {
        guard let https = URL(string: "https://example.com") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: https).compactMap { Bundle(url: $0)?.bundleIdentifier })
    }()

}

enum BrowserScripting {
    private enum Shape: CaseIterable {
        case chromium, safari

        var titleProperty: String {
            switch self {
            case .chromium: "title"
            case .safari: "name"
            }
        }
    }

    static func tabs(of bundleId: String) -> [VoiceCommandCatalog.Tab] {
        for shape in Shape.allCases {
            let source = """
            tell application id "\(bundleId)" to return {URL of every tab of every window, \
            \(shape.titleProperty) of every tab of every window}
            """
            guard let result = run(source), result.numberOfItems == 2,
                  let urls = result.atIndex(1), let titles = result.atIndex(2) else { continue }
            return parse(urls: urls, titles: titles, bundleId: bundleId)
        }
        return []
    }

    static func focus(_ tab: VoiceCommandCatalog.Tab) -> Bool {
        let bodies = [
            "set active tab index of window w to t",
            "set current tab of window w to tab t of window w",
        ]
        for body in bodies {
            if let result = run(focusSource(tab, selecting: body)) { return result.booleanValue }
        }
        return false
    }

    static func focusSource(_ tab: VoiceCommandCatalog.Tab, selecting body: String) -> String {
        sameURLHandler + """
        tell application id \(literal(tab.browserBundleId))
            set wanted to \(literal(tab.url))
            set found to missing value
            if (count of windows) \u{2265} \(tab.window) then
                if (count of tabs of window \(tab.window)) \u{2265} \(tab.tab) then
                    if my sameURL(URL of tab \(tab.tab) of window \(tab.window), wanted) then set found to {\(tab.window), \(tab.tab)}
                end if
            end if
            if found is missing value then
                repeat with w from 1 to count of windows
                    repeat with t from 1 to count of tabs of window w
                        if my sameURL(URL of tab t of window w, wanted) then
                            set found to {w, t}
                            exit repeat
                        end if
                    end repeat
                    if found is not missing value then exit repeat
                end repeat
            end if
            if found is missing value then return false
            set w to item 1 of found
            set t to item 2 of found
            \(body)
            set index of window w to 1
            return true
        end tell
        """
    }

    static let sameURLHandler = """
        on sameURL(candidate, wanted)
            considering case
                return candidate is wanted
            end considering
        end sameURL

        """

    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func frontTab(of bundleId: String) -> (url: String, title: String)? {
        for shape in Shape.allCases {
            let tabRef = shape == .chromium ? "active tab of front window" : "current tab of front window"
            let source = """
            tell application id "\(bundleId)" to return {URL of \(tabRef), \(shape.titleProperty) of \(tabRef)}
            """
            guard let result = run(source), result.numberOfItems == 2,
                  let url = result.atIndex(1)?.stringValue, !url.isEmpty else { continue }
            return (url, result.atIndex(2)?.stringValue ?? "")
        }
        return nil
    }

    private static func parse(urls: NSAppleEventDescriptor, titles: NSAppleEventDescriptor, bundleId: String) -> [VoiceCommandCatalog.Tab] {
        var tabs: [VoiceCommandCatalog.Tab] = []
        guard urls.numberOfItems > 0 else { return tabs }
        for w in 1...urls.numberOfItems {
            guard let windowURLs = urls.atIndex(w), windowURLs.numberOfItems > 0 else { continue }
            let windowTitles = titles.atIndex(w)
            for t in 1...windowURLs.numberOfItems {
                guard let url = windowURLs.atIndex(t)?.stringValue, !url.isEmpty else { continue }
                let title = windowTitles?.atIndex(t)?.stringValue ?? ""
                tabs.append(VoiceCommandCatalog.Tab(browserBundleId: bundleId, window: w, tab: t, url: url, title: title))
            }
        }
        return tabs
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
