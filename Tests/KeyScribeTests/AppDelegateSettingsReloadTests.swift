import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct AppDelegateSettingsReloadTests {
    @Test func externalSettingsEditIsAdoptedBeforeLaterWrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var running = Settings.defaults
        running.stt.engine = "parakeet"
        try SettingsStore.write(running, to: dir)

        var external = running
        external.stt.engine = "whisper"
        try SettingsStore.write(external, to: dir)

        guard case let .updated(adopted) = AppDelegate.settingsFileState(current: running, supportDir: dir) else {
            Issue.record("expected .updated")
            return
        }
        #expect(adopted.stt.engine == "whisper")

        var laterInAppToggle = adopted
        laterInAppToggle.history.enabled.toggle()
        try SettingsStore.write(laterInAppToggle, to: dir)

        let onDisk = try SettingsStore.loadOrCreate(supportDir: dir)
        #expect(onDisk.stt.engine == "whisper")
        #expect(onDisk.history.enabled == laterInAppToggle.history.enabled)
    }

    @Test func unchangedExternalSettingsReportUnchanged() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let running = Settings.defaults
        try SettingsStore.write(running, to: dir)

        #expect(AppDelegate.settingsFileState(current: running, supportDir: dir) == .unchanged)
    }

    @Test func malformedExternalSettingsReportInvalidRatherThanSilentlyIgnored() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let running = Settings.defaults
        try "schema_version = nope\n".write(
            to: dir.appendingPathComponent("settings.toml"),
            atomically: true,
            encoding: .utf8)

        guard case .invalid = AppDelegate.settingsFileState(current: running, supportDir: dir) else {
            Issue.record("expected .invalid")
            return
        }
    }

    @Test func newerSchemaVersionReportsInvalid() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "schema_version = 2\n".write(
            to: dir.appendingPathComponent("settings.toml"),
            atomically: true,
            encoding: .utf8)

        guard case .invalid = AppDelegate.settingsFileState(current: Settings.defaults, supportDir: dir) else {
            Issue.record("expected .invalid")
            return
        }
    }
}

struct AppDelegateHotkeyConflictTests {
    @Test func vocabularyShortcutShadowedIsAConflict() {
        #expect(AppDelegate.hotkeyConflictDetected(shadowed: [GlobalHotkey.vocabularyId]))
    }

    @Test func pasteLastShortcutShadowedIsAConflict() {
        #expect(AppDelegate.hotkeyConflictDetected(shadowed: [GlobalHotkey.pasteLastId]))
    }

    @Test func noShadowedGlobalsIsNotAConflict() {
        #expect(!AppDelegate.hotkeyConflictDetected(shadowed: ["some-mode#control+option+shift+z"]))
    }
}
