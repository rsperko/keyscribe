import Foundation

public struct VoiceCommandCatalog: Equatable, Sendable {
    public struct App: Equatable, Hashable, Sendable {
        public var name: String
        public var bundleId: String
        public init(name: String, bundleId: String) {
            self.name = name
            self.bundleId = bundleId
        }
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
    case script(VoiceCommandScript, arguments: [String])
    case window(VoiceCommandCatalog.Window)
    case goBack

    public func summary(appName: (String) -> String?) -> String {
        switch self {
        case .app(let app): return app.name
        case .window(let window): return "\(window.title) \u{00B7} \(window.appName)"
        case .goBack: return "Back"
        case .place(let place, .tab(let tab)):
            return appName(tab.browserBundleId).map { "\(place.name) · \($0)" } ?? place.name
        case .place(let place, _): return place.name
        case .script(let script, _): return script.name
        }
    }

    public func detail(appName: (String) -> String?) -> String {
        switch self {
        case .app(let app): return "Brings \(app.name) to the front, opening it if needed."
        case .window(let window):
            return "Brings the window \u{201C}\(window.title)\u{201D} in \(window.appName) to the front."
        case .goBack: return "Returns to the window or app you were in before your last command."
        case .place(_, .app(let bundleId)):
            return "Brings \(appName(bundleId) ?? bundleId) to the front, opening it if needed."
        case .place(_, .tab(let tab)):
            return "Focuses the open tab \u{201C}\(tab.title)\u{201D} in \(appName(tab.browserBundleId) ?? tab.browserBundleId)."
        case .place(_, .openURL(let url, let browser)):
            let inBrowser = browser.map { " in \(appName($0) ?? $0)" } ?? ""
            return "No open tab matches, so it opens \(url)\(inBrowser)."
        case .script(let script, let arguments):
            if script.isShortcut { return script.commandLine(arguments: arguments) }
            return "Runs \(script.commandLine(arguments: arguments)) in the background."
        }
    }

    public func command(appName: (String) -> String?) -> String {
        if case .script(let script, let arguments) = self { return script.commandLine(arguments: arguments) }
        return detail(appName: appName)
    }
}

public enum VoiceCommandResolution: Equatable, Sendable {
    case notACommand
    case action(VoiceCommandAction)
    case ambiguous(VoiceCommandChoice)
    case unavailable(String)
    case noMatch(String)
    case needsTabs(browser: String?)
    case needsWindows
    case windowsIncomplete
    case windowsNeedAccessibility
    case browserNotAllowed(String)
    case scriptNeedsText(String)
    case scriptNotFound(String)
}

public enum VoiceCommandResolver {
    public static func resolve(_ transcript: String, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        let intent = VoiceCommandGrammar.parse(transcript)
        switch intent {
        case nil: return .notACommand
        case .goBack: return .action(.goBack)
        case .focus(let target): return resolve(target: target, catalog: catalog)
        case .runScript(let target):
            return resolveScript(transcript, scripts: catalog.scripts) ?? .scriptNotFound(target)
        }
    }

    public static func resolveScript(_ transcript: String, scripts: [VoiceCommandScript]) -> VoiceCommandResolution? {
        guard !scripts.isEmpty, case .runScript = VoiceCommandGrammar.parse(transcript) else { return nil }
        let words = VoiceCommandGrammar.spokenWords(transcript)
        return resolveScript(transcript, words: words, from: 1, scripts: scripts)
    }

    private static func resolveScript(
        _ transcript: String, words: [VoiceCommandGrammar.SpokenWord], from start: Int, scripts: [VoiceCommandScript]
    ) -> VoiceCommandResolution? {
        var matches: [(script: VoiceCommandScript, length: Int, text: String)] = []
        for script in scripts {
            for form in script.spokenForms {
                let formWords = VoiceCommandText.key(form).split(separator: " ").map(String.init)
                let end = start + formWords.count
                guard !formWords.isEmpty, end <= words.count, words[start..<end].map(\.key) == formWords else { continue }
                let text = VoiceCommandGrammar.cleanedText(transcript[words[end - 1].end...])
                if script.takesText || text.isEmpty { matches.append((script, formWords.count, text)) }
            }
        }
        guard let longest = matches.map(\.length).max() else { return nil }
        var seen = Set<String>()
        let hits = matches.filter { $0.length == longest && seen.insert(VoiceCommandText.key($0.script.name)).inserted }
        guard hits.count == 1, let hit = hits.first else {
            let target = words[start..<(start + longest)].map(\.key).joined(separator: " ")
            return .ambiguous(VoiceCommandChoice(
                family: .action, target: target, matches: hits.map { .script($0.script) }, text: hits.first?.text ?? ""))
        }
        if hit.script.takesText && hit.text.isEmpty { return .scriptNeedsText(hit.script.name) }
        return .action(.script(hit.script, arguments: hit.script.arguments(text: hit.text)))
    }

    private enum Match { case exact, partial }

    private static func resolve(target: String, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        let places = catalog.places.map(VoiceCommandCandidate.place)
        let running = Self.ordered(catalog.runningApps).map(VoiceCommandCandidate.app)
        let installed = Self.ordered(catalog.installedApps).map(VoiceCommandCandidate.app)
        let named: [([VoiceCommandCandidate], Match)] = [
            (places, .exact), (running, .exact), (running, .partial), (places, .partial), (installed, .exact),
        ]
        if let resolution = firstTier(named, target: target, catalog: catalog) { return resolution }

        let windows: [VoiceCommandCandidate]
        switch catalog.windows {
        case nil: return .needsWindows
        case .incomplete: return .windowsIncomplete
        case .needsAccessibility: return .windowsNeedAccessibility
        case .complete(let listed): windows = Self.ordered(listed).map(VoiceCommandCandidate.window)
        }
        let rest: [([VoiceCommandCandidate], Match)] = [(windows, .exact), (windows, .partial), (installed, .partial)]
        if let resolution = firstTier(rest, target: target, catalog: catalog) { return resolution }

        return nearestMiss(target, among: places + running, tiers: Array(named.prefix(4)), catalog: catalog)
            ?? .noMatch(target)
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
        _ target: String, among pool: [VoiceCommandCandidate], tiers: [([VoiceCommandCandidate], Match)], catalog: VoiceCommandCatalog
    ) -> VoiceCommandResolution? {
        let spoken = VoiceCommandText.key(target)
        var nearest: [(candidate: VoiceCommandCandidate, snapped: String)] = []
        var nearestDistance = Int.max
        for candidate in pool {
            let terms = candidate.spokenForms.flatMap { [$0] + $0.split(separator: " ").map(String.init) }
            let snapped = VoiceCommandText.key(FuzzyCorrector.apply(target, prepared: FuzzyCorrector.prepare(terms)))
            guard snapped != spoken,
                  candidate.spokenForms.contains(where: { matches(snapped, $0, .exact) || matches(snapped, $0, .partial) })
            else { continue }
            let distance = FuzzyCorrector.levenshtein(VoiceCommandText.compact(spoken), VoiceCommandText.compact(snapped))
            if distance < nearestDistance { nearest = []; nearestDistance = distance }
            if distance == nearestDistance { nearest.append((candidate, snapped)) }
        }
        for (tierPool, match) in tiers {
            var seen = Set<String>()
            let hits = nearest.filter { entry in
                tierPool.contains(entry.candidate)
                    && entry.candidate.spokenForms.contains { matches(entry.snapped, $0, match) }
                    && seen.insert(entry.candidate.identity).inserted
            }.map(\.candidate)
            if hits.count == 1 { return action(for: hits[0], catalog: catalog) }
            if hits.count > 1 { return .ambiguous(VoiceCommandChoice(family: .navigation, target: target, matches: hits)) }
        }
        return nil
    }

    private static func firstTier(
        _ tiers: [([VoiceCommandCandidate], Match)], target: String, catalog: VoiceCommandCatalog
    ) -> VoiceCommandResolution? {
        for (pool, match) in tiers {
            var seen = Set<String>()
            let hits = pool.filter { candidate in
                candidate.spokenForms.contains { matches(target, $0, match) } && seen.insert(candidate.identity).inserted
            }
            if hits.count == 1 { return action(for: hits[0], catalog: catalog) }
            if hits.count > 1 { return .ambiguous(VoiceCommandChoice(family: .navigation, target: target, matches: hits)) }
        }
        return nil
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
            return .action(.app(app))
        case .window(let window):
            return .action(.window(window))
        case .place(let chosen):
            guard let current = catalog.places.first(where: { $0.hasSameDestination(as: chosen) }) else {
                return .unavailable(chosen.name)
            }
            return action(for: .place(current), catalog: catalog)
        case .script(let chosen):
            guard let current = catalog.scripts.first(where: {
                VoiceCommandText.key($0.name) == VoiceCommandText.key(chosen.name) && $0.action == chosen.action
            }) else { return .unavailable(chosen.name) }
            if current.takesText && text.isEmpty { return .scriptNeedsText(current.name) }
            return .action(.script(current, arguments: current.arguments(text: text)))
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
        }
    }

    private static func action(for candidate: VoiceCommandCandidate, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        switch candidate {
        case .app(let app):
            return .action(.app(app))
        case .script(let script):
            return .unavailable(script.name)
        case .window(let window):
            return .action(.window(window))
        case .place(let place):
            switch place.target {
            case .app(let bundleId):
                return .action(.place(place, .app(bundleId: bundleId)))
            case .url(let url):
                guard let tabs = catalog.tabs else { return .needsTabs(browser: place.browser) }
                let open = tabs.first { tab in
                    (place.browser == nil || place.browser == tab.browserBundleId) && urlMatches(tab.url, place: url)
                }
                if let open { return .action(.place(place, .tab(open))) }
                return .action(.place(place, .openURL(url, browser: place.browser)))
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
