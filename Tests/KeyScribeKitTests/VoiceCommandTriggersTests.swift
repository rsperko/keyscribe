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
}
