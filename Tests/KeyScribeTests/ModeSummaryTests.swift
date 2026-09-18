import Testing
@testable import KeyScribeApp
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

    @Test func everyShortcutIsListedJoinedWithOr() {
        var mode = Mode(id: "multi", name: "Multi")
        mode.triggerKeys = [.init(key: "fn"), .init(key: "mouse4", pressStyle: "hold-only")]
        #expect(ModeSummary.triggerDisplay(mode) == "Fn (Globe) or Mouse Button 4")
        #expect(ModeSummary.whenRuns(mode) == "Fn (Globe) or Mouse Button 4")
    }

    @Test func everyShortcutIsListedInMatchingApps() {
        var mode = Mode(id: "multi", name: "Multi")
        mode.triggerKeys = [.init(key: "fn"), .init(key: "mouse4")]
        mode.constraints = [Mode.Constraint(bundleId: "com.tinyspeck.slackmacgap")]
        #expect(ModeSummary.whenRuns(mode) == "Fn (Globe) or Mouse Button 4 in matching apps")
    }

    @Test func systemModeListsEveryShortcut() {
        var floor = Mode.direct
        floor.triggerKeys = [.init(key: "fn"), .init(key: "mouse5")]
        #expect(ModeSummary.whenRuns(floor) == "Fn (Globe) or Mouse Button 5")
    }

    @Test func aShortcutThatIsTheSamePressAsAnEarlierOneIsNotListed() {
        var mode = Mode(id: "multi", name: "Multi")
        mode.triggerKeys = [.init(key: "right_command"), .init(key: "command")]
        #expect(ModeSummary.triggerDisplay(mode) == "Right-⌘")
    }

    @Test func twoSpellingsOfOneShortcutAreListedOnce() {
        var mode = Mode(id: "multi", name: "Multi")
        mode.triggerKeys = [.init(key: "hyper"), .init(key: "control+option+shift+command")]
        #expect(ModeSummary.triggerDisplay(mode) == "⌃⌥⇧⌘")
    }

    @Test func unparsableShortcutsAreSkippedInTheDisplay() {
        var mode = Mode(id: "multi", name: "Multi")
        mode.triggerKeys = [.init(key: "not a key"), .init(key: "fn")]
        #expect(ModeSummary.triggerDisplay(mode) == "Fn (Globe)")
        mode.triggerKeys = [.init(key: "not a key")]
        #expect(ModeSummary.triggerDisplay(mode) == nil)
    }

    private func mode(_ entries: [(String, String)]) -> Mode {
        var mode = Mode(id: "multi", name: "Multi")
        mode.triggerKeys = entries.map { .init(key: $0.0, pressStyle: $0.1) }
        return mode
    }

    @Test func noExtraTriggersNoteForASingleShortcut() {
        #expect(ModeSummary.extraTriggersNote(mode([("fn", "hold-or-tap")])) == nil)
    }

    @Test func extraTriggersNoteListsTheLiveExtras() {
        #expect(ModeSummary.extraTriggersNote(mode([("fn", "hold-or-tap"), ("mouse4", "hold-or-tap")]))
            == "Also starts with Mouse Button 4, configured in its TOML file.")
    }

    @Test func extraTriggersNoteNamesAPressBehaviorThatDiffersFromTheFirst() {
        #expect(ModeSummary.extraTriggersNote(mode([("fn", "hold-or-tap"), ("mouse4", "hold-only")]))
            == "Also starts with Mouse Button 4 (Hold to talk), configured in its TOML file.")
    }

    @Test func extraTriggersNoteOnlyReportsAnIgnoredExtra() {
        #expect(ModeSummary.extraTriggersNote(mode([("right_command", "hold-or-tap"), ("command", "hold-or-tap")]))
            == "⌘ is ignored because it is the same press as Right-⌘.")
    }

    @Test func extraTriggersNoteSaysARepeatedShortcutIsListedTwice() {
        #expect(ModeSummary.extraTriggersNote(mode([("fn", "hold-or-tap"), ("fn", "hold-only")]))
            == "Fn (Globe) is listed twice; the second is ignored.")
        #expect(ModeSummary.extraTriggersNote(mode([("hyper", "hold-or-tap"), ("control+option+shift+command", "hold-or-tap")]))
            == "⌃⌥⇧⌘ is listed twice; the second is ignored.")
    }

    @Test func extraTriggersNoteCombinesLiveAndIgnoredExtras() {
        let entries = [("right_command", "hold-or-tap"), ("mouse4", "hold-or-tap"), ("command", "hold-or-tap")]
        #expect(ModeSummary.extraTriggersNote(mode(entries))
            == "Also starts with Mouse Button 4, configured in its TOML file. ⌘ is ignored because it is the same press as Right-⌘.")
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

    @Test func unconstrainedModeExplainsThatItWorksEverywhere() {
        let mode = Mode(id: "blank", name: "Blank")

        #expect(ModeSummary.availabilityDescription(mode) ==
            "Available in every app and website. Add a place to limit this mode to it.")
    }

    @Test func constrainedModeExplainsThatItsPlacesAreLimits() {
        var mode = Mode(id: "email", name: "Email")
        mode.constraints = [Mode.Constraint(bundleId: "com.apple.mail")]

        #expect(ModeSummary.availabilityDescription(mode) == "Available only in these places.")
    }
}
