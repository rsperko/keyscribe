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

public struct VoiceCommandScript: Codable, Equatable, Sendable {
    public static let textPlaceholder = "{text}"

    public var name: String
    public var say: [String]
    public var run: [String]

    public init(name: String, say: [String] = [], run: [String]) {
        self.name = name
        self.say = say
        self.run = run
    }

    public var program: String { run.first ?? "" }

    public var takesText: Bool { run.dropFirst().contains { $0.contains(Self.textPlaceholder) } }

    public func arguments(text: String) -> [String] {
        run.dropFirst().map { $0.replacingOccurrences(of: Self.textPlaceholder, with: text) }
    }

    public var spokenForms: [String] {
        var seen = Set<String>()
        return ([name] + say).filter { seen.insert(VoiceCommandText.key($0)).inserted }
    }

    public var issue: String? {
        if let issue = UserInputValidation.nameIssue(name) { return "Name: \(issue.message)" }
        if let word = Self.commandWord(name) { return "Name: \(word)" }
        for form in say {
            if let issue = UserInputValidation.phraseIssue(form) { return "Spoken name: \(issue.message)" }
            if let word = Self.commandWord(form) { return "Spoken name: \(word)" }
        }
        let program = program.trimmingCharacters(in: .whitespaces)
        if program.isEmpty { return "Program: Choose a program to run." }
        if let issue = UserInputValidation.identifierIssue(program, required: true) { return "Program: \(issue.message)" }
        if program.contains(Self.textPlaceholder) { return "Program: \(Self.textPlaceholder) can only be used in an argument." }
        guard program.hasPrefix("/") || program.hasPrefix("~/") else {
            return "Program: Use a full path, such as /usr/local/bin/tool or ~/bin/tool."
        }
        for (index, argument) in run.dropFirst().enumerated() {
            if let issue = UserInputValidation.identifierIssue(argument) { return "Argument \(index + 1): \(issue.message)" }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey { case name, say, run }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        say = try c.decodeIfPresent([String].self, forKey: .say) ?? []
        run = try c.decode([String].self, forKey: .run)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if !say.isEmpty { try c.encode(say, forKey: .say) }
        try c.encode(run, forKey: .run)
    }

    private static func commandWord(_ form: String) -> String? {
        let words = VoiceCommandText.key(form).split(separator: " ")
        guard !words.isEmpty else { return nil }
        let phrases = (VoiceCommandGrammar.focusVerbs + [VoiceCommandGrammar.goBack]).map { $0.split(separator: " ") }
        guard phrases.contains(where: { $0.starts(with: words) }) else { return nil }
        return "\u{201C}\(form)\u{201D} is already a command word. Choose another spoken name."
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
