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

    // A modifier-only trigger fires the instant its set is held, so a set that is a strict subset of another
    // contending mode's set is pressed on the way into it. The 150 ms grace keeps that safe at runtime; the
    // warning is what tells the user why the bigger shortcut has to be pressed as one motion.
    @Test func reportsASubsetSetAsMasking() {
        let modes = [mode("a", key: "left_control+left_command"), mode("b", key: "left_command")]
        let conflict = TriggerKeyConflicts.conflict(for: modes[1], in: modes)
        #expect(conflict?.modeId == "a")
        #expect(conflict?.kind == .masking)
    }

    @Test func maskingAcceptsASidelessSupersetButNotTheReverse() {
        let modes = [mode("a", key: "control+command"), mode("b", key: "right_command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind == .masking)
        // The larger set is not pressed on the way into the smaller one, so it is not masked by it.
        #expect(TriggerKeyConflicts.conflict(for: modes[0], in: modes) == nil)
    }

    // `left_command` is never held on the way into `right_command+control` — the shared modifier names
    // opposite keys, so those presses cannot overlap and the warning would be noise.
    @Test func maskingRequiresTheSharedModifiersToNameCompatibleKeys() {
        let modes = [mode("a", key: "right_command+control"), mode("b", key: "left_command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes) == nil)
    }

    // One press written two ways: shadowing drops a whole binding and Phase A routes by the surviving
    // string, so the loser's mode becomes unreachable no matter what context says.
    @Test func aSidelessTriggerReportsItsSidedTwinAsUnreachable() {
        let modes = [mode("a", key: "command"), mode("b", key: "right_command")]
        let loser = TriggerKeyConflicts.conflict(for: modes[1], in: modes)
        #expect(loser?.kind == .unreachable)
        #expect(loser?.modeId == "a")
    }

    // Shadowing keeps the FIRST registrant, so only the later mode is unreachable. Reporting it both ways
    // put "Shortcut never fires" on the mode whose shortcut does, in fact, fire.
    @Test func onlyTheLaterModeIsUnreachable() {
        let modes = [mode("a", key: "command"), mode("b", key: "right_command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[0], in: modes)?.kind != .unreachable)
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind == .unreachable)
    }

    @Test func reorderingMovesTheUnreachableVerdictToTheNewLoser() {
        let modes = [mode("a", key: "right_command"), mode("b", key: "command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[0], in: modes)?.kind != .unreachable)
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.modeId == "a")
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind == .unreachable)
    }

    // The warning must mirror shadowing exactly: the middle mode lost and was never registered, so it
    // cannot make the third unreachable — and the third really does fire, since left and right ⌘ are
    // mutually exclusive.
    @Test func aShadowedModeDoesNotMakeALaterOneUnreachable() {
        let modes = [
            mode("right", key: "right_command"),
            mode("either", key: "command"),
            mode("left", key: "left_command"),
        ]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind == .unreachable)
        #expect(TriggerKeyConflicts.conflict(for: modes[2], in: modes)?.kind != .unreachable)
        #expect(TriggerKeyConflicts.hasUnreachableTrigger(in: modes))
    }

    @Test func aClaimingModeStillMakesEveryOverlapAfterItUnreachable() {
        let modes = [
            mode("either", key: "command"),
            mode("right", key: "right_command"),
            mode("left", key: "left_command"),
        ]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.modeId == "either")
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind == .unreachable)
        #expect(TriggerKeyConflicts.conflict(for: modes[2], in: modes)?.modeId == "either")
        #expect(TriggerKeyConflicts.conflict(for: modes[2], in: modes)?.kind == .unreachable)
    }

    // `.unreachable` is a claim about the MODE — the list says "Shortcut never fires" and the menu-bar
    // badge lights — so one shadowed trigger among several must not raise it while another still fires.
    @Test func aModeWithOneSurvivingTriggerIsNotUnreachable() {
        let modes = [
            mode("first", key: "right_command"),
            mode("second", keys: ["fn", "command"]),
        ]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind != .unreachable)
        #expect(!TriggerKeyConflicts.hasUnreachableTrigger(in: modes))
    }

    @Test func aModeIsUnreachableOnlyWhenEveryTriggerWasClaimed() {
        let modes = [
            mode("first", key: "command"),
            mode("second", keys: ["right_command", "left_command"]),
        ]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind == .unreachable)
        #expect(TriggerKeyConflicts.hasUnreachableTrigger(in: modes))
    }

    // A second spelling of the SAME shortcut is not a lost trigger: `normalizeKey` canonicalizes, so the
    // surviving binding's string still routes here and the mode stays reachable.
    @Test func aTriggerShadowedByItsOwnSpellingLeavesTheModeReachable() {
        let modes = [mode("first", key: "fn"), mode("second", keys: ["globe"])]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind != .unreachable)
        #expect(!TriggerKeyConflicts.hasUnreachableTrigger(in: modes))
    }

    // Two triggers on ONE mode that claim the same press: runtime keeps the first and drops the second, so
    // the mode still fires. The Settings UI cannot even show a second trigger (it reads and rewrites
    // `triggerKeys.first`), so this stays a TOML-only redundancy, not a mode-level failure.
    @Test func aModeShadowingItsOwnSecondTriggerStillFires() {
        let modes = [mode("only", keys: ["right_command", "command"])]
        #expect(TriggerKeyConflicts.conflict(for: modes[0], in: modes)?.kind != .unreachable)
        #expect(!TriggerKeyConflicts.hasUnreachableTrigger(in: modes))
    }

    // A disabled mode never registers, so it cannot claim the press out from under a later one.
    @Test func aDisabledEarlierModeDoesNotShadow() {
        let modes = [mode("a", key: "command", enabled: false), mode("b", key: "right_command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind != .unreachable)
    }

    @Test func unreachableIsReportedEvenWhenContextWouldSeparateTheModes() {
        let modes = [
            mode("a", key: "command", bundles: ["com.example.a"]),
            mode("b", key: "right_command"),
        ]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind == .unreachable)
    }

    // The whole-config question the Modes pane and the menu-bar badge ask, since the row that explains
    // an unreachable trigger is only visible once that mode is selected.
    @Test func hasUnreachableTriggerSpotsAModeThatCanNeverFire() {
        #expect(TriggerKeyConflicts.hasUnreachableTrigger(
            in: [mode("a", key: "command"), mode("b", key: "right_command")]))
        // Exactly one of the two — the winner must not be counted as a problem itself, or the Modes list
        // flags both rows.
        let pair = [mode("a", key: "command"), mode("b", key: "right_command")]
        let flagged = pair.filter { TriggerKeyConflicts.conflict(for: $0, in: pair)?.kind == .unreachable }
        #expect(flagged.map(\.id) == ["b"])
        #expect(!TriggerKeyConflicts.hasUnreachableTrigger(
            in: [mode("a", key: "hyper"), mode("b", key: "control+option+shift+command")]))
        #expect(!TriggerKeyConflicts.hasUnreachableTrigger(
            in: [mode("a", key: "fn"), mode("b", key: "right_option")]))
        #expect(!TriggerKeyConflicts.hasUnreachableTrigger(
            in: [mode("a", key: "command"), mode("b", key: "right_command", enabled: false)]))
    }

    // The same spelling is fine: the surviving binding carries a string that still routes to both modes.
    @Test func theSameSpellingInSeparableContextsIsNotAConflict() {
        let modes = [
            mode("a", key: "right_command", bundles: ["com.example.a"]),
            mode("b", key: "right_command"),
        ]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes) == nil)
    }

    // `hyper` and its expanded spelling are one descriptor, so Phase A must route them identically —
    // otherwise the shadowed one is silently dead.
    @Test func anAliasSpellingRoutesLikeItsCanonicalForm() {
        var legacy = Mode(id: "a", name: "A")
        legacy.triggerKeys = [.init(key: "hyper")]
        let direct = Mode(id: "d", name: "D")
        let result = ModeResolver.resolvePhaseAWithReason(
            modes: [legacy], directFallback: direct, context: RoutingContext(),
            triggerKey: "control+option+shift+command")
        #expect(result.mode.id == "a")
        #expect(result.reason == .triggerKey)
    }

    @Test func oppositeSidesOfOneModifierAreTwoUsableTriggers() {
        let modes = [mode("a", key: "left_command"), mode("b", key: "right_command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes) == nil)
    }

    @Test func anEqualSetIsACollisionNotMasking() {
        let modes = [mode("a", key: "right_option"), mode("b", key: "right_option")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind == .collision)
    }

    @Test func maskingRespectsContextSeparation() {
        let modes = [
            mode("a", key: "left_control+left_command", bundles: ["com.example.a"]),
            mode("b", key: "left_command"),
        ]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes) == nil)
    }

    @Test func aChordNeverMasksAModifierSet() {
        let modes = [mode("a", key: "control+command+k"), mode("b", key: "left_command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes) == nil)
    }

    @Test func findsConflictAcrossModes() {
        let modes = [mode("a", key: "fn"), mode("b", key: "fn")]
        let conflict = TriggerKeyConflicts.conflict(for: modes[1], in: modes)
        #expect(conflict?.modeId == "a")
        #expect(conflict?.kind == .collision)
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

}
