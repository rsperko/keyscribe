import Foundation
import Testing
@testable import KeyScribeKit

struct VoiceCommandTriggersTests {
    private func commands(_ keys: String...) -> Mode {
        var mode = Mode.voiceCommands
        mode.triggerKeys = keys.map { Mode.TriggerKey(key: $0) }
        return mode
    }

    private func mode(_ id: String, _ keys: String..., enabled: Bool = true, bundle: String? = nil) -> Mode {
        var mode = Mode(id: id, name: id.capitalized)
        mode.triggerKeys = keys.map { Mode.TriggerKey(key: $0) }
        mode.enabled = enabled
        if let bundle { mode.constraints = [.init(bundleId: bundle)] }
        return mode
    }

    @Test func aCommandShortcutSharedWithAnotherModeIsAClash() {
        let polish = mode("polish", "right_option")
        #expect(VoiceCommandTriggers.clash(for: commands("right_option"), in: [polish])?.id == "polish")
    }

    @Test func aDifferentSpellingOfTheSamePressIsAClash() {
        let hyper = mode("hyper", "hyper")
        #expect(VoiceCommandTriggers.clash(for: commands("control+option+shift+command"), in: [hyper])?.id == "hyper")
    }

    @Test func anOrdinaryModeTakingTheCommandShortcutIsAClash() {
        let voice = commands("control+option+v")
        #expect(VoiceCommandTriggers.clash(for: mode("email", "control+option+v"), in: [voice])?.id == Mode.voiceCommandsId)
    }

    @Test func scopeDoesNotExcuseAClash() {
        let scoped = mode("code", "f12", bundle: "com.microsoft.VSCode")
        #expect(VoiceCommandTriggers.clash(for: commands("f12"), in: [scoped])?.id == "code")
    }

    @Test func disabledModesAndDistinctShortcutsDoNotClash() {
        let off = mode("off", "right_option", enabled: false)
        let wider = mode("wider", "right_option+right_shift")
        #expect(VoiceCommandTriggers.clash(for: commands("right_option"), in: [off, wider]) == nil)
        var disabled = commands("right_option")
        disabled.enabled = false
        #expect(VoiceCommandTriggers.clash(for: mode("polish", "right_option"), in: [disabled]) == nil)
    }

    @Test func twoOrdinaryModesAreNotThisRulesBusiness() {
        #expect(VoiceCommandTriggers.clash(for: mode("a", "f12"), in: [mode("b", "f12")]) == nil)
    }

    @Test func guardingDropsOnlyTheClashingCommandShortcut() {
        let polish = mode("polish", "right_option")
        let guarded = VoiceCommandTriggers.guarded([commands("right_option", "control+option+v"), polish])
        #expect(guarded[0].triggerKeys.map(\.key) == ["control+option+v"])
        #expect(guarded[1] == polish)
    }

    @Test func guardingWorksWhicheverModeIsListedFirst() {
        let polish = mode("polish", "right_option")
        let guarded = VoiceCommandTriggers.guarded([polish, commands("right_option")])
        #expect(guarded[0] == polish)
        #expect(guarded[1].triggerKeys.isEmpty)
    }

    @Test func guardingLeavesAConfigWithoutClashesAlone() {
        let modes = [commands("control+option+v"), mode("polish", "right_option")]
        #expect(VoiceCommandTriggers.guarded(modes) == modes)
    }

    @Test func movingToVoiceCommandsTakesOnlyTheClashingShortcutFromEachEnabledMode() throws {
        let polish = mode("polish", "right_option", "control+option+p")
        let email = mode("email", "option+right_option")
        let other = mode("other", "f12")
        let off = mode("off", "right_option", enabled: false)
        let move = try #require(VoiceCommandTriggers.move(commands("right_option"), in: [polish, email, other, off]))
        #expect(move.destination == commands("right_option"))
        #expect(move.claimedKey == "right_option")
        #expect(move.losses.map(\.before) == [polish])
        #expect(move.losses.first?.after == mode("polish", "control+option+p"))
        #expect(move.losses.first?.removed == [Mode.TriggerKey(key: "right_option")])
        #expect(move.writes == [commands("right_option"), mode("polish", "control+option+p")])
    }

    @Test func aDifferentSpellingOrAnOverlappingSideIsTakenToo() throws {
        let hyper = mode("hyper", "control+option+shift+command")
        let sided = mode("sided", "left_command")
        let move = try #require(VoiceCommandTriggers.move(commands("hyper"), in: [hyper, sided]))
        #expect(move.losses.map(\.before.id) == ["hyper"])
        let wide = try #require(VoiceCommandTriggers.move(commands("command"), in: [hyper, sided]))
        #expect(wide.losses.map(\.before.id) == ["sided"])
        #expect(wide.losses.first?.after.triggerKeys.isEmpty == true)
    }

    @Test func movingAwayFromVoiceCommandsTakesOnlyItsShortcut() throws {
        let voice = commands("f12", "right_option")
        let shared = mode("shared", "f12")
        let move = try #require(VoiceCommandTriggers.move(mode("polish", "f12"), in: [voice, shared]))
        #expect(move.losses.map(\.before) == [voice])
        #expect(move.losses.first?.after == commands("right_option"))
    }

    @Test func onlyTheClaimedKeysMove() throws {
        let polish = mode("polish", "right_option")
        let email = mode("email", "f12")
        let destination = commands("right_option", "f12")
        let move = try #require(VoiceCommandTriggers.move(destination, claiming: [.init(key: "f12")], in: [polish, email]))
        #expect(move.losses.map(\.before.id) == ["email"])
        #expect(move.claimedKey == "f12")
        #expect(move.destination == destination)
        #expect(VoiceCommandTriggers.move(destination, claiming: [], in: [polish, email]) == nil)
    }

    @Test func nothingToMoveWithoutAClash() {
        #expect(VoiceCommandTriggers.move(commands("f12"), in: [mode("polish", "right_option")]) == nil)
        #expect(VoiceCommandTriggers.move(mode("a", "f12"), in: [mode("b", "f12")]) == nil)
        var disabled = commands("f12")
        disabled.enabled = false
        #expect(VoiceCommandTriggers.move(disabled, in: [mode("polish", "f12")]) == nil)
    }

    @Test func voiceCommandsShutOutOnlyWhenEveryShortcutIsTaken() {
        #expect(VoiceCommandTriggers.isShutOut([commands("f12"), mode("polish", "f12")]))
        #expect(!VoiceCommandTriggers.isShutOut([commands("f12", "f11"), mode("polish", "f12")]))
        #expect(!VoiceCommandTriggers.isShutOut([commands(), mode("polish", "f12")]))
        #expect(!VoiceCommandTriggers.isShutOut([commands("f11"), mode("polish", "f12")]))
    }
}
