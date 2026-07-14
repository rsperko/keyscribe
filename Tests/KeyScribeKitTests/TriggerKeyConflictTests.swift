import Testing
@testable import KeyScribeKit

struct TriggerKeyConflictTests {
    private func mode(
        _ id: String, key: String?, enabled: Bool = true, bundles: [String] = [], urlPattern: String? = nil
    ) -> Mode {
        var m = Mode(id: id, name: id.capitalized)
        m.enabled = enabled
        m.triggerKeys = key.map { [.init(key: $0)] } ?? []
        m.constraints = bundles.map { Mode.Constraint(bundleId: $0, urlPattern: urlPattern) }
        if let urlPattern, bundles.isEmpty { m.constraints = [Mode.Constraint(bundleId: nil, urlPattern: urlPattern)] }
        return m
    }

    private func mode(_ id: String, keys: [String], enabled: Bool = true) -> Mode {
        var m = Mode(id: id, name: id.capitalized)
        m.enabled = enabled
        m.triggerKeys = keys.map { .init(key: $0) }
        return m
    }

    @Test func findsConflictAcrossModes() {
        let modes = [mode("a", key: "fn"), mode("b", key: "fn")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.modeId == "a")
    }

    @Test func ignoresTheModeBeingEdited() {
        let modes = [mode("a", key: "fn")]
        #expect(TriggerKeyConflicts.conflict(for: modes[0], in: modes) == nil)
    }

    @Test func ignoresDisabledModes() {
        let edited = mode("b", key: "fn")
        let modes = [mode("a", key: "fn", enabled: false), edited]
        #expect(TriggerKeyConflicts.conflict(for: edited, in: modes) == nil)
    }

    @Test func noConflictForDistinctKeys() {
        let edited = mode("b", key: "right_option")
        let modes = [mode("a", key: "fn"), edited]
        #expect(TriggerKeyConflicts.conflict(for: edited, in: modes) == nil)
    }

    @Test func noConflictWhenConstraintsDisjoint() {
        let slack = mode("slack", key: "right_option", bundles: ["com.tinyspeck.slackmacgap"])
        let obsidian = mode("obsidian", key: "right_option", bundles: ["md.obsidian"])
        #expect(TriggerKeyConflicts.conflict(for: slack, in: [slack, obsidian]) == nil)
    }

    @Test func noConflictUnconstrainedVersusConstrained() {
        let plain = mode("plain", key: "right_option")
        let scoped = mode("scoped", key: "right_option", bundles: ["com.tinyspeck.slackmacgap"])
        #expect(TriggerKeyConflicts.conflict(for: plain, in: [plain, scoped]) == nil)
        #expect(TriggerKeyConflicts.conflict(for: scoped, in: [plain, scoped]) == nil)
    }

    @Test func conflictWhenSameApp() {
        let a = mode("a", key: "right_option", bundles: ["com.tinyspeck.slackmacgap"])
        let b = mode("b", key: "right_option", bundles: ["com.tinyspeck.slackmacgap"])
        #expect(TriggerKeyConflicts.conflict(for: b, in: [a, b])?.modeId == "a")
    }

    @Test func findsConflictOnANonFirstTriggerKey() {
        let edited = mode("b", keys: ["fn", "right_option"])
        let other = mode("a", key: "right_option")
        #expect(TriggerKeyConflicts.conflict(for: edited, in: [other, edited])?.modeId == "a")
    }

    // --- modifierOverlap: only the Hyper trigger genuinely double-fires with a subsuming chord. The
    //     right-side modifier triggers are disambiguated at runtime ("chord wins"), so they no longer
    //     warn — that would be noise on the common right-Option-dictation + Hyper-shortcut setup.

    private func rival(_ key: String, _ label: String = "the other mode") -> TriggerKeyConflicts.RivalBinding {
        .init(key: key, label: label)
    }

    @Test func hyperOverlapsAFullHyperChord() {
        // ⌃⌥⇧⌘X engages the Hyper modifiers, so a Hyper-triggered mode fires alongside the chord.
        let overlap = TriggerKeyConflicts.modifierOverlap(
            triggerKey: "hyper", with: [rival("control+option+shift+command+x", "the Snippet mode’s shortcut")])
        #expect(overlap?.rivalLabel == "the Snippet mode’s shortcut")
    }

    @Test func rightOptionDoesNotWarnAgainstASubsumingChord() {
        // right-Option next to ⌃⌥⇧V is a common, legitimate setup; the runtime's "chord wins" rule
        // suppresses the dictation trigger when the chord is formed, so no warning is needed.
        #expect(TriggerKeyConflicts.modifierOverlap(
            triggerKey: "right_option", with: [rival("control+option+shift+v", "the Add to Vocabulary shortcut")]) == nil)
    }

    @Test func rightCommandAndRightControlDoNotWarnAgainstASubsumingChord() {
        #expect(TriggerKeyConflicts.modifierOverlap(
            triggerKey: "right_command", with: [rival("control+option+shift+command+v")]) == nil)
        #expect(TriggerKeyConflicts.modifierOverlap(
            triggerKey: "right_control", with: [rival("control+option+shift+command+v")]) == nil)
    }

    @Test func hyperDoesNotOverlapAChordMissingCommand() {
        // ⌃⌥⇧V lacks Command, so Hyper (⌃⌥⇧⌘) is not a subset — no double-fire.
        #expect(TriggerKeyConflicts.modifierOverlap(
            triggerKey: "hyper", with: [rival("control+option+shift+v")]) == nil)
    }

    @Test func fnNeverOverlapsAChord() {
        // Fn keys off the Fn flag, which no chord carries.
        #expect(TriggerKeyConflicts.modifierOverlap(
            triggerKey: "fn", with: [rival("control+option+shift+command+x")]) == nil)
    }

    @Test func aChordTriggerIsNotAModifierOnlyOverlapSource() {
        #expect(TriggerKeyConflicts.modifierOverlap(
            triggerKey: "control+option+shift+command+x", with: [rival("control+option+shift+command+x")]) == nil)
    }

    @Test func emptyAndUnparsableRivalsAreIgnored() {
        #expect(TriggerKeyConflicts.modifierOverlap(
            triggerKey: "hyper", with: [rival(""), rival("not-a-key")]) == nil)
    }

    // --- liveActionRivals: only shortcuts that actually register can double-fire, so the warning must
    //     not name a shadowed, unset, or non-chord global shortcut (mirrors AppDelegate.actionBindings).

    private func action(_ id: String, _ key: String, _ label: String = "the shortcut")
        -> TriggerKeyConflicts.ActionShortcut { .init(id: id, key: key, label: label) }

    @Test func liveActionRivalsKeepsAnActiveChordShortcut() {
        let vocab = action("global:add_vocabulary", "control+option+shift+v", "the Add to Vocabulary shortcut")
        #expect(TriggerKeyConflicts.liveActionRivals([vocab], shadowed: []).map(\.label)
                == ["the Add to Vocabulary shortcut"])
    }

    @Test func liveActionRivalsDropsShadowedUnsetAndNonChordShortcuts() {
        let shadowedVocab = action("global:add_vocabulary", "control+option+shift+v")
        #expect(TriggerKeyConflicts.liveActionRivals([shadowedVocab], shadowed: ["global:add_vocabulary"]).isEmpty)
        #expect(TriggerKeyConflicts.liveActionRivals([action("global:paste_last", "")], shadowed: []).isEmpty)
        // A modifier-only key never registers as a global action, so it is not a live rival.
        #expect(TriggerKeyConflicts.liveActionRivals([action("global:add_vocabulary", "right_option")], shadowed: []).isEmpty)
    }

    // A Hyper-triggered mode alongside an Add-Vocabulary chord that is shadowed by another mode on the
    // same chord: the warning must not name the shadowed (inactive) Add-Vocabulary shortcut; the overlap
    // is re-attributed to the enabled mode that actually claims that chord.
    @Test func shadowedActionShortcutIsNotNamedTheShadowingModeIs() {
        let shortcutKey = "control+option+shift+command+v"
        // Ordered as at runtime: modes first, then the global — so the mode claims the chord and the
        // global add-vocabulary is shadowed.
        let shadowed = HotkeyConflicts.shadowed([
            .init(id: "vocab-mode#\(shortcutKey)", key: shortcutKey),
            .init(id: "global:add_vocabulary", key: shortcutKey),
        ])
        #expect(shadowed.contains("global:add_vocabulary"))

        let liveActions = TriggerKeyConflicts.liveActionRivals(
            [action("global:add_vocabulary", shortcutKey, "the Add to Vocabulary shortcut")], shadowed: shadowed)
        #expect(liveActions.isEmpty)

        // The enabled mode on that chord is the real rival; Hyper is subsumed by its modifiers.
        let rivals = liveActions + [rival(shortcutKey, "the Snippet mode’s shortcut")]
        #expect(TriggerKeyConflicts.modifierOverlap(triggerKey: "hyper", with: rivals)?.rivalLabel
                == "the Snippet mode’s shortcut")
    }
}
