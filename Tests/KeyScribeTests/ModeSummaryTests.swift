import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct ModeSummaryTests {
    @Test func customChordSummaryUsesKeyboardGlyphs() {
        var mode = Mode(id: "custom", name: "Custom")
        mode.triggerKeys = [.init(key: "control+option+shift+command+m")]

        #expect(ModeSummary.whenRuns(mode) == "Triggered by ⌃⌥⇧⌘M")
    }

    @Test func namedModifierKeysRemainPlainLanguage() throws {
        #expect(ModeSummary.triggerLabel(try KeyDescriptor(parsing: "right_option")) == "Right Option")
        #expect(ModeSummary.triggerLabel(try KeyDescriptor(parsing: "right_command")) == "Right Command")
    }

    @Test func hyperSummaryUsesItsModifierSymbols() throws {
        #expect(ModeSummary.triggerLabel(try KeyDescriptor(parsing: "hyper")) == "⌃⌥⇧⌘")
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
