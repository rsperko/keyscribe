import Foundation

public enum VoiceCommandCandidate: Equatable, Sendable {
    case place(VoiceCommandPlace)
    case app(VoiceCommandCatalog.App)
    case script(VoiceCommandScript)
    case window(VoiceCommandCatalog.Window)

    public var identity: String {
        switch self {
        case .place(let place): "place:\(VoiceCommandText.key(place.name))"
        case .app(let app): "app:\(app.bundleId)"
        case .script(let script): "script:\(VoiceCommandText.key(script.name))"
        case .window(let window): "window:\(window.bundleId):\(window.pid):\(window.id)"
        }
    }

    public var name: String {
        switch self {
        case .place(let place): place.name
        case .app(let app): app.name
        case .script(let script): script.name
        case .window(let window): window.title
        }
    }

    var spokenForms: [String] {
        switch self {
        case .place(let place): return place.spokenForms
        case .app(let app): return app.spokenNames
        case .script(let script): return script.spokenForms
        case .window(let window):
            let segments = WindowTitle.segments(window.title)
            return segments.contains(window.title) ? segments : segments + [window.title]
        }
    }

    public func detail(appName: (String) -> String?, among others: [VoiceCommandCandidate]) -> String {
        switch self {
        case .place(let place):
            switch place.target {
            case .app(let bundleId):
                return appName(bundleId) ?? bundleId
            case .url(let url):
                let browser = place.browser.map { appName($0) ?? $0 } ?? "Default browser"
                guard let host = URL(string: url)?.host?.lowercased() else { return browser }
                return "\(browser) \u{00B7} \(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)"
            }
        case .app(let app):
            let repeated = others.contains { other in
                if case .app(let peer) = other { return peer.bundleId != app.bundleId && peer.name == app.name }
                return false
            }
            return repeated ? app.bundleId : "App"
        case .script(let script):
            if let shortcut = script.shortcut {
                return shortcut.name == script.name ? "Shortcut" : "Shortcut \u{00B7} \(shortcut.name)"
            }
            return "Script \u{00B7} \((script.program as NSString).lastPathComponent)"
        case .window(let window):
            let tied = others.contains { other in
                if case .window(let peer) = other {
                    return peer != window && VoiceCommandText.key(peer.title) == VoiceCommandText.key(window.title)
                }
                return false
            }
            guard tied, let document = window.document.flatMap(Self.documentLabel) else { return window.appName }
            return "\(window.appName) \u{00B7} \(document)"
        }
    }

    static func documentLabel(_ document: String) -> String? {
        guard let url = URL(string: document) else { return nil }
        if url.isFileURL {
            let parts = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
            return parts.isEmpty ? nil : parts.suffix(2).joined(separator: "/")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

public struct VoiceCommandChoice: Equatable, Sendable {
    public enum Family: Equatable, Sendable {
        case navigation
        case action
    }

    public static let displayLimit = 5

    public var family: Family
    public var target: String
    public var candidates: [VoiceCommandCandidate]
    public var total: Int
    public var text: String

    public init(family: Family, target: String, matches: [VoiceCommandCandidate], text: String = "") {
        self.family = family
        self.target = target
        candidates = Array(matches.prefix(Self.displayLimit))
        total = matches.count
        self.text = text
    }

    public var isOffered: Bool { total <= Self.displayLimit }

    public var tooManyMessage: String {
        "\(total) matches for \u{201C}\(target)\u{201D}. Say more of the name."
    }

    public var title: String {
        switch family {
        case .navigation: "Which one?"
        case .action: "Which action?"
        }
    }

    public var note: String? {
        var groups: [String: Set<Int32>] = [:]
        var counts: [String: Int] = [:]
        for candidate in candidates {
            guard case .window(let window) = candidate else { return nil }
            let row = "\(VoiceCommandText.key(candidate.name))|\(candidate.detail(appName: { _ in nil }, among: candidates))"
            groups[row, default: []].insert(window.pid)
            counts[row, default: 0] += 1
        }
        let tied = groups.filter { counts[$0.key, default: 0] > 1 }
        guard !tied.isEmpty else { return nil }
        guard tied.values.allSatisfy({ $0.count == 1 }) else { return "Same name; these windows can\u{2019}t be told apart." }
        return "Same name; the lower number is further forward."
    }

    public var retryMessage: String {
        "Choose 1\u{2013}\(candidates.count), say \u{201C}cancel\u{201D}, or give a new command."
    }
}

public enum VoiceCommandChoiceAnswer: Equatable, Sendable {
    case select(Int)
    case cancel
    case invalidSelection
    case unrecognized

    private static let cardinals: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "won": 1, "to": 2, "too": 2, "for": 4,
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10,
    ]
    private static let connectives: Set<String> = ["the", "number", "one", "last"]

    public static func parse(_ text: String, count: Int) -> VoiceCommandChoiceAnswer {
        let words = VoiceCommandText.key(text).split(separator: " ").map(String.init)
        if words == ["cancel"] || words == ["never", "mind"] || words == ["nevermind"] { return .cancel }
        guard !words.isEmpty else { return .unrecognized }
        guard let number = selection(in: words, count: count) else {
            return words.allSatisfy(isNumberWord) ? .invalidSelection : .unrecognized
        }
        return (1...max(1, count)).contains(number) && count > 0 ? .select(number - 1) : .invalidSelection
    }

    private static func selection(in words: [String], count: Int) -> Int? {
        if words.count == 1, let number = cardinal(words[0]) { return number }
        if words.count == 2, words[0] == "number", let number = cardinal(words[1]) { return number }
        var rest = words[...]
        if rest.first == "the" { rest = rest.dropFirst() }
        if rest.count == 2, rest.last == "one" { rest = rest.dropLast() }
        guard rest.count == 1, let word = rest.first else { return nil }
        if word == "last" { return count }
        return ordinal(word)
    }

    private static func cardinal(_ word: String) -> Int? {
        if let number = cardinals[word] { return number }
        guard word.allSatisfy(\.isASCII), word.allSatisfy(\.isNumber) else { return nil }
        return Int(word)
    }

    private static func ordinal(_ word: String) -> Int? {
        if let number = ordinals[word] { return number }
        guard word.count > 2, ["st", "nd", "rd", "th"].contains(String(word.suffix(2))) else { return nil }
        return cardinal(String(word.dropLast(2)))
    }

    private static func isNumberWord(_ word: String) -> Bool {
        connectives.contains(word) || cardinal(word) != nil || ordinal(word) != nil
    }
}
