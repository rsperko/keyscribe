import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct ModeSummaryTests {
    @Test func customChordSummaryUsesCompactKeyboardGlyphs() {
        var mode = Mode(id: "custom", name: "Custom")
        mode.triggerKeys = [.init(key: "control+option+shift+command+m")]

        #expect(ModeSummary.whenRuns(mode) == "⌃⌥⇧⌘M")
    }

    @Test func namedModifierKeysUseCompactSymbols() {
        var option = Mode(id: "opt", name: "Opt")
        option.triggerKeys = [.init(key: "right_option")]
        #expect(ModeSummary.whenRuns(option) == "Right-⌥")

        var command = Mode(id: "cmd", name: "Cmd")
        command.triggerKeys = [.init(key: "right_command")]
        #expect(ModeSummary.whenRuns(command) == "Right-⌘")
    }

    @Test func hyperSummaryUsesItsModifierSymbols() {
        var mode = Mode(id: "hyper", name: "Hyper")
        mode.triggerKeys = [.init(key: "hyper")]
        #expect(ModeSummary.whenRuns(mode) == "⌃⌥⇧⌘")
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
        #expect(ModeSummary.whenRuns(mode) == "Fn (Globe) in matching apps")
    }

    @Test func spokenPhraseModeShowsTheActualQuotedPhrase() {
        var mode = Mode(id: "email", name: "Email")
        mode.triggerPhrases = ["as an email"]
        #expect(ModeSummary.whenRuns(mode) == "Say \"as an email\"")
    }

    @Test func spokenPhraseInMatchingAppsKeepsTheQuotedPhrase() {
        var mode = Mode(id: "email", name: "Email")
        mode.triggerPhrases = ["as an email"]
        mode.constraints = [Mode.Constraint(bundleId: "com.tinyspeck.slackmacgap")]
        #expect(ModeSummary.whenRuns(mode) == "Say \"as an email\" in matching apps")
    }

    @Test func spokenPhraseFormatterMatchesAcrossCasings() {
        #expect(ModeSummary.spokenPhrase("as an email", capitalized: true) == "Say \"as an email\"")
        #expect(ModeSummary.spokenPhrase("as an email", capitalized: false) == "say \"as an email\"")
    }

    @Test func directFloorUsesItsShortcutWithoutFallbackMetadata() {
        var floor = Mode.direct
        floor.triggerKeys = [.init(key: "fn")]
        #expect(ModeSummary.whenRuns(floor) == "Fn (Globe)")
        var triggerless = Mode.direct
        triggerless.triggerKeys = []
        #expect(ModeSummary.whenRuns(triggerless) == "Fallback")
    }
}
