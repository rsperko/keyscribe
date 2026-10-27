import Foundation

public struct VoiceCommandCatalog: Equatable, Sendable {
    public struct App: Equatable, Hashable, Sendable {
        public var name: String
        public var bundleId: String
        public var spokenNames: [String]
        public init(name: String, bundleId: String, spokenNames: [String]? = nil) {
            self.name = name
            self.bundleId = bundleId
            self.spokenNames = spokenNames ?? [name]
        }
    }

    public static func reconciling(installed: [App], with running: [App]) -> [App] {
        let byId = Dictionary(running.map { ($0.bundleId, $0) }, uniquingKeysWith: { first, _ in first })
        return installed.map { byId[$0.bundleId] ?? $0 }
    }

    public struct Tab: Equatable, Sendable {
        public var browserBundleId: String
        public var window: Int
        public var tab: Int
        public var url: String
        public var title: String
        public init(browserBundleId: String, window: Int, tab: Int, url: String, title: String) {
            self.browserBundleId = browserBundleId
            self.window = window
            self.tab = tab
            self.url = url
            self.title = title
        }

        public var siteName: String? {
            guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased()),
                  let host = url.host?.lowercased() else { return nil }
            var labels = host.split(separator: ".").map(String.init)
            if labels.first == "www" { labels.removeFirst() }
            guard labels.count >= 2, let suffix = labels.popLast(), suffix.allSatisfy(\.isLetter) else { return nil }
            if suffix.count == 2, labels.count >= 2, Self.secondLevels.contains(labels[labels.count - 1]) { labels.removeLast() }
            let name = VoiceCommandText.key(labels.joined(separator: " "))
            return name.isEmpty ? nil : name
        }

        private static let secondLevels: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu", "ne", "or"]
    }

    public struct Window: Equatable, Hashable, Sendable {
        public var bundleId: String
        public var appName: String
        public var pid: Int32
        public var id: String
        public var title: String
        public var isMinimized: Bool
        public var document: String?
        public init(
            bundleId: String, appName: String, pid: Int32, id: String, title: String, isMinimized: Bool = false,
            document: String? = nil
        ) {
            self.bundleId = bundleId
            self.appName = appName
            self.pid = pid
            self.id = id
            self.title = title
            self.isMinimized = isMinimized
            self.document = document
        }
    }

    public struct SidebarItem: Equatable, Hashable, Sendable {
        public var bundleId: String
        public var pid: Int32
        public var name: String
        public var section: String?
        public var path: [Int]
        public var window: UInt32?
        public init(bundleId: String, pid: Int32, name: String, section: String?, path: [Int], window: UInt32? = nil) {
            self.bundleId = bundleId
            self.pid = pid
            self.name = name
            self.section = section
            self.path = path
            self.window = window
        }
    }

    public enum WindowScan: Equatable, Sendable {
        case complete([Window])
        case incomplete
        case needsAccessibility
    }

    public var places: [VoiceCommandPlace]
    public var scripts: [VoiceCommandScript]
    public var runningApps: [App]
    public var installedApps: [App]
    public var tabs: [Tab]?
    public var windows: WindowScan?
    public var sidebarItems: [SidebarItem]?
    public var findsInApps = false
    public var tabBrowsers: Set<String> = []

    public init(
        places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = [], runningApps: [App] = [],
        installedApps: [App] = [], tabs: [Tab]? = nil, windows: WindowScan? = nil
    ) {
        self.places = places
        self.scripts = scripts
        self.runningApps = runningApps
        self.installedApps = installedApps
        self.tabs = tabs
        self.windows = windows
    }
}

public enum AppNaming {
    private static let directionMarks = CharacterSet(charactersIn:
        "\u{200E}\u{200F}\u{061C}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

    public static func usable(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = name.trimmingCharacters(in: directionMarks.union(.whitespacesAndNewlines))
        return VoiceCommandText.key(cleaned).isEmpty ? nil : cleaned
    }

    public static func app(bundleId: String, names: [String?]) -> VoiceCommandCatalog.App {
        var seen = Set<String>()
        let spoken = names.compactMap(usable).filter { seen.insert(VoiceCommandText.key($0)).inserted }
        guard let shown = spoken.first else { return VoiceCommandCatalog.App(name: bundleId, bundleId: bundleId) }
        return VoiceCommandCatalog.App(name: shown, bundleId: bundleId, spokenNames: spoken)
    }
}

public enum WindowTitle {
    static let separators = [" \u{2014} ", " \u{2013} ", " - ", " | ", " \u{00B7} ", " \u{2022} ", ": "]

    public static func segments(_ title: String) -> [String] {
        var parts = [" \(title) "]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public enum VoiceCommandAction: Equatable, Sendable {
    public enum PlaceTarget: Equatable, Sendable {
        case app(bundleId: String)
        case tab(VoiceCommandCatalog.Tab)
        case openURL(String, browser: String?)
    }

    case app(VoiceCommandCatalog.App)
    case place(VoiceCommandPlace, PlaceTarget)
    case script(VoiceCommandScript, arguments: [String], choice: String? = nil)
    case window(VoiceCommandCatalog.Window)
    case tab(VoiceCommandCatalog.Tab)
    case sidebarItem(VoiceCommandCatalog.SidebarItem)
    case goBack

    public func summary(appName: (String) -> String?) -> String {
        switch self {
        case .app(let app): return app.name
        case .window(let window): return "\(window.title) \u{00B7} \(window.appName)"
        case .tab(let tab): return appName(tab.browserBundleId).map { "\(tab.title) \u{00B7} \($0)" } ?? tab.title
        case .sidebarItem(let item): return appName(item.bundleId).map { "\(item.name) \u{00B7} \($0)" } ?? item.name
        case .goBack: return "Back"
        case .place(let place, .tab(let tab)):
            return appName(tab.browserBundleId).map { "\(place.name) · \($0)" } ?? place.name
        case .place(let place, _): return place.name
        case .script(let script, _, _): return script.name
        }
    }

    public func detail(appName: (String) -> String?) -> String {
        switch self {
        case .app(let app): return "Brings \(app.name) to the front, opening it if needed."
        case .window(let window):
            return "Brings the window \u{201C}\(window.title)\u{201D} in \(window.appName) to the front."
        case .tab(let tab):
            return "Focuses the open tab \u{201C}\(tab.title)\u{201D} in \(appName(tab.browserBundleId) ?? tab.browserBundleId)."
        case .sidebarItem(let item):
            return "Opens \u{201C}\(item.name)\u{201D} in the sidebar of \(appName(item.bundleId) ?? item.bundleId)."
        case .goBack: return "Returns to the window or app you were in before your last command."
        case .place(_, .app(let bundleId)):
            return "Brings \(appName(bundleId) ?? bundleId) to the front, opening it if needed."
        case .place(_, .tab(let tab)):
            return "Focuses the open tab \u{201C}\(tab.title)\u{201D} in \(appName(tab.browserBundleId) ?? tab.browserBundleId)."
        case .place(let place, .openURL(let url, _)) where place.isAppLink:
            return "Opens \(url) in the app that handles it."
        case .place(_, .openURL(let url, let browser)):
            let inBrowser = browser.map { " in \(appName($0) ?? $0)" } ?? ""
            return "No open tab matches, so it opens \(url)\(inBrowser)."
        case .script(let script, let arguments, _):
            if script.isShortcut { return script.commandLine(arguments: arguments) }
            return "Runs \(script.commandLine(arguments: arguments)) in the background."
        }
    }

    public func command(appName: (String) -> String?) -> String {
        if case .script(let script, let arguments, _) = self { return script.commandLine(arguments: arguments) }
        return detail(appName: appName)
    }
}

public enum SidebarProblem: Equatable, Sendable {
    case notRunning
    case needsAccessibility
    case noSidebar
    case windowUnknown
    case noResponse
    case notReady
    case turnedOff
}

public enum VoiceCommandResolution: Equatable, Sendable {
    case notACommand
    case action(VoiceCommandAction)
    case ambiguous(VoiceCommandChoice)
    case unavailable(String)
    case noMatch(String)
    case noTabMatch(String, browser: String?)
    case needsTabs(browser: String?)
    case needsSidebar(String)
    case noSidebarMatch(String, app: String)
    case sidebarUnreadable(app: String, SidebarProblem)
    case needsWindows
    case windowsIncomplete
    case windowsNeedAccessibility
    case browserNotAllowed(String)
    case scriptNeedsText(String)
    case takesNoText(String)
    case scriptNotFound(String)
}

public enum VoiceCommandResolver {
    public enum Route: Equatable, Sendable {
        case saved(SavedMatch)
        case goBack
        case focus(String)
        case scriptNotFound(String)
        case notACommand
    }

    public static func route(_ transcript: String, catalog: VoiceCommandCatalog) -> Route {
        if let saved = savedMatch(transcript, catalog: catalog) { return .saved(saved) }
        switch VoiceCommandGrammar.parse(transcript) {
        case nil: return .notACommand
        case .goBack: return .goBack
        case .focus(let target): return .focus(target)
        case .runScript(let target):
            return savedMatch(transcript, from: 1, places: [], scripts: catalog.scripts).map(Route.saved) ?? .scriptNotFound(target)
        }
    }

    public static func resolve(_ transcript: String, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        switch route(transcript, catalog: catalog) {
        case .saved(let match): return resolve(match, catalog: catalog)
        case .goBack: return .action(.goBack)
        case .focus(let target): return resolve(target: target, catalog: catalog)
        case .scriptNotFound(let target): return .scriptNotFound(target)
        case .notACommand: return .notACommand
        }
    }

    public struct SavedMatch: Equatable, Sendable {
        public var candidates: [VoiceCommandCandidate]
        public var text: String
        public var target: String
    }

    public static func savedMatch(_ transcript: String, catalog: VoiceCommandCatalog) -> SavedMatch? {
        savedMatch(transcript, from: 0, places: catalog.places, scripts: catalog.scripts)
    }

    private static func savedMatch(
        _ transcript: String, from start: Int, places: [VoiceCommandPlace], scripts: [VoiceCommandScript]
    ) -> SavedMatch? {
        let words = VoiceCommandGrammar.spokenWords(transcript)
        guard start < words.count else { return nil }
        var hits: [(candidate: VoiceCommandCandidate, length: Int)] = []
        func leading(_ form: String) -> Int? {
            let formWords = VoiceCommandText.key(form).split(separator: " ").map(String.init)
            let end = start + formWords.count
            guard !formWords.isEmpty, end <= words.count, words[start..<end].map(\.key) == formWords else { return nil }
            return formWords.count
        }
        for place in places {
            for form in place.spokenForms {
                if let length = leading(form) { hits.append((.place(place), length)) }
            }
        }
        for script in scripts {
            for form in script.spokenForms {
                if let length = leading(form) { hits.append((.script(script), length)) }
            }
        }
        guard let longest = hits.map(\.length).max() else { return nil }
        var seen = Set<String>()
        let winners = hits.filter { $0.length == longest && seen.insert($0.candidate.identity).inserted }.map(\.candidate)
        let end = start + longest
        return SavedMatch(
            candidates: winners,
            text: VoiceCommandGrammar.cleanedText(transcript[words[end - 1].end...]),
            target: words[start..<end].map(\.key).joined(separator: " "))
    }

    private static func resolve(_ match: SavedMatch, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        guard match.candidates.count == 1, let only = match.candidates.first else {
            let allActions = match.candidates.allSatisfy {
                if case .script = $0 { return true }
                return false
            }
            return .ambiguous(VoiceCommandChoice(
                family: allActions ? .action : .navigation, target: match.target, matches: match.candidates, text: match.text))
        }
        return resolve(only, text: match.text, catalog: catalog)
    }

    private indirect enum Match {
        case exact, partial, words
        case site(Match)
    }

    private static func isSite(_ match: Match) -> Bool {
        if case .site = match { return true }
        return false
    }

    private static func forms(_ candidate: VoiceCommandCandidate, _ match: Match) -> [String] {
        guard case .site = match else { return candidate.spokenForms }
        guard case .tab(let tab) = candidate, let site = tab.siteName else { return [] }
        return [site]
    }

    static func resolveTabSearch(_ place: VoiceCommandPlace, text: String, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        guard !text.isEmpty else {
            guard let browser = place.browser else { return .scriptNeedsText(place.name) }
            return .action(.place(place, .app(bundleId: browser)))
        }
        return findTab(text, in: place.browser, catalog: catalog)
    }

    // Navigation never asks between equal matches it can order: tabs tied in one browser go to the frontmost,
    // and sidebar items tied by name to the first in sidebar order.
    private static func findTab(_ text: String, in browser: String?, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        let settle: ([VoiceCommandCandidate]) -> VoiceCommandCandidate? = { frontmost($0) }
        guard let listed = catalog.tabs else { return .needsTabs(browser: browser) }
        let tabs = listed.filter { browser == nil || $0.browserBundleId == browser }.map(VoiceCommandCandidate.tab)
        let named: [([VoiceCommandCandidate], Match)] = [
            (tabs, .exact), (tabs, .partial), (tabs, .site(.exact)), (tabs, .site(.partial)),
        ]
        if let resolution = firstTier(named, target: text, catalog: catalog, settle: settle) { return resolution }
        return nearestMiss(
            text, among: tabs, tiers: named + [(tabs, .words), (tabs, .site(.words))], catalog: catalog, settle: settle)
            ?? .noTabMatch(text, browser: browser)
    }

    private static func findInApp(_ app: String, text: String, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        if catalog.tabBrowsers.contains(app) { return findTab(text, in: app, catalog: catalog) }
        switch catalog.windows {
        case nil: return .needsWindows
        case .complete(let listed):
            let windows = Self.ordered(listed.filter { $0.bundleId == app }).map(VoiceCommandCandidate.window)
            if let resolution = firstTier([(windows, .exact), (windows, .partial)], target: text, catalog: catalog) {
                return resolution
            }
        case .incomplete, .needsAccessibility: break
        }
        guard let listed = catalog.sidebarItems else { return .needsSidebar(app) }
        let entries = listed.filter { $0.bundleId == app }.map(VoiceCommandCandidate.sidebarItem)
        let named: [([VoiceCommandCandidate], Match)] = [(entries, .exact), (entries, .partial)]
        let first: ([VoiceCommandCandidate]) -> VoiceCommandCandidate? = { $0.first }
        return firstTier(named, target: text, catalog: catalog, settle: first)
            ?? nearestMiss(text, among: entries, tiers: named + [(entries, .words)], catalog: catalog, settle: first)
            ?? .noSidebarMatch(text, app: app)
    }

    private static func resolve(target: String, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        let places = catalog.places.filter { !$0.isTabSearch }.map(VoiceCommandCandidate.place)
        let running = Self.ordered(catalog.runningApps).map(VoiceCommandCandidate.app)
        let installed = Self.ordered(catalog.installedApps).map(VoiceCommandCandidate.app)
        let named: [([VoiceCommandCandidate], Match)] = [
            (places, .exact), (running, .exact), (running, .partial), (installed, .exact), (places, .partial),
        ]
        if catalog.findsInApps {
            let wholeName: [([VoiceCommandCandidate], Match)] = [(places, .exact), (running, .exact), (installed, .exact)]
            if let resolution = firstTier(wholeName, target: target, catalog: catalog) ?? appScope(target, catalog: catalog) {
                return resolution
            }
        }
        if let resolution = firstTier(named, target: target, catalog: catalog) { return resolution }

        let windows: [VoiceCommandCandidate]
        switch catalog.windows {
        case nil: return .needsWindows
        case .incomplete: return .windowsIncomplete
        case .needsAccessibility: return .windowsNeedAccessibility
        case .complete(let listed): windows = Self.ordered(listed).map(VoiceCommandCandidate.window)
        }
        let early: [([VoiceCommandCandidate], Match)] = [(windows, .exact), (windows, .partial)]
        if let resolution = firstTier(early, target: target, catalog: catalog) { return resolution }

        guard let listed = catalog.tabs else { return .needsTabs(browser: nil) }
        let tabs = listed.map(VoiceCommandCandidate.tab)
        let rest: [([VoiceCommandCandidate], Match)] = [
            (tabs, .exact), (tabs, .partial), (tabs, .site(.exact)), (tabs, .site(.partial)), (installed, .partial),
        ]
        let settle: ([VoiceCommandCandidate]) -> VoiceCommandCandidate? = { frontmost($0) }
        if let resolution = firstTier(rest, target: target, catalog: catalog, settle: settle) { return resolution }

        let exhaustive = named + early + rest
        let unordered: [([VoiceCommandCandidate], Match)] = [
            (places, .words), (running, .words), (windows, .words), (tabs, .words), (tabs, .site(.words)), (installed, .words),
        ]
        return nearestMiss(
            target, among: places + running + installed + windows + tabs, tiers: exhaustive + unordered, catalog: catalog,
            settle: settle)
            ?? .noMatch(target)
    }

    // The longest app name or app nickname at the start of the target scopes the rest of it to that app.
    // Saved nicknames outrank running apps, which outrank installed ones, so a nickname can stand in for an app.
    private static func appScope(_ target: String, catalog: VoiceCommandCatalog) -> VoiceCommandResolution? {
        let words = target.split(separator: " ")
        let nicknames = catalog.places.filter { if case .app = $0.target { true } else { false } }.map(VoiceCommandCandidate.place)
        let tiers = [nicknames, catalog.runningApps.map(VoiceCommandCandidate.app), catalog.installedApps.map(VoiceCommandCandidate.app)]
        for length in stride(from: words.count - 1, through: 1, by: -1) {
            let prefix = words.prefix(length).joined(separator: " ")
            for tier in tiers {
                var seen = Set<String>()
                let hits = tier.filter { candidate in
                    candidate.spokenForms.contains { VoiceCommandText.key($0) == prefix }
                        && seen.insert(scopedApp(candidate) ?? candidate.identity).inserted
                }
                guard let first = hits.first else { continue }
                let rest = words.dropFirst(length).joined(separator: " ")
                guard hits.count == 1 else {
                    return .ambiguous(VoiceCommandChoice(family: .navigation, target: prefix, matches: hits, text: rest))
                }
                return resolve(first, text: rest, catalog: catalog)
            }
        }
        return nil
    }

    private static func scopedApp(_ candidate: VoiceCommandCandidate) -> String? {
        switch candidate {
        case .app(let app): app.bundleId
        case .place(let place): if case .app(let bundleId) = place.target { bundleId } else { nil }
        default: nil
        }
    }

    private static func ordered(_ windows: [VoiceCommandCatalog.Window]) -> [VoiceCommandCatalog.Window] {
        windows.enumerated().sorted { a, b in
            let byName = a.element.appName.localizedStandardCompare(b.element.appName)
            if byName != .orderedSame { return byName == .orderedAscending }
            if a.element.bundleId != b.element.bundleId { return a.element.bundleId < b.element.bundleId }
            if a.element.pid != b.element.pid { return a.element.pid < b.element.pid }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func nearestMiss(
        _ target: String, among pool: [VoiceCommandCandidate], tiers: [([VoiceCommandCandidate], Match)], catalog: VoiceCommandCatalog,
        settle: (([VoiceCommandCandidate]) -> VoiceCommandCandidate?)? = nil
    ) -> VoiceCommandResolution? {
        let spoken = VoiceCommandText.key(target)
        var nearest: [(candidate: VoiceCommandCandidate, snapped: String, bySite: Bool)] = []
        var nearestDistance = Int.max
        for candidate in pool {
            for bySite in [false, true] {
                let names = forms(candidate, bySite ? .site(.exact) : .exact)
                let terms = names.flatMap { [$0] + $0.split(separator: " ").map(String.init) }
                guard !terms.isEmpty else { continue }
                let snapped = VoiceCommandText.key(FuzzyCorrector.apply(target, prepared: FuzzyCorrector.prepare(terms)))
                guard names.contains(where: { form in
                    [Match.exact, .partial, .words].contains { matches(snapped, form, $0) }
                }) else { continue }
                let distance = FuzzyCorrector.levenshtein(VoiceCommandText.compact(spoken), VoiceCommandText.compact(snapped))
                if distance < nearestDistance { nearest = []; nearestDistance = distance }
                if distance == nearestDistance { nearest.append((candidate, snapped, bySite)) }
            }
        }
        for (tierPool, match) in tiers {
            var seen = Set<String>()
            let hits = nearest.filter { entry in
                tierPool.contains(entry.candidate)
                    && entry.bySite == isSite(match)
                    && forms(entry.candidate, match).contains { matches(entry.snapped, $0, match) }
                    && seen.insert(entry.candidate.identity).inserted
            }.map(\.candidate)
            if let result = settled(hits, target: target, catalog: catalog, settle: settle) { return result }
        }
        return nil
    }

    private static func firstTier(
        _ tiers: [([VoiceCommandCandidate], Match)], target: String, catalog: VoiceCommandCatalog,
        settle: (([VoiceCommandCandidate]) -> VoiceCommandCandidate?)? = nil
    ) -> VoiceCommandResolution? {
        for (pool, match) in tiers {
            var seen = Set<String>()
            let hits = pool.filter { candidate in
                forms(candidate, match).contains { matches(target, $0, match) } && seen.insert(candidate.identity).inserted
            }
            if let result = settled(hits, target: target, catalog: catalog, settle: settle) { return result }
        }
        return nil
    }

    private static func settled(
        _ hits: [VoiceCommandCandidate], target: String, catalog: VoiceCommandCatalog,
        settle: (([VoiceCommandCandidate]) -> VoiceCommandCandidate?)?
    ) -> VoiceCommandResolution? {
        guard let first = hits.first else { return nil }
        if hits.count == 1 { return action(for: first, catalog: catalog) }
        if let pick = settle?(hits) { return action(for: pick, catalog: catalog) }
        return .ambiguous(VoiceCommandChoice(family: .navigation, target: target, matches: hits))
    }

    private static func frontmost(_ hits: [VoiceCommandCandidate]) -> VoiceCommandCandidate? {
        let tabs = hits.compactMap { candidate -> VoiceCommandCatalog.Tab? in
            if case .tab(let tab) = candidate { return tab }
            return nil
        }
        guard tabs.count == hits.count, Set(tabs.map(\.browserBundleId)).count == 1 else { return nil }
        return tabs.min { ($0.window, $0.tab) < ($1.window, $1.tab) }.map(VoiceCommandCandidate.tab)
    }

    private static func ordered(_ apps: [VoiceCommandCatalog.App]) -> [VoiceCommandCatalog.App] {
        apps.enumerated().sorted { a, b in
            let byName = a.element.name.localizedStandardCompare(b.element.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            if a.element.bundleId != b.element.bundleId { return a.element.bundleId < b.element.bundleId }
            return a.offset < b.offset
        }.map(\.element)
    }

    public static func resolve(
        _ candidate: VoiceCommandCandidate, text: String, catalog: VoiceCommandCatalog
    ) -> VoiceCommandResolution {
        switch candidate {
        case .app(let app):
            guard catalog.findsInApps, !text.isEmpty else { return .action(.app(app)) }
            return findInApp(app.bundleId, text: text, catalog: catalog)
        case .window(let window):
            return .action(.window(window))
        case .tab(let tab):
            return .action(.tab(tab))
        case .sidebarItem(let item):
            return .action(.sidebarItem(item))
        case .place(let chosen):
            guard let current = catalog.places.first(where: { $0.hasSameDestination(as: chosen) }) else {
                return .unavailable(chosen.name)
            }
            if current.isTabSearch { return resolveTabSearch(current, text: text, catalog: catalog) }
            guard !text.isEmpty else { return action(for: .place(current), catalog: catalog) }
            guard catalog.findsInApps, case .app(let bundleId) = current.target else { return .takesNoText(current.name) }
            return findInApp(bundleId, text: text, catalog: catalog)
        case .script(let chosen):
            guard let current = catalog.scripts.first(where: { $0.id == chosen.id && $0.action == chosen.action }) else {
                return .unavailable(chosen.name)
            }
            if current.takesText && text.isEmpty { return .scriptNeedsText(current.name) }
            if !current.takesText && !text.isEmpty { return .takesNoText(current.name) }
            return .action(.script(current, arguments: current.arguments(text: text)))
        case .option(let option):
            guard let current = catalog.scripts.first(where: { $0.id == option.script.id && $0.action == option.script.action })
            else { return .unavailable(option.script.name) }
            return .action(.script(current, arguments: option.arguments, choice: option.value))
        }
    }

    private static func matches(_ target: String, _ form: String, _ match: Match) -> Bool {
        let spoken = VoiceCommandText.key(target)
        let name = VoiceCommandText.key(form)
        guard !spoken.isEmpty, !name.isEmpty else { return false }
        switch match {
        case .exact:
            return spoken == name || VoiceCommandText.compact(spoken) == VoiceCommandText.compact(name)
        case .partial:
            guard spoken != name, VoiceCommandText.compact(spoken).count >= 3 else { return false }
            let words = name.split(separator: " ")
            let wanted = spoken.split(separator: " ")
            guard wanted.count < words.count else { return false }
            return (0...(words.count - wanted.count)).contains { Array(words[$0..<$0 + wanted.count]) == wanted }
        case .words:
            guard VoiceCommandText.compact(spoken).count >= 3 else { return false }
            let words = Set(name.split(separator: " "))
            return spoken.split(separator: " ").allSatisfy(words.contains)
        case .site(let inner):
            return matches(target, form, inner)
        }
    }

    private static func action(for candidate: VoiceCommandCandidate, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        switch candidate {
        case .app(let app):
            return .action(.app(app))
        case .script(let script):
            return .unavailable(script.name)
        case .option(let option):
            return .unavailable(option.script.name)
        case .window(let window):
            return .action(.window(window))
        case .tab(let tab):
            return .action(.tab(tab))
        case .sidebarItem(let item):
            return .action(.sidebarItem(item))
        case .place(let place):
            switch place.target {
            case .app(let bundleId):
                return .action(.place(place, .app(bundleId: bundleId)))
            case .url(let url):
                if place.isAppLink { return .action(.place(place, .openURL(url, browser: nil))) }
                guard let tabs = catalog.tabs else { return .needsTabs(browser: place.browser) }
                let open = tabs.first { tab in
                    (place.browser == nil || place.browser == tab.browserBundleId) && urlMatches(tab.url, place: url)
                }
                if let open { return .action(.place(place, .tab(open))) }
                return .action(.place(place, .openURL(url, browser: place.browser)))
            case .tabSearch:
                return resolveTabSearch(place, text: "", catalog: catalog)
            }
        }
    }

    static func urlMatches(_ tabURL: String, place placeURL: String) -> Bool {
        let tab = comparableURL(tabURL)
        let place = comparableURL(placeURL)
        guard !place.isEmpty, tab.hasPrefix(place) else { return false }
        guard let next = tab.dropFirst(place.count).first else { return true }
        return "/?#".contains(next)
    }

    private static func comparableURL(_ url: String) -> String {
        var s = Substring(url.trimmingCharacters(in: .whitespacesAndNewlines))
        for scheme in ["https://", "http://"] where s.lowercased().hasPrefix(scheme) { s = s.dropFirst(scheme.count) }
        let hostEnd = s.firstIndex { "/?#".contains($0) } ?? s.endIndex
        var host = s[..<hostEnd].lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var rest = String(s[hostEnd...])
        while rest.hasSuffix("/") { rest.removeLast() }
        return host + rest
    }
}
