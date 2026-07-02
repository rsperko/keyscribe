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

        let adopted = try #require(AppDelegate.externallyEditedSettings(current: running, supportDir: dir))
        #expect(adopted.stt.engine == "whisper")

        var laterInAppToggle = adopted
        laterInAppToggle.history.enabled.toggle()
        try SettingsStore.write(laterInAppToggle, to: dir)

        let onDisk = try SettingsStore.loadOrCreate(supportDir: dir)
        #expect(onDisk.stt.engine == "whisper")
        #expect(onDisk.history.enabled == laterInAppToggle.history.enabled)
    }

    @Test func malformedExternalSettingsKeepsRunningSettings() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let running = Settings.defaults
        try "schema_version = nope\n".write(
            to: dir.appendingPathComponent("settings.toml"),
            atomically: true,
            encoding: .utf8)

        #expect(AppDelegate.externallyEditedSettings(current: running, supportDir: dir) == nil)
    }
}
