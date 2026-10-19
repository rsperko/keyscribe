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

    public var spokenForms: [String] {
        var seen = Set<String>()
        return ([name] + say).filter { seen.insert(VoiceCommandText.key($0)).inserted }
    }

    public var issue: String? {
        if let issue = UserInputValidation.nameIssue(name) { return "Name: \(issue.message)" }
        for form in say {
            if let issue = UserInputValidation.phraseIssue(form) { return "Spoken name: \(issue.message)" }
        }
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

    public var spokenForms: [String] {
        var seen = Set<String>()
        return ([name] + say).filter { seen.insert(VoiceCommandText.key($0)).inserted }
    }

    public var issue: String? {
        if let issue = UserInputValidation.nameIssue(name) { return "Name: \(issue.message)" }
        for form in say {
            if let issue = UserInputValidation.phraseIssue(form) { return "Spoken name: \(issue.message)" }
        }
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
        try TOMLEncoder().encode(config)
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
