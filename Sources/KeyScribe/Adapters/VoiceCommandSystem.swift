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

struct TabRead: Equatable, Sendable {
    var tabs: [VoiceCommandCatalog.Tab]
    var refused: [String] = []
    var unavailable: [String] = []
}

enum BrowserTabsReply: Equatable, Sendable {
    case tabs([VoiceCommandCatalog.Tab])
    case refused
    case unavailable
}

enum TabFocusResult: Equatable, Sendable {
    case focused
    case gone
    case noResponse
}

@MainActor
protocol VoiceCommandSystem: AnyObject {
    var ownBundleId: String? { get }
    func defaultBrowserId(for url: String) -> String?
    func runningApps() -> [VoiceCommandCatalog.App]
    func installedApps() async -> [VoiceCommandCatalog.App]
    func browserTabs(in browser: String?) async -> TabRead?
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
        guard let read = await system.browserTabs(in: browser) else { return first }
        catalog.tabs = read.tabs
        let resolved = VoiceCommandResolver.resolve(transcript, catalog: catalog)
        if case .action(.place(_, .openURL(let url, let opener))) = resolved,
           let destination = opener ?? system.defaultBrowserId(for: url) {
            if read.refused.contains(destination) { return .browserNotAllowed(destination) }
            if read.unavailable.contains(destination) { return .needsTabs(browser: destination) }
        }
        return resolved
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
        case .needsTabs(let browser):
            let name = browser.flatMap(system.appName(forBundleId:)) ?? "The browser"
            return .failed(message: "\(name) did not list its open tabs, so nothing was opened.")
        case .browserNotAllowed(let browser):
            return .failed(message: Self.notAllowedMessage(browser: system.appName(forBundleId: browser) ?? browser))
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

    static func notAllowedMessage(browser: String) -> String {
        "\(Branding.appName) is not allowed to control \(browser), so nothing was opened. Allow it in System Settings \u{2192} Privacy & Security \u{2192} Automation."
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

    func defaultBrowserId(for url: String) -> String? {
        URL(string: url).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

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

    func browserTabs(in browser: String?) async -> TabRead? {
        let browsers = Self.runningTabBrowsers().filter { browser == nil || $0 == browser }
        guard !browsers.isEmpty else { return TabRead(tabs: []) }
        guard case .finished(let read) = await Self.scripts.run(within: Self.tabReadDeadline, { isCurrent in
            Self.collectTabs(from: browsers, isCurrent: isCurrent) { BrowserScripting.tabs(of: $0, isCurrent: isCurrent) }
        }) else {
            Log.context.error("voice command: the browser tabs could not be read in time")
            return nil
        }
        for bundleId in read.refused {
            Log.context.error("voice command: \(bundleId, privacy: .public) refused Automation")
        }
        for bundleId in read.unavailable {
            Log.context.error("voice command: \(bundleId, privacy: .public) tabs could not be read")
        }
        return read
    }

    nonisolated static func collectTabs(
        from browsers: [String], isCurrent: () -> Bool, read: (String) -> BrowserTabsReply
    ) -> TabRead {
        var result = TabRead(tabs: [])
        for bundleId in browsers {
            guard isCurrent() else { break }
            switch read(bundleId) {
            case .tabs(let tabs): result.tabs += tabs
            case .refused: result.refused.append(bundleId)
            case .unavailable: result.unavailable.append(bundleId)
            }
        }
        return result
    }

    func focusTab(_ tab: VoiceCommandCatalog.Tab) async -> TabFocusResult {
        switch await Self.scripts.run(within: Self.focusDeadline, { BrowserScripting.focus(tab, isCurrent: $0) }) {
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
        guard isRunning(bundleId: bundleId), Self.tabBrowsers.contains(bundleId),
              case .finished(let tab) = await Self.scripts.run(within: Self.tabReadDeadline, {
                  BrowserScripting.frontTab(of: bundleId, isCurrent: $0).map { FrontTab(url: $0.url, title: $0.title) }
              }), let tab else { return nil }
        return (tab.url, tab.title)
    }

    private struct FrontTab: Sendable {
        let url: String
        let title: String
    }

    func isBrowser(_ bundleId: String) -> Bool { Self.httpsHandlers.contains(bundleId) }

    private static func runningTabBrowsers() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return tabBrowsers.filter { running.contains($0) }.sorted()
    }

    nonisolated static func hasScriptableTabs(_ app: URL) -> Bool {
        guard let bundle = Bundle(url: app),
              let name = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
              let sdef = bundle.resourceURL?.appendingPathComponent(name),
              let parser = XMLParser(contentsOf: sdef) else { return false }
        let finder = TabClassFinder()
        parser.delegate = finder
        parser.parse()
        return finder.found
    }

    private static let httpsHandlerURLs: [URL] =
        URL(string: "https://example.com").map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []

    private static let httpsHandlers = Set(httpsHandlerURLs.compactMap { Bundle(url: $0)?.bundleIdentifier })

    private static let tabBrowsers = Set(httpsHandlerURLs.filter(hasScriptableTabs).compactMap { Bundle(url: $0)?.bundleIdentifier })

}

private final class TabClassFinder: NSObject, XMLParserDelegate {
    private(set) var found = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        guard elementName == "class", attributes["name"] == "tab" else { return }
        found = true
        parser.abortParsing()
    }
}

enum BrowserScripting {
    static let replyTimeout = 3

    enum Shape: CaseIterable {
        case chromium, safari

        var titleProperty: String {
            switch self {
            case .chromium: "title"
            case .safari: "name"
            }
        }
    }

    static func tabs(of bundleId: String, isCurrent: () -> Bool) -> BrowserTabsReply {
        for shape in Shape.allCases {
            guard isCurrent() else { return .unavailable }
            switch run(tabsSource(of: bundleId, shape: shape)) {
            case .refused:
                return .refused
            case .failed(let code) where code == timedOut:
                return .unavailable
            case .failed:
                continue
            case .value(let result):
                guard result.numberOfItems == 2, let urls = result.atIndex(1), let titles = result.atIndex(2) else { continue }
                return .tabs(parse(urls: urls, titles: titles, bundleId: bundleId))
            }
        }
        return .unavailable
    }

    static func tabsSource(of bundleId: String, shape: Shape) -> String {
        bounded("""
        tell application id \(literal(bundleId)) to return {URL of every tab of every window, \
        \(shape.titleProperty) of every tab of every window}
        """)
    }

    static func frontTabSource(of bundleId: String, shape: Shape) -> String {
        let tabRef = shape == .chromium ? "active tab of front window" : "current tab of front window"
        return bounded("""
        tell application id \(literal(bundleId)) to return {URL of \(tabRef), \(shape.titleProperty) of \(tabRef)}
        """)
    }

    private static func bounded(_ statements: String) -> String {
        "with timeout of \(replyTimeout) seconds\n\(statements)\nend timeout"
    }

    static func focus(_ tab: VoiceCommandCatalog.Tab, isCurrent: () -> Bool) -> Bool {
        let bodies = [
            "set active tab index of window w to t",
            "set current tab of window w to tab t of window w",
        ]
        return firstAnswer(bodies.map { focusSource(tab, selecting: $0) }, isCurrent: isCurrent) { source in
            guard case .value(let result) = run(source) else { return nil }
            return result.booleanValue
        } ?? false
    }

    static func firstAnswer<T>(_ sources: [String], isCurrent: () -> Bool, run: (String) -> T?) -> T? {
        for source in sources {
            guard isCurrent() else { return nil }
            if let answer = run(source) { return answer }
        }
        return nil
    }

    static func focusSource(_ tab: VoiceCommandCatalog.Tab, selecting body: String) -> String {
        sameURLHandler + bounded("""
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
        """)
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

    static func frontTab(of bundleId: String, isCurrent: () -> Bool) -> (url: String, title: String)? {
        firstAnswer(Shape.allCases.map { frontTabSource(of: bundleId, shape: $0) }, isCurrent: isCurrent) { source in
            guard case .value(let result) = run(source), result.numberOfItems == 2,
                  let url = result.atIndex(1)?.stringValue, !url.isEmpty else { return nil }
            return (url, result.atIndex(2)?.stringValue ?? "")
        }
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

    private enum Reply {
        case value(NSAppleEventDescriptor)
        case refused
        case failed(Int)
    }

    private static let notPermitted = -1743
    private static let timedOut = -1712

    private static func run(_ source: String) -> Reply {
        guard let script = NSAppleScript(source: source) else { return .failed(0) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard let error else { return .value(result) }
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        return code == notPermitted ? .refused : .failed(code)
    }
}
