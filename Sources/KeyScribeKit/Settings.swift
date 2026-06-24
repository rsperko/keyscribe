import Foundation
import TOMLKit

public enum Eviction: String, Codable, Sendable, Equatable {
    case fastest, balanced, frugal
}

public struct Settings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var loadOnLogin: Bool
    public var defaultModeId: String
    public var stt: STT
    public var duringDictation: DuringDictation
    public var history: History
    public var shortcuts: Shortcuts

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case loadOnLogin = "load_on_login"
        case defaultModeId = "default_mode_id"
        case stt
        case duringDictation = "during_dictation"
        case history
        case shortcuts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        loadOnLogin = try c.decodeIfPresent(Bool.self, forKey: .loadOnLogin) ?? Settings.defaults.loadOnLogin
        defaultModeId = try c.decodeIfPresent(String.self, forKey: .defaultModeId) ?? Settings.defaults.defaultModeId
        stt = try c.decodeIfPresent(STT.self, forKey: .stt) ?? Settings.defaults.stt
        duringDictation = try c.decodeIfPresent(DuringDictation.self, forKey: .duringDictation) ?? Settings.defaults.duringDictation
        history = try c.decodeIfPresent(History.self, forKey: .history) ?? Settings.defaults.history
        shortcuts = try c.decodeIfPresent(Shortcuts.self, forKey: .shortcuts) ?? Settings.defaults.shortcuts
    }

    public init(
        schemaVersion: Int, loadOnLogin: Bool, defaultModeId: String,
        stt: STT, duringDictation: DuringDictation, history: History,
        shortcuts: Shortcuts = Shortcuts()
    ) {
        self.schemaVersion = schemaVersion
        self.loadOnLogin = loadOnLogin
        self.defaultModeId = defaultModeId
        self.stt = stt
        self.duringDictation = duringDictation
        self.history = history
        self.shortcuts = shortcuts
    }

    public struct STT: Codable, Equatable, Sendable {
        public var engine: String
        public var eviction: Eviction
        public var evictionIdleSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case engine, eviction
            case evictionIdleSeconds = "eviction_idle_seconds"
        }

        public init(engine: String, eviction: Eviction, evictionIdleSeconds: Int? = nil) {
            self.engine = engine
            self.eviction = eviction
            self.evictionIdleSeconds = evictionIdleSeconds
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Settings.defaults.stt
            engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? d.engine
            eviction = try c.decodeIfPresent(Eviction.self, forKey: .eviction) ?? d.eviction
            evictionIdleSeconds = try c.decodeIfPresent(Int.self, forKey: .evictionIdleSeconds)
        }
    }

    public struct DuringDictation: Codable, Equatable, Sendable {
        public var muteSystemAudio: Bool
        public var keepDisplayAwake: Bool
        public var sounds: Bool

        enum CodingKeys: String, CodingKey {
            case muteSystemAudio = "mute_system_audio"
            case keepDisplayAwake = "keep_display_awake"
            case sounds
        }

        public init(muteSystemAudio: Bool, keepDisplayAwake: Bool, sounds: Bool) {
            self.muteSystemAudio = muteSystemAudio
            self.keepDisplayAwake = keepDisplayAwake
            self.sounds = sounds
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Settings.defaults.duringDictation
            muteSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .muteSystemAudio) ?? d.muteSystemAudio
            keepDisplayAwake = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayAwake) ?? d.keepDisplayAwake
            sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        }
    }

    public struct History: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var retentionDays: Int

        enum CodingKeys: String, CodingKey {
            case enabled
            case retentionDays = "retention_days"
        }

        public init(enabled: Bool, retentionDays: Int) {
            self.enabled = enabled
            self.retentionDays = retentionDays
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Settings.defaults.history
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        }
    }

    // Optional global shortcuts for the standalone correction surfaces (design.md §4.7). An empty
    // string means the shortcut is off; only chord descriptors are honored at registration.
    public struct Shortcuts: Codable, Equatable, Sendable {
        public var addDictionaryEntry: String
        public var addReplacement: String

        enum CodingKeys: String, CodingKey {
            case addDictionaryEntry = "add_dictionary_entry"
            case addReplacement = "add_replacement"
        }

        public init(addDictionaryEntry: String = "", addReplacement: String = "") {
            self.addDictionaryEntry = addDictionaryEntry
            self.addReplacement = addReplacement
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            addDictionaryEntry = try c.decodeIfPresent(String.self, forKey: .addDictionaryEntry) ?? ""
            addReplacement = try c.decodeIfPresent(String.self, forKey: .addReplacement) ?? ""
        }
    }

    public static let defaults = Settings(
        schemaVersion: 1,
        loadOnLogin: false,
        defaultModeId: "plain-dictation",
        stt: STT(engine: "parakeet-tdt-ctc-110m", eviction: .fastest),
        duringDictation: DuringDictation(muteSystemAudio: true, keepDisplayAwake: true, sounds: true),
        history: History(enabled: true, retentionDays: 7),
        shortcuts: Shortcuts()
    )

    func validate() throws {
        guard history.retentionDays >= 0 else {
            throw ConfigError.invalid("history.retention_days must be >= 0")
        }
    }
}

public enum ConfigError: Error, Equatable {
    case missingSchemaVersion
    case newerSchemaVersion(found: Int, supported: Int)
    case invalid(String)
}

public enum SettingsStore {
    public static let currentSchemaVersion = 1
    public static let fileName = "settings.toml"

    public static func decode(from toml: String) throws -> Settings {
        try ConfigDecode.table(toml, supportedVersion: currentSchemaVersion) { table in
            let settings = try TOMLDecoder().decode(Settings.self, from: table)
            try settings.validate()
            return settings
        }
    }

    public static func encode(_ settings: Settings) throws -> String {
        try TOMLEncoder().encode(settings)
    }

    public static func loadOrCreate(supportDir: URL) throws -> Settings {
        let fm = FileManager.default
        let file = supportDir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: file.path) {
            let toml = try String(contentsOf: file, encoding: .utf8)
            return try decode(from: toml)
        }
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try write(Settings.defaults, to: supportDir)
        return Settings.defaults
    }

    public static func write(_ settings: Settings, to supportDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let toml = try encode(settings)
        try toml.write(to: supportDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }
}
