import Foundation

public struct VoiceCommandExample: Equatable, Sendable {
    public static let sampleWords = "buy milk"
    public static let sampleTabWords = "inbox"

    public var heard: String
    public var result: String
    public var conflict: String?

    public static func make(
        for candidate: VoiceCommandCandidate, among saved: VoiceCommandConfig = VoiceCommandConfig(),
        readAs: (String) -> String = { $0 }, appName: (String) -> String? = { _ in nil }
    ) -> VoiceCommandExample {
        let heard = heard(for: candidate)
        let read = readAs(heard)
        let catalog = catalog(with: candidate, among: saved)
        let lead = read == heard
            ? "Saying \u{201C}\(heard)\u{201D}"
            : "Your replacements read \u{201C}\(heard)\u{201D} as \u{201C}\(read)\u{201D}, so it"
        let resolution = VoiceCommandResolver.resolve(read, catalog: catalog)
        let (handlers, input) = handlers(of: read, resolution: resolution, in: catalog)
        guard handlers.map(\.identity) == [candidate.identity] else {
            let others = handlers.filter { $0.identity != candidate.identity }.map(\.name)
            if others.isEmpty { return VoiceCommandExample(heard: heard, result: "", conflict: "\(lead) does not run this command.") }
            let choices = others.count == handlers.count ? others : ["this command"] + others
            guard choices.count > 1 else {
                let why = read == heard ? ", because its name is longer" : ""
                return VoiceCommandExample(heard: heard, result: "", conflict: "\(lead) runs \(others[0]) instead\(why).")
            }
            return VoiceCommandExample(
                heard: heard, result: "", conflict: "\(lead) would ask you to choose between \(Self.list(choices)).")
        }
        switch resolution {
        case .scriptNeedsText:
            return VoiceCommandExample(heard: heard, result: "", conflict: "\(lead) gives this command no words after its name.")
        case .takesNoText:
            return VoiceCommandExample(heard: heard, result: "", conflict: "\(lead) gives this command words it does not take.")
        default:
            return VoiceCommandExample(heard: heard, result: result(for: candidate, input: input, resolution: resolution, appName: appName))
        }
    }

    private static func list(_ names: [String]) -> String {
        names.count == 2 ? "\(names[0]) and \(names[1])" : names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
    }

    public static func phrases(for candidate: VoiceCommandCandidate) -> [String] {
        let more = candidate.takesWords ? " \u{2026}" : ""
        return candidate.spokenForms.map { $0 + more }
    }

    private static func heard(for candidate: VoiceCommandCandidate) -> String {
        let phrase = VoiceCommandText.key(candidate.name)
        switch candidate {
        case .place(let place) where place.isTabSearch: return "\(phrase) \(sampleTabWords)"
        case .script(let script) where script.takesText: return "\(phrase) \(sampleWords)"
        default: return phrase
        }
    }

    private static func catalog(with candidate: VoiceCommandCandidate, among saved: VoiceCommandConfig) -> VoiceCommandCatalog {
        var commands = saved.commands.filter { $0.candidate.identity != candidate.identity }
        switch candidate {
        case .place(let place): commands.append(.place(place))
        case .script(let script): commands.append(.script(script))
        case .app, .window, .tab: break
        }
        let config = VoiceCommandConfig(commands: commands)
        return VoiceCommandCatalog(places: config.places, scripts: config.scripts, tabs: [], windows: .complete([]))
    }

    private static func handlers(
        of read: String, resolution: VoiceCommandResolution, in catalog: VoiceCommandCatalog
    ) -> (handlers: [VoiceCommandCandidate], input: String) {
        if case .saved(let match) = VoiceCommandResolver.route(read, catalog: catalog) { return (match.candidates, match.text) }
        switch resolution {
        case .action(.place(let place, _)): return ([.place(place)], "")
        case .ambiguous(let choice): return (choice.candidates, choice.text)
        default: return ([], "")
        }
    }

    private static func result(
        for candidate: VoiceCommandCandidate, input: String, resolution: VoiceCommandResolution, appName: (String) -> String?
    ) -> String {
        if case .place(let place) = candidate {
            switch place.target {
            case .tabSearch where !input.isEmpty:
                let scope = place.browser.map { "open \(appName($0) ?? $0) tab" } ?? "open tab, in any browser,"
                return "Switches to the \(scope) whose title best matches \u{201C}\(input)\u{201D}."
            case .url(let url) where !place.isAppLink:
                let inBrowser = place.browser.map { " in \(appName($0) ?? $0)" } ?? ""
                return "Switches to an open tab at \(url)\(inBrowser), or opens it."
            default:
                break
            }
        }
        guard case .action(let action) = resolution else { return "" }
        return action.detail(appName: appName)
    }
}
