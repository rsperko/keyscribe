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
            schemaVersion: 1, loadOnLogin: true, defaultModeId: "email",
            stt: .init(engine: "whisper", eviction: .fastest, evictionIdleSeconds: 45),
            duringDictation: .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false),
            history: .init(enabled: false, retentionDays: 30))
        #expect(try SettingsStore.decode(from: SettingsStore.encode(s)) == s)
    }

    @Test func evictionIdleSecondsRoundTrips() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1\n[stt]\neviction_idle_seconds = 45")
        #expect(s.stt.evictionIdleSeconds == 45)
        #expect(try SettingsStore.decode(from: SettingsStore.encode(s)).stt.evictionIdleSeconds == 45)
    }

    @Test func shortcutsRoundTrip() throws {
        var s = Settings.defaults
        s.shortcuts = .init(addDictionaryEntry: "control+option+shift+d", addReplacement: "control+option+shift+r")
        let decoded = try SettingsStore.decode(from: SettingsStore.encode(s))
        #expect(decoded.shortcuts.addDictionaryEntry == "control+option+shift+d")
        #expect(decoded.shortcuts.addReplacement == "control+option+shift+r")
        #expect(decoded == s)
    }

    @Test func absentShortcutsDefaultToEmpty() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1")
        #expect(s.shortcuts.addDictionaryEntry.isEmpty)
        #expect(s.shortcuts.addReplacement.isEmpty)
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
