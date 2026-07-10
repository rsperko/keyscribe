import Foundation
import Testing
@testable import KeyScribeKit

struct SettingsTests {
    let full = """
    schema_version = 1
    load_on_login = true
    default_mode_id = "plain-dictation"

    [stt]
    engine = "parakeet"
    eviction = "balanced"

    [during_dictation]
    mute_system_audio = true
    keep_display_awake = true
    sounds = true

    [history]
    enabled = true
    retention_days = 7
    """

    @Test func decodesFullSettings() throws {
        let s = try SettingsStore.decode(from: full)
        #expect(s.schemaVersion == 1)
        #expect(s.stt.engine == "parakeet")
        #expect(s.stt.eviction == .balanced)
        #expect(s.history.retentionDays == 7)
    }

    @Test func missingSchemaVersionThrows() {
        #expect(throws: ConfigError.missingSchemaVersion) {
            try SettingsStore.decode(from: "load_on_login = true")
        }
    }

    @Test func newerSchemaVersionIsRefusedNotDowngraded() {
        #expect(throws: ConfigError.newerSchemaVersion(found: 2, supported: 1)) {
            try SettingsStore.decode(from: "schema_version = 2")
        }
    }

    @Test func absentFieldsFallBackToDefaults() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1")
        #expect(s == Settings.defaults)
    }

    @Test func invalidEvictionIsRejected() {
        let toml = "schema_version = 1\n[stt]\neviction = \"turbo\"\n"
        #expect(throws: ConfigError.self) { try SettingsStore.decode(from: toml) }
    }

    @Test func defaultsRoundTrip() throws {
        let encoded = try SettingsStore.encode(Settings.defaults)
        #expect(try SettingsStore.decode(from: encoded) == Settings.defaults)
    }

    // Every field differs from defaults — catches a snake_case encode-key regression the
    // defaults-only round-trip would miss.
    @Test func nonDefaultSettingsRoundTrip() throws {
        let s = Settings(
            schemaVersion: 1, loadOnLogin: true,
            stt: .init(engine: "whisper", eviction: .fastest, evictionIdleSeconds: 45),
            duringDictation: .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false),
            history: .init(enabled: false, retentionDays: 30),
            audio: .init(inputDeviceUID: "BuiltInMicrophoneDevice", inputDeviceName: "Built-in Microphone"))
        #expect(try SettingsStore.decode(from: SettingsStore.encode(s)) == s)
    }

    @Test func evictionIdleSecondsRoundTrips() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1\n[stt]\neviction_idle_seconds = 45")
        #expect(s.stt.evictionIdleSeconds == 45)
        #expect(try SettingsStore.decode(from: SettingsStore.encode(s)).stt.evictionIdleSeconds == 45)
    }

    @Test func recognitionBiasDefaultsOnForCapableModelsOffForOthers() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1")
        let capable = try #require(SpeechModelCatalog.entry(for: "qwen3-asr-1.7b"))
        let incapable = try #require(SpeechModelCatalog.entry(for: "parakeet"))
        #expect(s.stt.recognitionBiasEnabled(for: capable))
        #expect(!s.stt.recognitionBiasEnabled(for: incapable))
    }

    @Test func recognitionBiasDisableRoundTrips() throws {
        var s = Settings.defaults
        let capable = try #require(SpeechModelCatalog.entry(for: "qwen3-asr-1.7b"))
        s.stt.setRecognitionBias(false, for: capable)
        #expect(!s.stt.recognitionBiasEnabled(for: capable))

        let decoded = try SettingsStore.decode(from: SettingsStore.encode(s))
        #expect(!decoded.stt.recognitionBiasEnabled(for: capable))
    }

    // Rev2: the per-engine dictionary-recovery keys were removed (recovery now runs unconditionally in the
    // pipeline). A settings file written by an older build still carries them; it must decode cleanly, drop
    // them on re-encode, and leave the recognition-bias disable list untouched.
    @Test func legacyRecoveryKeysAreIgnoredAndDroppedWhileBiasSurvives() throws {
        let toml = """
        schema_version = 1
        [stt]
        recognition_bias_disabled_engines = ["qwen3-asr-1.7b"]
        dictionary_recovery_enabled_engines = ["parakeet"]
        dictionary_recovery_disabled_engines = ["whisper"]
        dictionary_recovery_engines = ["parakeet"]
        """
        let s = try SettingsStore.decode(from: toml)
        let capable = try #require(SpeechModelCatalog.entry(for: "qwen3-asr-1.7b"))
        #expect(!s.stt.recognitionBiasEnabled(for: capable))

        let reencoded = try SettingsStore.encode(s)
        #expect(!reencoded.contains("dictionary_recovery"))
        #expect(reencoded.contains("recognition_bias_disabled_engines"))

        let round = try SettingsStore.decode(from: reencoded)
        #expect(!round.stt.recognitionBiasEnabled(for: capable))
    }

    @Test func shortcutsRoundTrip() throws {
        var s = Settings.defaults
        s.shortcuts = .init(
            addVocabulary: "control+option+shift+d",
            pasteLastDictation: "control+option+shift+v")
        let decoded = try SettingsStore.decode(from: SettingsStore.encode(s))
        #expect(decoded.shortcuts.addVocabulary == "control+option+shift+d")
        #expect(decoded.shortcuts.pasteLastDictation == "control+option+shift+v")
        #expect(decoded == s)
    }

    @Test func absentShortcutsFallBackToDefaults() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1")
        #expect(s.shortcuts.addVocabulary == "control+option+shift+v")
        #expect(s.shortcuts.pasteLastDictation.isEmpty)
    }

    @Test func explicitlyEmptyShortcutStaysOff() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1\n[shortcuts]\nadd_vocabulary = \"\"")
        #expect(s.shortcuts.addVocabulary.isEmpty)
    }

    @Test func legacyDictionaryShortcutMigratesToAddVocabulary() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1\n[shortcuts]\nadd_dictionary_entry = \"control+option+shift+f\"")
        #expect(s.shortcuts.addVocabulary == "control+option+shift+f")
    }

    @Test func explicitLegacyDictionaryShortcutEmptyStaysOff() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1\n[shortcuts]\nadd_dictionary_entry = \"\"")
        #expect(s.shortcuts.addVocabulary.isEmpty)
    }

    @Test func addVocabularyWinsOverLegacyDictionaryShortcut() throws {
        let toml = """
        schema_version = 1
        [shortcuts]
        add_vocabulary = "control+option+shift+v"
        add_dictionary_entry = "control+option+shift+d"
        """
        let s = try SettingsStore.decode(from: toml)
        #expect(s.shortcuts.addVocabulary == "control+option+shift+v")
    }

    @Test func legacyReplacementShortcutIsIgnored() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1\n[shortcuts]\nadd_replacement = \"control+option+shift+r\"")
        #expect(s.shortcuts.addVocabulary == "control+option+shift+v")
    }

    @Test func encodedShortcutsUseAddVocabularyKey() throws {
        var s = Settings.defaults
        s.shortcuts = .init(addVocabulary: "control+option+shift+v")
        let encoded = try SettingsStore.encode(s)
        #expect(encoded.contains("add_vocabulary"))
        #expect(!encoded.contains("add_dictionary_entry"))
        #expect(!encoded.contains("add_replacement"))
    }

    @Test func audioInputDeviceRoundTrips() throws {
        var s = Settings.defaults
        s.audio = .init(inputDeviceUID: "AppleUSBAudioEngine:Shure:MV7:1", inputDeviceName: "Shure MV7")
        let decoded = try SettingsStore.decode(from: SettingsStore.encode(s))
        #expect(decoded.audio.inputDeviceUID == "AppleUSBAudioEngine:Shure:MV7:1")
        #expect(decoded.audio.inputDeviceName == "Shure MV7")
        #expect(decoded == s)
    }

    @Test func absentAudioFallsBackToSystemDefault() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1")
        #expect(s.audio.inputDeviceUID == nil)
        #expect(s.audio.inputDeviceName == nil)
    }

    @Test func explicitAudioSectionDecodes() throws {
        let s = try SettingsStore.decode(
            from: "schema_version = 1\n[audio]\ninput_device_uid = \"BuiltInMic\"\ninput_device_name = \"MacBook Pro Microphone\"")
        #expect(s.audio.inputDeviceUID == "BuiltInMic")
        #expect(s.audio.inputDeviceName == "MacBook Pro Microphone")
    }

    // A name may be absent even when the UID is set (an older config, or a device that was disconnected
    // when first saved) — the picker just falls back to a generic label until the next startup refresh.
    @Test func audioUIDWithoutNameDecodes() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1\n[audio]\ninput_device_uid = \"BuiltInMic\"")
        #expect(s.audio.inputDeviceUID == "BuiltInMic")
        #expect(s.audio.inputDeviceName == nil)
    }

    @Test func negativeRetentionIsRejected() {
        #expect(throws: ConfigError.self) {
            try SettingsStore.decode(from: "schema_version = 1\n[history]\nretention_days = -1")
        }
    }

    @Test func loadOrCreateWritesDefaultsWhenAbsent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try SettingsStore.loadOrCreate(supportDir: dir)
        #expect(s == Settings.defaults)
        let file = dir.appendingPathComponent("settings.toml")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let reloaded = try SettingsStore.loadOrCreate(supportDir: dir)
        #expect(reloaded == Settings.defaults)
    }
}
