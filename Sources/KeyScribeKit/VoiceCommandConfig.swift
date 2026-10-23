import Foundation
import TOMLKit

public struct VoiceCommandPlace: Codable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case app(bundleId: String)
        case url(String)
    }

    public var name: String
    public var say: [String]
    public var target: Target
    public var browser: String?

    public init(name: String, say: [String] = [], target: Target, browser: String? = nil) {
        self.name = name
        self.say = say
        self.target = target
        self.browser = browser
    }

    public var spokenForms: [String] { VoiceCommandNaming.spokenForms(name: name, say: say) }

    public func hasSameDestination(as other: VoiceCommandPlace) -> Bool {
        VoiceCommandText.key(name) == VoiceCommandText.key(other.name) && target == other.target && browser == other.browser
    }

    public var issue: String? {
        if let issue = VoiceCommandNaming.issue(name: name, say: say) { return issue }
        switch target {
        case .app(let bundleId):
            if let issue = UserInputValidation.identifierIssue(bundleId, required: true) { return "App: \(issue.message)" }
        case .url(let url):
            if let issue = UserInputValidation.endpointIssue(url) { return "Web page: \(issue.message)" }
        }
        if let browser, let issue = UserInputValidation.identifierIssue(browser, required: true) {
            return "Browser: \(issue.message)"
        }
        return nil
    }

    enum CodingKeys: String, CodingKey { case name, say, app, url, browser }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        say = try c.decodeIfPresent([String].self, forKey: .say) ?? []
        browser = try c.decodeIfPresent(String.self, forKey: .browser)
        let app = try c.decodeIfPresent(String.self, forKey: .app)
        let url = try c.decodeIfPresent(String.self, forKey: .url)
        switch (app, url) {
        case (let app?, nil): target = .app(bundleId: app)
        case (nil, let url?): target = .url(url)
        default: throw ConfigError.invalid("place \"\(name)\": set exactly one of app or url")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if !say.isEmpty { try c.encode(say, forKey: .say) }
        switch target {
        case .app(let bundleId): try c.encode(bundleId, forKey: .app)
        case .url(let url): try c.encode(url, forKey: .url)
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

public struct VoiceCommandScript: Codable, Equatable, Sendable {
    public static let textPlaceholder = "{text}"

    public enum Action: Equatable, Sendable {
        case program([String])
        case shortcut(VoiceCommandShortcut)
    }

    public var name: String
    public var say: [String]
    public var action: Action

    public init(name: String, say: [String] = [], run: [String]) {
        self.name = name
        self.say = say
        action = .program(run)
    }

    public init(name: String, say: [String] = [], shortcut: VoiceCommandShortcut) {
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
        case name, say, run, shortcut, input
        case shortcutId = "shortcut_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        say = try c.decodeIfPresent([String].self, forKey: .say) ?? []
        let run = try c.decodeIfPresent([String].self, forKey: .run)
        let shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        let identifier = try c.decodeIfPresent(String.self, forKey: .shortcutId)
        let input = try c.decodeIfPresent(String.self, forKey: .input)
        switch (run, shortcut) {
        case (let run?, nil):
            guard identifier == nil, input == nil else {
                throw ConfigError.invalid("script \"\(name)\": shortcut_id and input apply only to a shortcut")
            }
            action = .program(run)
        case (nil, let shortcut?):
            action = .shortcut(VoiceCommandShortcut(name: shortcut, identifier: identifier, input: input))
        default:
            throw ConfigError.invalid("script \"\(name)\": set exactly one of run or shortcut")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
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

public struct VoiceCommandConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var places: [VoiceCommandPlace]
    public var scripts: [VoiceCommandScript]

    public init(
        schemaVersion: Int = VoiceCommandStore.currentSchemaVersion, places: [VoiceCommandPlace] = [],
        scripts: [VoiceCommandScript] = []
    ) {
        self.schemaVersion = schemaVersion
        self.places = places
        self.scripts = scripts
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case places = "place"
        case scripts = "script"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        places = try c.decodeIfPresent([VoiceCommandPlace].self, forKey: .places) ?? []
        scripts = try c.decodeIfPresent([VoiceCommandScript].self, forKey: .scripts) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        if !places.isEmpty { try c.encode(places, forKey: .places) }
        if !scripts.isEmpty { try c.encode(scripts, forKey: .scripts) }
    }

    public var issue: String? {
        var names = Set<String>()
        for place in places {
            if let issue = place.issue { return "place \"\(place.name)\": \(issue)" }
            guard names.insert(VoiceCommandText.key(place.name)).inserted else {
                return "place \"\(place.name)\": another place already uses this name"
            }
        }
        for script in scripts {
            if let issue = script.issue { return "script \"\(script.name)\": \(issue)" }
            guard names.insert(VoiceCommandText.key(script.name)).inserted else {
                return "script \"\(script.name)\": a place or script already uses this name"
            }
        }
        return nil
    }
}

extension VoiceCommandConfig {
    public func sharedNameAdvisory(for place: VoiceCommandPlace, replacing originalName: String?) -> String? {
        let others = places.filter { !Self.isSame($0.name, place.name, originalName) }
        return Self.sharedNameAdvisory(name: place.name, forms: place.spokenForms, kind: "places",
                                       among: others.map { ($0.name, $0.spokenForms) }, spoken: VoiceCommandText.compact)
    }

    public func sharedNameAdvisory(for script: VoiceCommandScript, replacing originalName: String?) -> String? {
        let others = scripts.filter { !Self.isSame($0.name, script.name, originalName) }
        return Self.sharedNameAdvisory(name: script.name, forms: script.spokenForms, kind: "actions",
                                       among: others.map { ($0.name, $0.spokenForms) }, spoken: VoiceCommandText.key)
    }

    private static func isSame(_ saved: String, _ edited: String, _ original: String?) -> Bool {
        let key = VoiceCommandText.key(saved)
        return key == VoiceCommandText.key(original ?? edited)
    }

    private static func sharedNameAdvisory(
        name: String, forms: [String], kind: String, among others: [(name: String, forms: [String])],
        spoken comparable: (String) -> String
    ) -> String? {
        for form in forms {
            let spoken = comparable(form)
            guard !spoken.isEmpty else { continue }
            let sharers = others.filter { $0.forms.contains { comparable($0) == spoken } }.map(\.name)
            guard !sharers.isEmpty else { continue }
            let names = [name] + sharers
            guard names.count <= VoiceCommandChoice.displayLimit else {
                return "\(names.count) \(kind) answer to \u{201C}\(form)\u{201D}, too many to choose from. Give this one a name of its own."
            }
            let list = names.count == 2
                ? "\(names[0]) and \(names[1])"
                : names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
            return "Saying \u{201C}\(form)\u{201D} will ask you to choose between \(list)."
        }
        return nil
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

enum VoiceCommandNaming {
    static func spokenForms(name: String, say: [String]) -> [String] {
        var seen = Set<String>()
        return ([name] + say).filter { seen.insert(VoiceCommandText.key($0)).inserted }
    }

    static func issue(name: String, say: [String]) -> String? {
        if let issue = UserInputValidation.nameIssue(name) { return "Name: \(issue.message)" }
        for form in say {
            if let issue = UserInputValidation.phraseIssue(form) { return "Spoken name: \(issue.message)" }
        }
        return nil
    }
}
