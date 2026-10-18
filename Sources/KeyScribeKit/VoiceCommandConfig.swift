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

public struct VoiceCommandConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var places: [VoiceCommandPlace]

    public init(schemaVersion: Int = VoiceCommandStore.currentSchemaVersion, places: [VoiceCommandPlace] = []) {
        self.schemaVersion = schemaVersion
        self.places = places
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case places = "place"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        places = try c.decodeIfPresent([VoiceCommandPlace].self, forKey: .places) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        if !places.isEmpty { try c.encode(places, forKey: .places) }
    }

    public var issue: String? {
        var names = Set<String>()
        for place in places {
            if let issue = place.issue { return "place \"\(place.name)\": \(issue)" }
            guard names.insert(VoiceCommandText.key(place.name)).inserted else {
                return "place \"\(place.name)\": another place already uses this name"
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
