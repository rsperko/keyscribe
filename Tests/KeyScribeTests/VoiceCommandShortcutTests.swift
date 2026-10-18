import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandShortcutTests {
    private struct Fixture {
        let dir: URL
        let model: ModesSettingsModel
        let config: ConfigCache
    }

    private func make(commandKey: String, polishKey: String) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcshortcut-\(UUID().uuidString)")
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        var commands = Mode.voiceCommands
        commands.triggerKeys = [.init(key: commandKey)]
        var polish = Mode(id: "polish", name: "Polish")
        polish.triggerKeys = [.init(key: polishKey)]
        try ModeStore.write(commands, to: modesDir)
        try ModeStore.write(polish, to: modesDir)
        let config = ConfigCache(supportDir: dir)
        config.voiceCommandsEnabled = true
        let model = ModesSettingsModel(repository: ConfigRepository(supportDir: dir, config: config), voiceCommandsEnabled: true)
        return Fixture(dir: dir, model: model, config: config)
    }

    private func onDisk(_ id: String, in dir: URL) -> [String] {
        ModeStore.loadAll(in: dir.appendingPathComponent("modes")).first { $0.id == id }?.triggerKeys.map(\.key) ?? []
    }

    @Test func settingsRefusesACommandShortcutAnotherModeUses() throws {
        let f = try make(commandKey: "control+option+v", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        var commands = try #require(f.model.modes.first { $0.runsVoiceCommands })
        commands.triggerKeys = [.init(key: "right_option")]
        f.model.update(commands)
        #expect(f.model.error == "Polish already uses that shortcut. Voice Commands needs one no other mode uses.")
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["control+option+v"])
    }

    @Test func settingsRefusesGivingAnotherModeTheCommandShortcut() throws {
        let f = try make(commandKey: "control+option+v", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        var polish = try #require(f.model.modes.first { $0.id == "polish" })
        polish.triggerKeys = [.init(key: "control+option+v")]
        f.model.update(polish)
        #expect(f.model.error == "Voice Commands already uses that shortcut, and it cannot share one with another mode.")
        #expect(onDisk("polish", in: f.dir) == ["right_option"])
    }

    @Test func aModeAlreadyClashingOnDiskCanStillBeEdited() throws {
        let f = try make(commandKey: "right_option", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        var polish = try #require(f.model.modes.first { $0.id == "polish" })
        polish.name = "Polished"
        f.model.update(polish)
        #expect(f.model.error == nil)
    }

    @Test func aClashOnDiskLeavesTheShortcutToTheOtherMode() throws {
        let f = try make(commandKey: "right_option", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        #expect(f.config.modes.first { $0.runsVoiceCommands }?.triggerKeys.isEmpty == true)
        #expect(f.config.modes.first { $0.id == "polish" }?.triggerKeys.map(\.key) == ["right_option"])
    }
}
