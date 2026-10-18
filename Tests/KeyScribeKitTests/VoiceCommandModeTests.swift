import Foundation
import Testing
@testable import KeyScribeKit

struct VoiceCommandModeTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcmode-\(UUID().uuidString)")
    }

    @Test func voiceCommandsIsASystemModeThatNeverInserts() {
        let mode = Mode.voiceCommands
        #expect(mode.id == Mode.voiceCommandsId)
        #expect(mode.isSystem)
        #expect(!mode.isDirect)
        #expect(Mode.direct.isDirect)
        #expect(mode.output == .voiceCommand)
        #expect(mode.triggerKeys.isEmpty)
        #expect(mode.aiRewrite == nil)
        #expect(mode.excludeFromHistory)
        #expect(mode.constraints.isEmpty)
        #expect(mode.triggerPhrases.isEmpty)
        #expect(!mode.commands.liveEdits)
        #expect(!mode.dictionary.includeGlobal)
        #expect(!mode.replacements.includeGlobal)
    }

    @Test func outputRoundTripsThroughTOML() throws {
        let decoded = try ModeStore.decode(from: ModeStore.encode(.voiceCommands), id: Mode.voiceCommandsId)
        #expect(decoded.output == .voiceCommand)
    }

    @Test func onlyTheBuiltInModeMayRunCommands() throws {
        var custom = Mode(id: "my-commands", name: "My Commands")
        custom.output = .voiceCommand
        let toml = try ModeStore.encode(custom)
        #expect(throws: ConfigError.self) { try ModeStore.decode(from: toml, id: "my-commands") }
        #expect(try ModeStore.decode(from: toml, id: Mode.voiceCommandsId).output == .voiceCommand)
    }

    @Test func normalizationKeepsOnlyTheShortcutAndEnabled() {
        var tampered = Mode.voiceCommands
        tampered.triggerKeys = [.init(key: "right_option", pressStyle: "tap-to-toggle")]
        tampered.enabled = false
        tampered.name = "Renamed"
        tampered.output = .cursor
        tampered.aiRewrite = Mode.AIRewrite(connection: "x", prompt: "leak")
        tampered.excludeFromHistory = false
        tampered.triggerPhrases = ["as a command"]
        tampered.constraints = [Mode.Constraint(bundleId: "com.example")]
        tampered.commands.liveEdits = true

        let normalized = tampered.systemNormalized()
        var expected = Mode.voiceCommands
        expected.triggerKeys = [.init(key: "right_option", pressStyle: "tap-to-toggle")]
        expected.enabled = false
        #expect(normalized == expected)
    }

    @Test func seedingIsOptInAndIdempotent() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        ModeStore.ensureSystemModes(in: dir)
        #expect(!ModeStore.loadAll(in: dir).contains { $0.id == Mode.voiceCommandsId })

        ModeStore.ensureSystemModes(in: dir, voiceCommands: true)
        ModeStore.ensureSystemModes(in: dir, voiceCommands: true)
        let seeded = ModeStore.loadAll(in: dir).filter { $0.id == Mode.voiceCommandsId }
        #expect(seeded == [Mode.voiceCommands])
    }

    @Test func turningTheFlagOffLeavesTheFileAndItsShortcut() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var mode = Mode.voiceCommands
        mode.triggerKeys = [.init(key: "right_command")]
        try ModeStore.write(mode, to: dir)

        ModeStore.ensureSystemModes(in: dir, voiceCommands: false)
        let kept = try #require(ModeStore.loadAll(in: dir).first { $0.id == Mode.voiceCommandsId })
        #expect(kept.triggerKeys == [.init(key: "right_command")])
    }

    @Test func seedingHealsATamperedFileOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var tampered = Mode.voiceCommands
        tampered.triggerKeys = [.init(key: "right_command")]
        tampered.aiRewrite = Mode.AIRewrite(connection: "x", prompt: "leak")
        try ModeStore.write(tampered, to: dir)

        ModeStore.ensureSystemModes(in: dir, voiceCommands: true)
        let toml = try String(contentsOf: dir.appendingPathComponent("\(Mode.voiceCommandsId).toml"), encoding: .utf8)
        let healed = try ModeStore.decode(from: toml, id: Mode.voiceCommandsId)
        #expect(healed.aiRewrite == nil)
        #expect(healed.triggerKeys == [.init(key: "right_command")])
    }

    @Test func seedingDoesNotTakeAShortcutFromDirect() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        ModeStore.ensureSystemModes(in: dir, voiceCommands: true)
        let modes = ModeStore.loadAll(in: dir)
        #expect(modes.first { $0.id == Mode.directId }?.triggerKeys == [.init(key: "fn")])
        #expect(modes.first { $0.id == Mode.voiceCommandsId }?.triggerKeys.isEmpty == true)
    }

    @Test func hiddenWhenTheFlagIsOff() {
        let modes = [Mode.direct, Mode.voiceCommands, Mode(id: "m", name: "M")]
        #expect(Mode.visible(modes, voiceCommands: false).map(\.id) == [Mode.directId, "m"])
        #expect(Mode.visible(modes, voiceCommands: true).map(\.id) == [Mode.directId, Mode.voiceCommandsId, "m"])
    }

    @Test func deleteRefusesBothSystemModes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        ModeStore.ensureSystemModes(in: dir, voiceCommands: true)
        try ModeStore.delete(.voiceCommands, from: dir)
        #expect(ModeStore.loadAll(in: dir).contains { $0.id == Mode.voiceCommandsId })
    }

    @Test func neverTheFallback() {
        var commands = Mode.voiceCommands
        commands.triggerKeys = [.init(key: "right_option")]
        let modes = [Mode.direct, commands]
        let unbound = ModeResolver.resolvePhaseAWithReason(
            modes: modes, directFallback: .direct, context: .init(bundleId: "com.apple.TextEdit"), triggerKey: nil)
        #expect(unbound?.mode.id == Mode.directId)
        let bound = ModeResolver.resolvePhaseAWithReason(
            modes: modes, directFallback: .direct, context: .init(bundleId: "com.apple.TextEdit"), triggerKey: "right_option")
        #expect(bound?.mode.id == Mode.voiceCommandsId)
        #expect(bound?.reason == .triggerKey)
    }

    @Test func aSpokenSuffixNeverRoutesIntoVoiceCommands() {
        let routed = ModeResolver.resolvePhaseB(eligibleModes: [.voiceCommands], transcript: "switch to chrome")
        #expect(routed.routedModeId == nil)
    }

    @Test func itsShortcutConflictsLikeAnyMode() {
        var commands = Mode.voiceCommands
        commands.triggerKeys = [.init(key: "right_option")]
        var other = Mode(id: "other", name: "Other")
        other.triggerKeys = [.init(key: "right_option")]
        #expect(TriggerKeyConflicts.conflict(for: other, in: [commands, other]) != nil)
    }
}
