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

    @Test func settingsSavesTheChoiceToKeepCommandsOutOfHistory() throws {
        let f = try make(commandKey: "control+option+v", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        var commands = try #require(f.model.modes.first { $0.runsVoiceCommands })
        #expect(!commands.excludeFromHistory)
        commands.excludeFromHistory = true
        f.model.update(commands)
        let saved = ModeStore.loadAll(in: f.dir.appendingPathComponent("modes")).first { $0.runsVoiceCommands }
        #expect(saved?.excludeFromHistory == true)
    }

    private func assign(_ key: String, to id: String, in f: Fixture) throws {
        var mode = try #require(f.model.modes.first { $0.id == id })
        mode.triggerKeys = [.init(key: key)]
        f.model.update(mode)
    }

    @Test func anOccupiedCommandShortcutAsksBeforeMovingAndChangesNothingYet() throws {
        let f = try make(commandKey: "control+option+v", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try assign("right_option", to: Mode.voiceCommandsId, in: f)
        let move = try #require(f.model.pendingMove)
        #expect(move.losses.map(\.before.id) == ["polish"])
        #expect(f.model.notice == nil)
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["control+option+v"])
        #expect(onDisk("polish", in: f.dir) == ["right_option"])
        f.model.cancelMove()
        #expect(f.model.pendingMove == nil)
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["control+option+v"])
        #expect(f.model.modes.first { $0.runsVoiceCommands }?.triggerKeys.map(\.key) == ["control+option+v"])
    }

    @Test func movingTheShortcutUpdatesEveryAffectedModeAndUndoRestoresThem() throws {
        let f = try make(commandKey: "control+option+v", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try assign("right_option", to: Mode.voiceCommandsId, in: f)
        f.model.confirmMove()
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["right_option"])
        #expect(onDisk("polish", in: f.dir).isEmpty)
        #expect(f.model.modes.first { $0.id == "polish" }?.triggerKeys.isEmpty == true)
        #expect(f.config.modes.first { $0.runsVoiceCommands }?.triggerKeys.map(\.key) == ["right_option"])
        #expect(f.model.undoableMove != nil)
        f.model.undoMove()
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["control+option+v"])
        #expect(onDisk("polish", in: f.dir) == ["right_option"])
        #expect(f.model.undoableMove == nil)
    }

    @Test func givingAnotherModeTheCommandShortcutMovesItAwayFromVoiceCommands() throws {
        let f = try make(commandKey: "control+option+v", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try assign("control+option+v", to: "polish", in: f)
        #expect(f.model.pendingMove?.losses.map(\.before.id) == [Mode.voiceCommandsId])
        f.model.confirmMove()
        #expect(onDisk("polish", in: f.dir) == ["control+option+v"])
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir).isEmpty)
    }

    @Test func undoGoesAwayOnceAnAffectedModeIsEdited() throws {
        let f = try make(commandKey: "control+option+v", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try assign("right_option", to: Mode.voiceCommandsId, in: f)
        f.model.confirmMove()
        var polish = try #require(f.model.modes.first { $0.id == "polish" })
        polish.name = "Polished"
        f.model.update(polish)
        #expect(f.model.undoableMove == nil)
        f.model.undoMove()
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["right_option"])
    }

    @Test func undoRefusesToRestoreAShortcutAnotherModeTookSince() throws {
        let f = try make(commandKey: "f12", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        var email = Mode(id: "email", name: "Email")
        email.triggerKeys = [.init(key: "f11")]
        try ModeStore.write(email, to: f.dir.appendingPathComponent("modes"))
        f.model.reload(force: true)
        try assign("right_option", to: Mode.voiceCommandsId, in: f)
        f.model.confirmMove()
        try assign("f12", to: "email", in: f)
        #expect(f.model.undoableMove != nil)
        f.model.undoMove()
        #expect(f.model.notice == PaneNotice(title: "Undo didn’t change anything", message: "Those shortcuts changed since the move."))
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["right_option"])
        #expect(onDisk("email", in: f.dir) == ["f12"])
    }

    @Test func undoNoticesAnEditMadeOutsideSettings() throws {
        let f = try make(commandKey: "control+option+v", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try assign("right_option", to: Mode.voiceCommandsId, in: f)
        f.model.confirmMove()
        var polish = Mode(id: "polish", name: "Polish")
        polish.triggerKeys = [.init(key: "f9")]
        try ModeStore.write(polish, to: f.dir.appendingPathComponent("modes"))
        f.model.undoMove()
        #expect(onDisk("polish", in: f.dir) == ["f9"])
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["right_option"])
    }

    @Test func changingAnAlreadyClashingShortcutToAnotherTakenOneStillAsks() throws {
        let f = try make(commandKey: "right_option", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        var email = Mode(id: "email", name: "Email")
        email.triggerKeys = [.init(key: "f12")]
        try ModeStore.write(email, to: f.dir.appendingPathComponent("modes"))
        f.model.reload(force: true)
        try assign("f12", to: Mode.voiceCommandsId, in: f)
        #expect(f.model.pendingMove?.losses.map(\.before.id) == ["email"])
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["right_option"])
    }

    @Test func aModeThatTookTheShortcutMeanwhileStopsTheMove() throws {
        let f = try make(commandKey: "control+option+v", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try assign("right_option", to: Mode.voiceCommandsId, in: f)
        var email = Mode(id: "email", name: "Email")
        email.triggerKeys = [.init(key: "right_option")]
        try ModeStore.write(email, to: f.dir.appendingPathComponent("modes"))
        f.model.confirmMove()
        #expect(f.model.notice == PaneNotice(title: "Shortcut wasn’t moved", message: "The modes using that shortcut changed. Try again."))
        #expect(onDisk(Mode.voiceCommandsId, in: f.dir) == ["control+option+v"])
        #expect(onDisk("polish", in: f.dir) == ["right_option"])
        #expect(f.model.undoableMove == nil)
    }

    @Test func enablingAModeThatClashesIsStillRefused() throws {
        let f = try make(commandKey: "right_option", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        var polish = try #require(f.model.modes.first { $0.id == "polish" })
        polish.enabled = false
        f.model.update(polish)
        polish.enabled = true
        f.model.update(polish)
        #expect(f.model.pendingMove == nil)
        #expect(f.model.notice == PaneNotice(
            title: "Changes to Polish weren’t saved",
            message: "Voice Commands already uses that shortcut, and it cannot share one with another mode."))
    }

    @Test func aClashWrittenOnDiskCanBeMovedToVoiceCommandsFromSettings() throws {
        let f = try make(commandKey: "right_option", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        #expect(f.config.voiceCommandsShutOut)
        let commands = try #require(f.model.modes.first { $0.runsVoiceCommands })
        f.model.proposeMove(to: commands)
        f.model.confirmMove()
        #expect(onDisk("polish", in: f.dir).isEmpty)
        #expect(!f.config.voiceCommandsShutOut)
    }

    @Test func undoingARepairOfAHandEditedClashRestoresTheClash() throws {
        let f = try make(commandKey: "right_option", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let commands = try #require(f.model.modes.first { $0.runsVoiceCommands })
        f.model.proposeMove(to: commands)
        f.model.confirmMove()
        f.model.undoMove()
        #expect(f.model.notice == nil)
        #expect(onDisk("polish", in: f.dir) == ["right_option"])
        #expect(f.config.voiceCommandsShutOut)
    }

    @Test func aModeAlreadyClashingOnDiskCanStillBeEdited() throws {
        let f = try make(commandKey: "right_option", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        var polish = try #require(f.model.modes.first { $0.id == "polish" })
        polish.name = "Polished"
        f.model.update(polish)
        #expect(f.model.notice == nil)
    }

    @Test func aClashOnDiskLeavesTheShortcutToTheOtherMode() throws {
        let f = try make(commandKey: "right_option", polishKey: "right_option")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        #expect(f.config.modes.first { $0.runsVoiceCommands }?.triggerKeys.isEmpty == true)
        #expect(f.config.modes.first { $0.id == "polish" }?.triggerKeys.map(\.key) == ["right_option"])
    }
}
