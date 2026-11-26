import Foundation
import Testing
@testable import KeyScribeApp
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

    @Test func aReloadKeepsAChangeThatWasNotSavedUntilTheFileItselfChangesAndThenSaysSo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = Settings.defaults
        try SettingsStore.write(saved, to: dir)
        var running = saved
        running.history.enabled.toggle()

        let quiet = AppDelegate.settingsFileState(running: running, saved: saved, supportDir: dir)
        #expect(quiet.state == .unchanged)
        #expect(!quiet.replacesUnsaved)
        #expect(quiet.retriesSave)

        var external = saved
        external.stt.engine = "whisper"
        try SettingsStore.write(external, to: dir)

        let edited = AppDelegate.settingsFileState(running: running, saved: saved, supportDir: dir)
        #expect(edited.state == .updated(external))
        #expect(edited.replacesUnsaved)
        #expect(!edited.retriesSave)
        try SettingsStore.write(saved, to: dir)
        let clean = AppDelegate.settingsFileState(running: saved, saved: saved, supportDir: dir)
        #expect(!clean.replacesUnsaved)
        #expect(!clean.retriesSave)
    }

    @Test func aMicrophoneNameTheAppRefreshedIsNotCountedAsAChangeTheUserMade() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = Settings.defaults
        var running = saved
        running.audio.inputDeviceName = "Studio Mic (renamed)"
        var external = saved
        external.stt.engine = "whisper"
        try SettingsStore.write(external, to: dir)

        let reload = AppDelegate.settingsFileState(running: running, saved: saved, supportDir: dir)
        #expect(reload.state == .updated(external))
        #expect(!reload.replacesUnsaved)
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

    private func settingsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aSettingsSaveSaysWhetherItLandedWasHeldBackOrFailed() throws {
        let dir = try settingsDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try SettingsStore.write(Settings.defaults, to: dir)
        var changed = Settings.defaults
        changed.history.retentionDays = 30

        let unreadable = ConfigFileIssue.unreadable(SettingsStore.fileName, error: .missingSchemaVersion, recovery: .previousVersion)
        #expect(AppDelegate.saveSettings(changed, issue: unreadable, supportDir: dir) == .held)
        #expect(try SettingsStore.loadOrCreate(supportDir: dir) == Settings.defaults)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        guard case .failed(let issue) = AppDelegate.saveSettings(changed, issue: nil, supportDir: dir) else {
            Issue.record("expected .failed")
            return
        }
        #expect(issue.title == "Couldn’t save settings.toml")
        #expect(issue.isError)
        #expect(!issue.detail.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(AppDelegate.saveSettings(changed, issue: issue, supportDir: dir) == .saved)
        #expect(try SettingsStore.loadOrCreate(supportDir: dir) == changed)

        let file = dir.appendingPathComponent(SettingsStore.fileName)
        let withTypo = try String(contentsOf: file, encoding: .utf8) + "retention_dayz = 3\n"
        try withTypo.write(to: file, atomically: true, encoding: .utf8)
        #expect(AppDelegate.saveSettings(Settings.defaults, issue: nil, supportDir: dir) == .held)
        #expect(try String(contentsOf: file, encoding: .utf8) == withTypo)
    }

    @Test func historyIsDeletedOnlyUnderARetentionTheSettingsFileHolds() {
        var saved = Settings.defaults
        saved.history.retentionDays = 30
        let previous = ConfigFileIssue.unreadable(SettingsStore.fileName, error: .missingSchemaVersion, recovery: .previousVersion)
        let defaults = ConfigFileIssue.unreadable(SettingsStore.fileName, error: .missingSchemaVersion, recovery: .defaults)
        let notSaved = ConfigFileIssue.notSaved(SettingsStore.fileName, detail: "disk full")

        #expect(AppDelegate.deletableHistoryDays(chosen: 30, saved: saved, issue: nil) == 30)
        #expect(AppDelegate.deletableHistoryDays(chosen: 3, saved: saved, issue: nil) == 30)
        #expect(AppDelegate.deletableHistoryDays(chosen: 90, saved: saved, issue: nil) == 90)
        #expect(AppDelegate.deletableHistoryDays(chosen: 3, saved: saved, issue: notSaved) == 30)
        #expect(AppDelegate.deletableHistoryDays(chosen: 3, saved: saved, issue: previous) == 30)
        #expect(AppDelegate.deletableHistoryDays(chosen: 7, saved: saved, issue: defaults) == nil)
    }

    @Test func theHistoryIsSweptAgainWheneverWhatItMayDeleteOrTheChosenPeriodChanges() {
        func saved(_ days: Int) -> Settings { var s = Settings.defaults; s.history.retentionDays = days; return s }
        let defaults = ConfigFileIssue.unreadable(SettingsStore.fileName, error: .missingSchemaVersion, recovery: .defaults)
        let previous = ConfigFileIssue.unreadable(SettingsStore.fileName, error: .missingSchemaVersion, recovery: .previousVersion)
        let notSaved = ConfigFileIssue.notSaved(SettingsStore.fileName, detail: "disk full")
        typealias Cell = (name: String, before: (Int, Settings, ConfigFileIssue?), after: (Int, Settings, ConfigFileIssue?), sweeps: Bool)
        let grid: [Cell] = [
            ("a shorter period not saved", (90, saved(90), nil), (7, saved(90), notSaved), true),
            ("a pending period saved by an unrelated change", (7, saved(90), notSaved), (7, saved(7), nil), true),
            ("a pending period saved by a reload retry", (7, saved(90), nil), (7, saved(7), nil), true),
            ("defaults recovered to the same period", (7, Settings.defaults, defaults), (7, saved(7), nil), true),
            ("the file goes bad while running", (7, saved(7), nil), (7, saved(7), previous), false),
            ("an unrelated change", (7, saved(7), nil), (7, saved(7), nil), false),
            ("a failed save of an unrelated change", (7, saved(7), nil), (7, saved(7), notSaved), false),
        ]
        for cell in grid {
            let before = AppDelegate.historyRetention(chosen: cell.before.0, saved: cell.before.1, issue: cell.before.2)
            let after = AppDelegate.historyRetention(chosen: cell.after.0, saved: cell.after.1, issue: cell.after.2)
            #expect((before != after) == cell.sweeps, "\(cell.name)")
        }
    }
}
