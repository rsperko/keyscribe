import Foundation

public struct VoiceCommandPreview: Equatable, Sendable {
    public struct Details: Equatable, Sendable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var headline: String
    public var context: String
    public var details: Details?

    public init(headline: String, context: String, details: Details? = nil) {
        self.headline = headline
        self.context = context
        self.details = details
    }
}

extension VoiceCommandAction {
    public func preview(
        spoken: String, appName: (String) -> String?, reach: VoiceCommandReach = .opening, isRunning: (String) -> Bool = { _ in true }
    ) -> VoiceCommandPreview {
        func name(_ bundleId: String) -> String { appName(bundleId) ?? bundleId }
        func app(_ bundleId: String, named shown: String) -> VoiceCommandPreview {
            guard reach == .opening, !isRunning(bundleId) else { return VoiceCommandPreview(headline: "Switch to \(shown)", context: "App") }
            return VoiceCommandPreview(headline: "Open \(shown)", context: "App \u{00B7} starts it if needed")
        }
        switch self {
        case .app(let found):
            return app(found.bundleId, named: found.name)
        case .place(_, .app(let bundleId)):
            return app(bundleId, named: name(bundleId))
        case .window(let window):
            return Self.titled(window.title, spoken: spoken, context: "Window in \(window.appName)")
        case .tab(let tab):
            return Self.titled(tab.title, spoken: spoken, context: "Tab in \(name(tab.browserBundleId))")
        case .place(let place, .tab(let tab)):
            return VoiceCommandPreview(
                headline: "Switch to \(place.name)", context: "Open tab in \(name(tab.browserBundleId))",
                details: .init(label: "Tab title", value: tab.title))
        case .place(let place, .openURL(let url, _)) where place.isAppLink:
            return VoiceCommandPreview(
                headline: "Open \(place.name)", context: "Link \u{00B7} opens in the app that handles it",
                details: .init(label: "Full address", value: url))
        case .place(let place, .openURL(let url, let browser)):
            let site = URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url
            return VoiceCommandPreview(
                headline: "Open \(place.name)", context: "\(site) in \(browser.map { name($0) } ?? "your default browser")",
                details: .init(label: "Full address", value: url))
        case .sidebarItem(let item):
            return VoiceCommandPreview(headline: "Open \(item.name)", context: "In the \(name(item.bundleId)) sidebar")
        case .goBack:
            return VoiceCommandPreview(headline: "Go back", context: "To where you were before your last command")
        case .script(let script, _, _):
            return VoiceCommandPreview(headline: "Run \(script.name)", context: detail(appName: appName))
        }
    }

    private static func titled(_ title: String, spoken: String, context: String) -> VoiceCommandPreview {
        let target: String
        if case .focus(let named, _) = VoiceCommandGrammar.parse(spoken) { target = named } else { target = spoken }
        let said = Set(VoiceCommandText.key(target).split(separator: " ").map(String.init))
        let ranked = WindowTitle.segments(title).enumerated().map { index, segment in
            (index: index, segment: segment, said: said.intersection(VoiceCommandText.key(segment).split(separator: " ").map(String.init)),
             length: VoiceCommandText.key(segment).split(separator: " ").count)
        }.filter { !$0.said.isEmpty }.sorted { a, b in
            (-a.said.count, a.length, a.index) < (-b.said.count, b.length, b.index)
        }
        var covered = Set<String>()
        var kept: [(index: Int, segment: String)] = []
        for candidate in ranked where !candidate.said.isSubset(of: covered) {
            covered.formUnion(candidate.said)
            kept.append((candidate.index, candidate.segment))
        }
        let part = kept.sorted { $0.index < $1.index }.map(\.segment).joined(separator: " \u{2013} ")
        guard !part.isEmpty, part != title else { return VoiceCommandPreview(headline: "Switch to \(title)", context: context) }
        return VoiceCommandPreview(
            headline: "Switch to \(part)", context: context, details: .init(label: "Full title", value: title))
    }
}
