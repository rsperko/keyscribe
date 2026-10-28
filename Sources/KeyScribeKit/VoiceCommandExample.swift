import Foundation

public struct VoiceCommandExample: Equatable, Sendable {
    public static let sampleWords = "buy milk"
    public static let sampleTabWords = "inbox"

    public var heard: String
    public var result: String
    public var conflict: String?

    public static func make(
        for candidate: VoiceCommandCandidate, sample: String? = nil, among saved: VoiceCommandConfig = VoiceCommandConfig(),
        readAs: (String) -> String = { $0 }, appName: (String) -> String? = { _ in nil }
    ) -> VoiceCommandExample {
        make(for: candidate, heard: heard(for: candidate, saying: candidate.name, sample: sample), among: saved,
             readAs: readAs, appName: appName)
    }

    // Only names a replacement rewrites: a name another command shares is already reported by `conflicts`.
    public static func namesLostToReplacements(
        for candidate: VoiceCommandCandidate, among saved: VoiceCommandConfig = VoiceCommandConfig(),
        readAs: (String) -> String = { $0 }
    ) -> [String] {
        candidate.spokenForms.compactMap { name in
            let heard = heard(for: candidate, saying: name)
            guard readAs(heard) != heard else { return nil }
            return make(for: candidate, heard: heard, among: saved, readAs: readAs, appName: { _ in nil }).conflict
        }
    }

    private static func make(
        for candidate: VoiceCommandCandidate, heard: String, among saved: VoiceCommandConfig,
        readAs: (String) -> String, appName: (String) -> String?
    ) -> VoiceCommandExample {
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

    private static func heard(for candidate: VoiceCommandCandidate, saying name: String, sample: String? = nil) -> String {
        let phrase = VoiceCommandText.key(name)
        switch candidate {
        case .place(let place) where place.isTabSearch: return "\(phrase) \(sampleTabWords)"
        case .script(let script) where script.takesText:
            let words = (sample ?? sampleWords).trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? phrase : "\(phrase) \(words)"
        default: return phrase
        }
    }

    private static func catalog(with candidate: VoiceCommandCandidate, among saved: VoiceCommandConfig) -> VoiceCommandCatalog {
        var commands = saved.commands.filter { $0.candidate.identity != candidate.identity }
        switch candidate {
        case .place(let place): commands.append(.place(place))
        case .script(let script): commands.append(.script(script))
        case .app, .window, .tab, .sidebarItem, .option: break
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
                let across = place.browser == nil ? " Matches in different browsers still ask." : ""
                let tie = " If several match equally, it picks the leftmost match in the frontmost window that has one.\(across)"
                return "Switches to the \(scope) whose title or site best matches \u{201C}\(input)\u{201D}.\(tie)"
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
