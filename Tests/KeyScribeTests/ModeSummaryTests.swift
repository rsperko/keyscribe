import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct ModeSummaryTests {
    @Test func customChordSummaryUsesKeyboardGlyphs() {
        var mode = Mode(id: "custom", name: "Custom")
        mode.triggerKeys = [.init(key: "control+option+shift+command+m")]

        #expect(ModeSummary.whenRuns(mode) == "Triggered by ⌃⌥⇧⌘M")
    }

    @Test func namedModifierKeysUseCompactSymbols() {
        var option = Mode(id: "opt", name: "Opt")
        option.triggerKeys = [.init(key: "right_option")]
        #expect(ModeSummary.whenRuns(option) == "Triggered by Right-⌥")

        var command = Mode(id: "cmd", name: "Cmd")
        command.triggerKeys = [.init(key: "right_command")]
        #expect(ModeSummary.whenRuns(command) == "Triggered by Right-⌘")
    }

    @Test func hyperSummaryUsesItsModifierSymbols() {
        var mode = Mode(id: "hyper", name: "Hyper")
        mode.triggerKeys = [.init(key: "hyper")]
        #expect(ModeSummary.whenRuns(mode) == "Triggered by ⌃⌥⇧⌘")
    }

    @Test func appRuleWithoutAShortcutDoesNotLookAutomatic() {
        var mode = Mode(id: "slacky", name: "Slacky")
        mode.constraints = [Mode.Constraint(bundleId: "com.tinyspeck.slackmacgap")]
        #expect(ModeSummary.whenRuns(mode) == "App rule — add a shortcut to use it")
    }

    @Test func appRuleWithAShortcutSaysMatchingApps() {
        var mode = Mode(id: "slacky", name: "Slacky")
        mode.triggerKeys = [.init(key: "fn")]
        mode.constraints = [Mode.Constraint(bundleId: "com.tinyspeck.slackmacgap")]
        #expect(ModeSummary.whenRuns(mode) == "Triggered by Fn (Globe) in matching apps")
    }

    @Test func directFloorLeadsWithShortcutThenFallbackRole() {
        var floor = Mode.direct
        floor.triggerKeys = [.init(key: "fn")]
        #expect(ModeSummary.whenRuns(floor) == "Triggered by Fn (Globe) · fallback")
        var triggerless = Mode.direct
        triggerless.triggerKeys = []
        #expect(ModeSummary.whenRuns(triggerless) == "Fallback when no mode matches")
    }
}
