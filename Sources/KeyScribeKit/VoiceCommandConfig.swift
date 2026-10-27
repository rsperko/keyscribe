import Foundation
import TOMLKit

public struct VoiceCommandPlace: Encodable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case app(bundleId: String)
        case url(String)
        case tabSearch
    }

    public var id: String
    public var name: String
    public var say: [String]
    public var target: Target
    public var browser: String?

    public init(id: String? = nil, name: String, say: [String] = [], target: Target, browser: String? = nil) {
        self.id = id ?? VoiceCommandNaming.defaultId(name)
        self.name = name
        self.say = say
        self.target = target
        self.browser = browser
    }

    public var isTabSearch: Bool { target == .tabSearch }

    public var spokenForms: [String] { VoiceCommandNaming.spokenForms(name: name, say: say) }

    public func hasSameDestination(as other: VoiceCommandPlace) -> Bool {
        id == other.id && target == other.target && browser == other.browser
    }

    public var issue: String? {
        if let issue = VoiceCommandNaming.issue(name: name, say: say) { return issue }
        switch target {
        case .app(let bundleId):
            if let issue = UserInputValidation.identifierIssue(bundleId, required: true) { return "App: \(issue.message)" }
        case .url(let url):
            if let issue = Self.linkIssue(url) { return "Web page: \(issue)" }
        case .tabSearch:
            break
        }
        if let browser {
            if let issue = UserInputValidation.identifierIssue(browser, required: true) { return "Browser: \(issue.message)" }
            if isAppLink { return "Browser: An app link opens in its own app, so leave the browser unset." }
        }
        return nil
    }

    public var isAppLink: Bool {
        guard case .url(let url) = target else { return false }
        return Self.isAppLink(url)
    }

    static let refusedLinkSchemes: Set<String> = ["file", "javascript", "data", "blob", "about", "ftp", "http", "https"]

    public static func isAppLink(_ url: String) -> Bool {
        guard let scheme = linkScheme(url) else { return false }
        return !refusedLinkSchemes.contains(scheme)
    }

    private static func linkScheme(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let scheme = trimmed[..<colon]
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first), first.isASCII,
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) }),
              URLComponents(string: trimmed) != nil
        else { return nil }
        return scheme.lowercased()
    }

    public static func linkIssue(_ url: String) -> String? {
        guard let scheme = linkScheme(url), !["http", "https"].contains(scheme) else {
            return UserInputValidation.endpointIssue(url).map { _ in
                "Enter a complete http or https address, or a link that opens an app."
            }
        }
        if let issue = UserInputValidation.singleLineIssue(url, required: true, limit: UserInputValidation.endpointLimit) {
            return issue.message
        }
        guard !refusedLinkSchemes.contains(scheme) else { return "Links that start with \(scheme): can\u{2019}t be used." }
        let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
        guard components?.user == nil, components?.password == nil else {
            return UserInputValidation.Issue.credentialsNotAllowed.message
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, say, app, url, browser
        case findTab = "find_tab"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if !say.isEmpty { try c.encode(say, forKey: .say) }
        switch target {
        case .app(let bundleId): try c.encode(bundleId, forKey: .app)
        case .url(let url): try c.encode(url, forKey: .url)
        case .tabSearch: try c.encode(true, forKey: .findTab)
        }
        try c.encodeIfPresent(browser, forKey: .browser)
    }
}

public struct VoiceCommandShortcut: Equatable, Sendable {
    public var name: String
    public var identifier: String?
    public var input: String?

    public init(name: String, identifier: String? = nil, input: String? = nil) {
        self.name = name
        self.identifier = identifier
        self.input = input
    }

    public var target: String { identifier ?? name }

    public static func parseList(_ output: String) -> [VoiceCommandShortcut] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) {
                let identifier = String(line[open.upperBound..<line.index(before: line.endIndex)])
                if UUID(uuidString: identifier) != nil {
                    return VoiceCommandShortcut(name: String(line[..<open.lowerBound]), identifier: identifier)
                }
            }
            return VoiceCommandShortcut(name: line)
        }
    }
}

public struct VoiceCommandScript: Encodable, Equatable, Sendable {
    public static let textPlaceholder = "{text}"

    public enum Action: Equatable, Sendable {
        case program([String])
        case shortcut(VoiceCommandShortcut)
    }

    public var id: String
    public var name: String
    public var say: [String]
    public var action: Action

    public init(id: String? = nil, name: String, say: [String] = [], run: [String]) {
        self.id = id ?? VoiceCommandNaming.defaultId(name)
        self.name = name
        self.say = say
        action = .program(run)
    }

    public init(id: String? = nil, name: String, say: [String] = [], shortcut: VoiceCommandShortcut) {
        self.id = id ?? VoiceCommandNaming.defaultId(name)
        self.name = name
        self.say = say
        action = .shortcut(shortcut)
    }

    public var run: [String] {
        if case .program(let run) = action { return run }
        return []
    }

    public var shortcut: VoiceCommandShortcut? {
        if case .shortcut(let shortcut) = action { return shortcut }
        return nil
    }

    public var isShortcut: Bool { shortcut != nil }

    public var program: String { run.first ?? "" }

    public var takesText: Bool {
        switch action {
        case .program(let run): run.dropFirst().contains { $0.contains(Self.textPlaceholder) }
        case .shortcut(let shortcut): shortcut.input?.contains(Self.textPlaceholder) ?? false
        }
    }

    public func arguments(text: String) -> [String] {
        switch action {
        case .program(let run): run.dropFirst().map { $0.replacingOccurrences(of: Self.textPlaceholder, with: text) }
        case .shortcut(let shortcut): shortcut.input.map { [$0.replacingOccurrences(of: Self.textPlaceholder, with: text)] } ?? []
        }
    }

    public func commandLine(arguments: [String]) -> String {
        if let shortcut {
            let input = arguments.first.map { " with \u{201C}\($0)\u{201D} as its input" } ?? ""
            return "Runs the shortcut \u{201C}\(shortcut.name)\u{201D}\(input)."
        }
        let shownProgram = program.hasPrefix("~/") && !Self.isShellSafe(program.dropFirst(2))
            ? "~/" + Self.shellQuoted(program.dropFirst(2))
            : Self.shellQuoted(program, allowingHome: true)
        return ([shownProgram] + arguments.map { Self.shellQuoted($0) }).joined(separator: " ")
    }

    private static func isShellSafe(_ text: Substring, allowingHome: Bool = false) -> Bool {
        !text.isEmpty && text.first != "=" && text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "_-./:,@%+=".contains($0) || (allowingHome && $0 == "~"))
        }
    }

    private static func shellQuoted(_ text: some StringProtocol, allowingHome: Bool = false) -> String {
        if isShellSafe(Substring(text), allowingHome: allowingHome) { return String(text) }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public var spokenForms: [String] { VoiceCommandNaming.spokenForms(name: name, say: say) }

    public var issue: String? {
        if let issue = VoiceCommandNaming.issue(name: name, say: say) { return issue }
        switch action {
        case .program(let run): return Self.programIssue(run)
        case .shortcut(let shortcut): return Self.shortcutIssue(shortcut)
        }
    }

    private static func programIssue(_ run: [String]) -> String? {
        let program = (run.first ?? "").trimmingCharacters(in: .whitespaces)
        if program.isEmpty { return "Program: Choose a program to run." }
        if let issue = UserInputValidation.identifierIssue(program, required: true) { return "Program: \(issue.message)" }
        if program.contains(textPlaceholder) { return "Program: \(textPlaceholder) can only be used in an argument." }
        guard program.hasPrefix("/") || program.hasPrefix("~/") else {
            return "Program: Use a full path, such as /usr/local/bin/tool or ~/bin/tool."
        }
        for (index, argument) in run.dropFirst().enumerated() {
            if let issue = UserInputValidation.identifierIssue(argument) { return "Argument \(index + 1): \(issue.message)" }
        }
        return nil
    }

    // Checked when the action is saved and again at launch, never at load: a refusal disables only this action,
    // so tightening the rule can never make the rest of a saved file unloadable.
    public func executionRefusal(resolvedProgram: String? = nil) -> String? {
        guard case .program(let run) = action, let program = run.first,
              run.dropFirst().contains(where: { $0.contains(Self.textPlaceholder) }) else { return nil }
        var names = [program, resolvedProgram].compactMap { $0 }.map { ($0 as NSString).lastPathComponent }
        var rest = run.dropFirst()
        while let wrapper = names.lazy.compactMap({ Self.wrappers[$0.lowercased()] }).first,
              let operand = Self.operand(of: wrapper, in: rest) {
            if run[operand].contains(Self.textPlaceholder) { return Self.refusal(names[0]) }
            names = [(run[operand] as NSString).lastPathComponent]
            rest = run[(operand + 1)...]
        }
        guard let interpreter = names.first(where: Self.isInterpreter) else { return nil }
        return Self.refusal(interpreter)
    }

    private static func refusal(_ name: String) -> String {
        "With \(textPlaceholder), “\(name)” could run spoken words as code. "
            + "Put the logic in an executable script file and choose that file instead."
    }

    private struct Wrapper {
        var optionsWithValues: Set<String> = []
        var leadingValues = 0
    }

    // Each wrapper's options that take a separate value, and the plain values it reads before its program, so
    // the program it launches can be found without guessing from later arguments.
    private static let wrappers: [String: Wrapper] = [
        "nice": Wrapper(optionsWithValues: ["-n"]),
        "nohup": Wrapper(),
        "xcrun": Wrapper(optionsWithValues: ["--sdk", "-sdk", "--toolchain", "-toolchain"]),
        "timeout": Wrapper(optionsWithValues: ["-s", "--signal", "-k", "--kill-after"], leadingValues: 1),
        "gtimeout": Wrapper(optionsWithValues: ["-s", "--signal", "-k", "--kill-after"], leadingValues: 1),
        "caffeinate": Wrapper(optionsWithValues: ["-t", "-w"]),
        "time": Wrapper(),
        "arch": Wrapper(optionsWithValues: ["-arch"]),
        "sudo": Wrapper(optionsWithValues: ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t"]),
        "doas": Wrapper(optionsWithValues: ["-u", "-C"]),
        "xargs": Wrapper(optionsWithValues: ["-n", "-I", "-J", "-L", "-P", "-R", "-S", "-s", "-E"]),
        "stdbuf": Wrapper(optionsWithValues: ["-i", "-o", "-e"]),
        "taskpolicy": Wrapper(optionsWithValues: ["-c", "-t", "-l", "-d", "-p"]),
    ]

    private static func operand(of wrapper: Wrapper, in arguments: ArraySlice<String>) -> Int? {
        var index = arguments.startIndex
        var leadingValues = wrapper.leadingValues
        var optionsEnded = false
        while index < arguments.endIndex {
            let argument = arguments[index]
            if !optionsEnded, argument == "--" {
                optionsEnded = true
                index += 1
            } else if !optionsEnded, argument.hasPrefix("-"), argument.count > 1 {
                index += wrapper.optionsWithValues.contains(argument) ? 2 : 1
            } else if !optionsEnded, argument.firstMatch(of: /^[A-Za-z_][A-Za-z0-9_]*=/) != nil {
                index += 1
            } else if leadingValues > 0 {
                leadingValues -= 1
                index += 1
            } else {
                return index
            }
        }
        return nil
    }

    private static let interpreterNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "osascript", "python", "perl", "ruby", "node",
        "nodejs", "swift", "awk", "gawk", "mawk", "nawk", "env",
    ]

    private static func isInterpreter(_ fileName: String) -> Bool {
        let name = fileName.lowercased()
        let base = name.firstMatch(of: /^([a-z]+)[0-9]+(?:\.[0-9]+)*$/).map { String($0.1) } ?? name
        return interpreterNames.contains(base)
    }

    private static func shortcutIssue(_ shortcut: VoiceCommandShortcut) -> String? {
        if shortcut.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Shortcut: Choose a shortcut to run." }
        if let issue = UserInputValidation.identifierIssue(shortcut.name, required: true) { return "Shortcut: \(issue.message)" }
        if let identifier = shortcut.identifier, let issue = UserInputValidation.identifierIssue(identifier, required: true) {
            return "Shortcut: \(issue.message)"
        }
        if let input = shortcut.input, let issue = UserInputValidation.identifierIssue(input) { return "Input: \(issue.message)" }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, say, run, shortcut, input
        case shortcutId = "shortcut_id"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if !say.isEmpty { try c.encode(say, forKey: .say) }
        switch action {
        case .program(let run):
            try c.encode(run, forKey: .run)
        case .shortcut(let shortcut):
            try c.encode(shortcut.name, forKey: .shortcut)
            try c.encodeIfPresent(shortcut.identifier, forKey: .shortcutId)
            try c.encodeIfPresent(shortcut.input, forKey: .input)
        }
    }
}

public enum VoiceCommand: Codable, Equatable, Sendable {
    case place(VoiceCommandPlace)
    case script(VoiceCommandScript)

    public var id: String {
        switch self {
        case .place(let place): place.id
        case .script(let script): script.id
        }
    }

    public var name: String {
        switch self {
        case .place(let place): place.name
        case .script(let script): script.name
        }
    }

    public var candidate: VoiceCommandCandidate {
        switch self {
        case .place(let place): .place(place)
        case .script(let script): .script(script)
        }
    }

    var issue: String? {
        switch self {
        case .place(let place): place.issue
        case .script(let script): script.issue
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, say, app, url, browser, run, shortcut, input, sidebar
        case findTab = "find_tab"
        case quickSwitch = "quick_switch"
        case shortcutId = "shortcut_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        let id = try c.decodeIfPresent(String.self, forKey: .id)
        let say = try c.decodeIfPresent([String].self, forKey: .say) ?? []
        let sidebar = try c.decodeIfPresent(String.self, forKey: .sidebar)
        let app = try c.decodeIfPresent(String.self, forKey: .app) ?? sidebar
        let url = try c.decodeIfPresent(String.self, forKey: .url)
        let findTab = try c.decodeIfPresent(Bool.self, forKey: .findTab) ?? false
        let browser = try c.decodeIfPresent(String.self, forKey: .browser)
        let run = try c.decodeIfPresent([String].self, forKey: .run)
        let shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        let shortcutId = try c.decodeIfPresent(String.self, forKey: .shortcutId)
        let input = try c.decodeIfPresent(String.self, forKey: .input)
        _ = try c.decodeIfPresent(Bool.self, forKey: .quickSwitch)
        func invalid(_ problem: String) -> ConfigError { .invalid("command \"\(name)\": \(problem)") }
        let exactlyOne = "set exactly one of app, url, find_tab, run, or shortcut"
        if sidebar != nil, c.contains(.app) { throw invalid(exactlyOne) }
        switch (app, url, findTab, run, shortcut) {
        case (let app?, nil, false, nil, nil):
            guard shortcutId == nil, input == nil else { throw invalid("shortcut_id and input apply only to a shortcut") }
            self = .place(VoiceCommandPlace(id: id, name: name, say: say, target: .app(bundleId: app), browser: browser))
        case (nil, let url?, false, nil, nil):
            guard shortcutId == nil, input == nil else { throw invalid("shortcut_id and input apply only to a shortcut") }
            self = .place(VoiceCommandPlace(id: id, name: name, say: say, target: .url(url), browser: browser))
        case (nil, nil, true, nil, nil):
            guard shortcutId == nil, input == nil else { throw invalid("shortcut_id and input apply only to a shortcut") }
            self = .place(VoiceCommandPlace(
                id: id, name: name, say: say, target: .tabSearch, browser: browser))
        case (nil, nil, false, let run?, nil):
            guard browser == nil else { throw invalid("browser applies only to app, url, or find_tab") }
            guard shortcutId == nil, input == nil else { throw invalid("shortcut_id and input apply only to a shortcut") }
            self = .script(VoiceCommandScript(id: id, name: name, say: say, run: run))
        case (nil, nil, false, nil, let shortcut?):
            guard browser == nil else { throw invalid("browser applies only to app, url, or find_tab") }
            self = .script(VoiceCommandScript(
                id: id, name: name, say: say,
                shortcut: VoiceCommandShortcut(name: shortcut, identifier: shortcutId, input: input)))
        default:
            throw invalid(exactlyOne)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .place(let place): try place.encode(to: encoder)
        case .script(let script): try script.encode(to: encoder)
        }
    }
}

public struct VoiceCommandConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var commands: [VoiceCommand]

    public init(schemaVersion: Int = VoiceCommandStore.currentSchemaVersion, commands: [VoiceCommand]) {
        self.schemaVersion = schemaVersion
        self.commands = commands
    }

    public init(
        schemaVersion: Int = VoiceCommandStore.currentSchemaVersion, places: [VoiceCommandPlace] = [],
        scripts: [VoiceCommandScript] = []
    ) {
        self.init(schemaVersion: schemaVersion, commands: places.map(VoiceCommand.place) + scripts.map(VoiceCommand.script))
    }

    public var places: [VoiceCommandPlace] {
        commands.compactMap { if case .place(let place) = $0 { place } else { nil } }
    }

    public var scripts: [VoiceCommandScript] {
        commands.compactMap { if case .script(let script) = $0 { script } else { nil } }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case commands = "command"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        commands = try c.decodeIfPresent([VoiceCommand].self, forKey: .commands) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        if !commands.isEmpty { try c.encode(commands, forKey: .commands) }
    }

    public var issue: String? {
        var names = Set<String>()
        var ids = Set<String>()
        for command in commands {
            if let issue = command.issue { return "command \"\(command.name)\": \(issue)" }
            guard names.insert(VoiceCommandText.key(command.name)).inserted else {
                return "command \"\(command.name)\": another command already uses this name"
            }
            guard ids.insert(command.id).inserted else {
                return "command \"\(command.name)\": another command already uses the id \"\(command.id)\""
            }
        }
        return nil
    }
}

extension VoiceCommandConfig {
    public func conflicts(for candidate: VoiceCommandCandidate) -> [String] {
        let others = commands.map(\.candidate).filter { $0.identity != candidate.identity }
        return [Self.duplicate(candidate, among: others), Self.longer(candidate, among: others), Self.shorter(candidate, among: others)]
            .compactMap { $0 } + candidate.spokenForms.compactMap(Self.builtInConflict)
    }

    public static func hiddenApps(by candidate: VoiceCommandCandidate, installed: [VoiceCommandCatalog.App]) -> [String] {
        guard case .place(let place) = candidate else { return [] }
        let own: String? = if case .app(let bundleId) = place.target { bundleId } else { nil }
        return place.spokenForms.compactMap { form in
            let spoken = VoiceCommandText.key(form)
            guard let app = installed.first(where: { app in
                app.bundleId != own && app.spokenNames.contains { VoiceCommandText.key($0) == spoken }
            }) else { return nil }
            return "\u{201C}\(form)\u{201D} is also the name of \(app.name), so saying it opens this command instead."
        }
    }

    private static func words(_ phrase: String) -> [Substring] {
        VoiceCommandText.key(phrase).split(separator: " ")
    }

    private static func starts(_ long: String, with short: String) -> Bool {
        let long = words(long)
        let short = words(short)
        return !short.isEmpty && long.count > short.count && Array(long.prefix(short.count)) == short
    }

    private static func duplicate(_ candidate: VoiceCommandCandidate, among others: [VoiceCommandCandidate]) -> String? {
        for form in candidate.spokenForms {
            let spoken = VoiceCommandText.key(form)
            guard !spoken.isEmpty else { continue }
            let sharers = others.filter { $0.spokenForms.contains { VoiceCommandText.key($0) == spoken } }.map(\.name)
            guard !sharers.isEmpty else { continue }
            guard sharers.count < VoiceCommandChoice.displayLimit else {
                return "\(sharers.count + 1) commands answer to \u{201C}\(form)\u{201D}, too many to choose from. Give this one a name of its own."
            }
            return "\u{201C}\(form)\u{201D} is also a name for \(list(sharers)), so saying it will ask you to choose. Give this one a name of its own."
        }
        return nil
    }

    private static func longer(_ candidate: VoiceCommandCandidate, among others: [VoiceCommandCandidate]) -> String? {
        guard candidate.takesWords else { return nil }
        for form in candidate.spokenForms {
            for other in others {
                guard let phrase = other.spokenForms.first(where: { starts($0, with: form) }) else { continue }
                return "\u{201C}\(phrase)\u{201D} runs \(other.name) instead, because its name is longer."
            }
        }
        return nil
    }

    private static func shorter(_ candidate: VoiceCommandCandidate, among others: [VoiceCommandCandidate]) -> String? {
        for form in candidate.spokenForms {
            for other in others where other.takesWords {
                guard other.spokenForms.contains(where: { starts(form, with: $0) }) else { continue }
                let said = candidate.takesWords ? "\(form) \u{2026}" : form
                return "Saying \u{201C}\(said)\u{201D} will run this command instead of \(other.name), because its name is longer."
            }
        }
        return nil
    }

    private static func builtInConflict(_ form: String) -> String? {
        let spoken = words(form)
        guard !spoken.isEmpty else { return nil }
        func covers(_ phrase: String) -> Bool {
            let builtIn = words(phrase)
            return builtIn.count >= spoken.count && Array(builtIn.prefix(spoken.count)) == spoken
        }
        if covers(VoiceCommandGrammar.goBack) {
            return "Saying \u{201C}\(VoiceCommandGrammar.goBack)\u{201D} will run this command instead of returning to the previous window."
        }
        if covers(VoiceCommandGrammar.run) {
            return "Saying \u{201C}\(VoiceCommandGrammar.run) \u{2026}\u{201D} will reach this command instead of your other actions."
        }
        guard let verb = VoiceCommandGrammar.focusVerbs.first(where: covers) else { return nil }
        let alternative = VoiceCommandPhrase.focus.words.first { !covers($0) }.map { " Say \u{201C}\($0) \u{2026}\u{201D} to switch apps." } ?? ""
        return "Saying \u{201C}\(verb) \u{2026}\u{201D} will reach this command instead of switching apps.\(alternative)"
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
    }
}

public enum VoiceCommandStore {
    public static let currentSchemaVersion = 1
    public static let fileName = "voice_commands.toml"

    public static func decode(from toml: String) throws -> VoiceCommandConfig {
        let config = try ConfigDecode.table(toml, supportedVersion: currentSchemaVersion) {
            try TOMLDecoder().decode(VoiceCommandConfig.self, from: $0)
        }
        if let issue = config.issue { throw ConfigError.invalid(issue) }
        return config
    }

    public static func encode(_ config: VoiceCommandConfig) throws -> String {
        try ConfigEncode.toml(config)
    }

    public static func unknownKeys(in toml: String) -> [UnknownConfigKey] {
        ConfigKeyCheck.unknownKeys(
            VoiceCommandConfig.self, in: toml, supportedVersion: currentSchemaVersion, examples: [everyKeyExample])
    }

    static var everyKeyExample: VoiceCommandConfig {
        VoiceCommandConfig(
            places: [
                VoiceCommandPlace(name: "a", say: ["a"], target: .app(bundleId: "a")),
                VoiceCommandPlace(name: "b", say: ["b"], target: .url("https://example.com/"), browser: "b"),
                VoiceCommandPlace(name: "c", say: ["c"], target: .tabSearch, browser: "c"),
            ],
            scripts: [
                VoiceCommandScript(name: "a", say: ["a"], run: ["/a", "{text}"]),
                VoiceCommandScript(
                    name: "b", say: ["b"],
                    shortcut: VoiceCommandShortcut(name: "b", identifier: "b", input: "{text}")),
            ])
    }

    public static func load(supportDir: URL) -> ConfigLoad<VoiceCommandConfig> {
        ConfigLoad.read(supportDir.appendingPathComponent(fileName), decode: decode)
    }

    public static func loadOrDefault(supportDir: URL) -> VoiceCommandConfig {
        if case .loaded(let config) = load(supportDir: supportDir) { return config }
        return VoiceCommandConfig()
    }

    public static func write(_ config: VoiceCommandConfig, to supportDir: URL) throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try encode(config).write(to: supportDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }
}

public enum VoiceCommandNaming {
    public static func newId() -> String { UUID().uuidString.lowercased() }

    static func defaultId(_ name: String) -> String {
        VoiceCommandText.key(name).replacingOccurrences(of: " ", with: "-")
    }

    static func spokenForms(name: String, say: [String]) -> [String] {
        var seen = Set<String>()
        return ([name] + say).filter { seen.insert(VoiceCommandText.key($0)).inserted }
    }

    static func issue(name: String, say: [String]) -> String? {
        if let issue = UserInputValidation.nameIssue(name) { return "Name: \(issue.message)" }
        for form in say {
            if let issue = UserInputValidation.phraseIssue(form) { return "Other names: \(issue.message)" }
        }
        return nil
    }
}
