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

    public var places: [VoiceCommandPlace]
    public var runningApps: [App]
    public var installedApps: [App]
    public var tabs: [Tab]?

    public init(places: [VoiceCommandPlace] = [], runningApps: [App] = [], installedApps: [App] = [], tabs: [Tab]? = nil) {
        self.places = places
        self.runningApps = runningApps
        self.installedApps = installedApps
        self.tabs = tabs
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
    case goBack

    public func summary(appName: (String) -> String?) -> String {
        switch self {
        case .app(let app): return app.name
        case .goBack: return "Back"
        case .place(let place, .tab(let tab)):
            return appName(tab.browserBundleId).map { "\(place.name) · \($0)" } ?? place.name
        case .place(let place, _): return place.name
        }
    }

    public func detail(appName: (String) -> String?) -> String {
        switch self {
        case .app(let app): return "Brings \(app.name) to the front, opening it if needed."
        case .goBack: return "Returns to the app you were in before your last command."
        case .place(_, .app(let bundleId)):
            return "Brings \(appName(bundleId) ?? bundleId) to the front, opening it if needed."
        case .place(_, .tab(let tab)):
            return "Focuses the open tab \u{201C}\(tab.title)\u{201D} in \(appName(tab.browserBundleId) ?? tab.browserBundleId)."
        case .place(_, .openURL(let url, let browser)):
            let inBrowser = browser.map { " in \(appName($0) ?? $0)" } ?? ""
            return "No open tab matches, so it opens \(url)\(inBrowser)."
        }
    }
}

public enum VoiceCommandResolution: Equatable, Sendable {
    case notACommand
    case action(VoiceCommandAction)
    case ambiguous([String])
    case noMatch(String)
    case needsTabs(browser: String?)
}

public enum VoiceCommandResolver {
    static let ambiguityLimit = 3

    public static func resolve(_ transcript: String, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        switch VoiceCommandGrammar.parse(transcript) {
        case nil: return .notACommand
        case .goBack: return .action(.goBack)
        case .focus(let target): return resolve(target: target, catalog: catalog)
        }
    }

    private enum Candidate: Equatable {
        case place(VoiceCommandPlace)
        case app(VoiceCommandCatalog.App)

        var identity: String {
            switch self {
            case .place(let place): "place:\(VoiceCommandText.key(place.name))"
            case .app(let app): "app:\(app.bundleId)"
            }
        }

        var displayName: String {
            switch self {
            case .place(let place): place.name
            case .app(let app): app.name
            }
        }

        var spokenForms: [String] {
            switch self {
            case .place(let place): place.spokenForms
            case .app(let app): [app.name]
            }
        }
    }

    private enum Match { case exact, partial }

    private static func resolve(target: String, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        let places = catalog.places.map(Candidate.place)
        let running = catalog.runningApps.map(Candidate.app)
        let installed = catalog.installedApps.map(Candidate.app)
        let tiers: [([Candidate], Match)] = [
            (places, .exact), (running, .exact), (running, .partial), (places, .partial),
            (installed, .exact), (installed, .partial),
        ]
        if let resolution = firstTier(tiers, target: target, catalog: catalog) { return resolution }

        return nearestMiss(target, among: places + running, tiers: Array(tiers.prefix(4)), catalog: catalog)
            ?? .noMatch(target)
    }

    private static func nearestMiss(
        _ target: String, among pool: [Candidate], tiers: [([Candidate], Match)], catalog: VoiceCommandCatalog
    ) -> VoiceCommandResolution? {
        let spoken = VoiceCommandText.key(target)
        var nearest: [(candidate: Candidate, snapped: String)] = []
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
            if hits.count > 1 { return .ambiguous(hits.prefix(ambiguityLimit).map(\.displayName)) }
        }
        return nil
    }

    private static func firstTier(
        _ tiers: [([Candidate], Match)], target: String, catalog: VoiceCommandCatalog
    ) -> VoiceCommandResolution? {
        for (pool, match) in tiers {
            var seen = Set<String>()
            let hits = pool.filter { candidate in
                candidate.spokenForms.contains { matches(target, $0, match) } && seen.insert(candidate.identity).inserted
            }
            if hits.count == 1 { return action(for: hits[0], catalog: catalog) }
            if hits.count > 1 { return .ambiguous(hits.prefix(ambiguityLimit).map(\.displayName)) }
        }
        return nil
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

    private static func action(for candidate: Candidate, catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        switch candidate {
        case .app(let app):
            return .action(.app(app))
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
