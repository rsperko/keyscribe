import Foundation
import TOMLKit

public enum Eviction: String, Codable, Sendable, Equatable {
    case fastest, balanced, frugal
}

public struct Settings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var loadOnLogin: Bool
    public var stt: STT
    public var duringDictation: DuringDictation
    public var history: History
    public var shortcuts: Shortcuts
    public var audio: Audio

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case loadOnLogin = "load_on_login"
        case stt
        case duringDictation = "during_dictation"
        case history
        case shortcuts
        case audio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        loadOnLogin = try c.decodeIfPresent(Bool.self, forKey: .loadOnLogin) ?? Settings.defaults.loadOnLogin
        // `default_mode_id` was removed when the Direct floor took over the primary role; an old file's
        // key is simply ignored here and dropped on the next write (see AGENTS.md "Config migrations").
        stt = try c.decodeIfPresent(STT.self, forKey: .stt) ?? Settings.defaults.stt
        duringDictation = try c.decodeIfPresent(DuringDictation.self, forKey: .duringDictation) ?? Settings.defaults.duringDictation
        history = try c.decodeIfPresent(History.self, forKey: .history) ?? Settings.defaults.history
        shortcuts = try c.decodeIfPresent(Shortcuts.self, forKey: .shortcuts) ?? Settings.defaults.shortcuts
        audio = try c.decodeIfPresent(Audio.self, forKey: .audio) ?? Settings.defaults.audio
    }

    public init(
        schemaVersion: Int, loadOnLogin: Bool,
        stt: STT, duringDictation: DuringDictation, history: History,
        shortcuts: Shortcuts = Shortcuts(), audio: Audio = Audio()
    ) {
        self.schemaVersion = schemaVersion
        self.loadOnLogin = loadOnLogin
        self.stt = stt
        self.duringDictation = duringDictation
        self.history = history
        self.shortcuts = shortcuts
        self.audio = audio
    }

    public struct STT: Codable, Equatable, Sendable {
        public var engine: String
        public var eviction: Eviction
        public var evictionIdleSeconds: Int?
        // Bias-less engine ids that recover dictionary terms via the post-STT fuzzy stage. Only the
        // active engine's membership matters (it gates that engine's pipeline); listed per id so the
        // choice persists independently across engines. Defaults to every bias-exempt engine on.
        public var dictionaryRecoveryEngines: [String]

        enum CodingKeys: String, CodingKey {
            case engine, eviction
            case evictionIdleSeconds = "eviction_idle_seconds"
            case dictionaryRecoveryEngines = "dictionary_recovery_engines"
        }

        public init(
            engine: String, eviction: Eviction, evictionIdleSeconds: Int? = nil,
            dictionaryRecoveryEngines: [String] = SpeechModelCatalog.biasExemptIds
        ) {
            self.engine = engine
            self.eviction = eviction
            self.evictionIdleSeconds = evictionIdleSeconds
            self.dictionaryRecoveryEngines = dictionaryRecoveryEngines
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Settings.defaults.stt
            engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? d.engine
            eviction = try c.decodeIfPresent(Eviction.self, forKey: .eviction) ?? d.eviction
            evictionIdleSeconds = try c.decodeIfPresent(Int.self, forKey: .evictionIdleSeconds)
            dictionaryRecoveryEngines = try c.decodeIfPresent(
                [String].self, forKey: .dictionaryRecoveryEngines) ?? d.dictionaryRecoveryEngines
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

    public struct Shortcuts: Codable, Equatable, Sendable {
        public static let defaultAddVocabulary = "control+option+shift+v"
        public static let defaultPasteLastDictation = ""

        public var addVocabulary: String
        public var pasteLastDictation: String

        enum CodingKeys: String, CodingKey {
            case addVocabulary = "add_vocabulary"
            case legacyAddDictionaryEntry = "add_dictionary_entry"
            case addReplacement = "add_replacement"
            case pasteLastDictation = "paste_last_dictation"
        }

        public init(
            addVocabulary: String = defaultAddVocabulary,
            pasteLastDictation: String = defaultPasteLastDictation
        ) {
            self.addVocabulary = addVocabulary
            self.pasteLastDictation = pasteLastDictation
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            addVocabulary = try c.decodeIfPresent(String.self, forKey: .addVocabulary)
                ?? c.decodeIfPresent(String.self, forKey: .legacyAddDictionaryEntry)
                ?? Self.defaultAddVocabulary
            pasteLastDictation = try c.decodeIfPresent(String.self, forKey: .pasteLastDictation)
                ?? Self.defaultPasteLastDictation
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(addVocabulary, forKey: .addVocabulary)
            try c.encode(pasteLastDictation, forKey: .pasteLastDictation)
        }
    }

    // Preferred capture device. `inputDeviceUID` is a CoreAudio device UID (stable across reconnect,
    // unlike the ephemeral AudioDeviceID); nil means "follow the system default input." The capture
    // adapter resolves it live each bring-up: preferred device if present, else the system default. A
    // present preferred device is strict; fallback is for disconnected preferred devices. `inputDeviceName`
    // is the human-friendly label
    // captured when the device was last seen; it may be stale (the host refreshes it at startup whenever
    // the device is connected) and is shown only so a disconnected preferred device still reads as itself.
    public struct Audio: Codable, Equatable, Sendable {
        public var inputDeviceUID: String?
        public var inputDeviceName: String?

        enum CodingKeys: String, CodingKey {
            case inputDeviceUID = "input_device_uid"
            case inputDeviceName = "input_device_name"
        }

        public init(inputDeviceUID: String? = nil, inputDeviceName: String? = nil) {
            self.inputDeviceUID = inputDeviceUID
            self.inputDeviceName = inputDeviceName
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
            inputDeviceName = try c.decodeIfPresent(String.self, forKey: .inputDeviceName)
        }
    }

    public static let defaults = Settings(
        schemaVersion: 1,
        loadOnLogin: false,
        stt: STT(engine: "parakeet-tdt-ctc-110m", eviction: .fastest),
        duringDictation: DuringDictation(muteSystemAudio: true, keepDisplayAwake: true, sounds: true),
        history: History(enabled: true, retentionDays: 7),
        shortcuts: Shortcuts(),
        audio: Audio()
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
