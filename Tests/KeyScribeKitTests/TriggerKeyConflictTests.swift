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

    @Test func reportsASubsetSetAsMasking() {
        let modes = [mode("a", key: "left_control+left_command"), mode("b", key: "left_command")]
        let conflict = TriggerKeyConflicts.conflict(for: modes[1], in: modes)
        #expect(conflict?.modeId == "a")
        #expect(conflict?.kind == .masking)
    }

    @Test func maskingAcceptsASidelessSupersetButNotTheReverse() {
        let modes = [mode("a", key: "control+command"), mode("b", key: "right_command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind == .masking)
        #expect(TriggerKeyConflicts.conflict(for: modes[0], in: modes) == nil)
    }

    @Test func maskingRequiresTheSharedModifiersToNameCompatibleKeys() {
        let modes = [mode("a", key: "right_command+control"), mode("b", key: "left_command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes) == nil)
    }

    @Test func aSidelessTriggerReportsItsSidedTwinAsUnreachable() {
        let modes = [mode("a", key: "command"), mode("b", key: "right_command")]
        let loser = TriggerKeyConflicts.conflict(for: modes[1], in: modes)
        #expect(loser?.kind == .unreachable)
        #expect(loser?.modeId == "a")
    }

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

    @Test func aTriggerShadowedByItsOwnSpellingLeavesTheModeReachable() {
        let modes = [mode("first", key: "fn"), mode("second", keys: ["globe"])]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind != .unreachable)
        #expect(!TriggerKeyConflicts.hasUnreachableTrigger(in: modes))
    }

    @Test func aModeShadowingItsOwnSecondTriggerStillFires() {
        let modes = [mode("only", keys: ["right_command", "command"])]
        #expect(TriggerKeyConflicts.conflict(for: modes[0], in: modes)?.kind != .unreachable)
        #expect(!TriggerKeyConflicts.hasUnreachableTrigger(in: modes))
    }

    @Test func aDisabledEarlierModeDoesNotShadow() {
        let modes = [mode("a", key: "command", enabled: false), mode("b", key: "right_command")]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind != .unreachable)
    }

    @Test func aScopedClaimantLeavesALaterUnconstrainedModeReachable() {
        let modes = [
            mode("a", key: "command", bundles: ["com.example.a"]),
            mode("b", key: "right_command"),
        ]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes)?.kind != .unreachable)
    }

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

    @Test func theSameSpellingInSeparableContextsIsNotAConflict() {
        let modes = [
            mode("a", key: "right_command", bundles: ["com.example.a"]),
            mode("b", key: "right_command"),
        ]
        #expect(TriggerKeyConflicts.conflict(for: modes[1], in: modes) == nil)
    }

    @Test func anAliasSpellingRoutesLikeItsCanonicalForm() {
        var legacy = Mode(id: "a", name: "A")
        legacy.triggerKeys = [.init(key: "hyper")]
        let direct = Mode(id: "d", name: "D")
        let result = ModeResolver.resolvePhaseAWithReason(
            modes: [legacy], directFallback: direct, context: RoutingContext(),
            triggerKey: "control+option+shift+command")
        #expect(result?.mode.id == "a")
        #expect(result?.reason == .triggerKey)
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


    @Test func bundleDisjointModesAreNotUnreachable() {
        let vm = mode("vm", key: "command", bundles: ["com.vmware.fusion"])
        let notes = mode("notes", key: "right_command", bundles: ["com.apple.Notes"])
        #expect(TriggerKeyConflicts.conflict(for: notes, in: [vm, notes])?.kind != .unreachable)
    }

    @Test func anUnconstrainedClaimantStillMakesALaterModeUnreachable() {
        let plain = mode("plain", key: "command")
        let vm = mode("vm", key: "right_command", bundles: ["com.vmware.fusion"])
        #expect(TriggerKeyConflicts.conflict(for: vm, in: [plain, vm])?.kind == .unreachable)
    }

    @Test func aURLScopedClaimantStillMakesALaterModeUnreachable() {
        let email = mode("email", key: "command", urlPattern: #"mail\.google\.com"#)
        let vm = mode("vm", key: "right_command", bundles: ["com.vmware.fusion"])
        #expect(TriggerKeyConflicts.conflict(for: vm, in: [email, vm])?.kind == .unreachable)
    }

    @Test func aBundlePrefixClaimantCoversAnExactIdVictim() {
        var chrome = mode("chrome", key: "command")
        chrome.constraints = [Mode.Constraint(bundlePrefix: "com.google.")]
        let mail = mode("mail", key: "right_command", bundles: ["com.google.Chrome"])
        #expect(TriggerKeyConflicts.conflict(for: mail, in: [chrome, mail])?.kind == .unreachable)
    }

    @Test func aConstraintWithBothBundleFieldsScopesToTheExactId() {
        var chrome = mode("chrome", key: "command")
        chrome.constraints = [Mode.Constraint(bundleId: "com.google.Chrome", bundlePrefix: "com.google.")]
        let gmail = mode("gmail", key: "right_command", bundles: ["com.google.Gmail"])
        #expect(TriggerKeyConflicts.conflict(for: gmail, in: [chrome, gmail])?.kind != .unreachable)
    }

    @Test func aRetainedLoserDoesNotClaimWhereItWasItselfShadowed() {
        let a = mode("a", key: "right_command", bundles: ["com.example.a"])
        let b = mode("b", key: "command")
        let c = mode("c", key: "left_command", bundles: ["com.example.a"])
        #expect(TriggerKeyConflicts.conflict(for: c, in: [a, b, c])?.kind != .unreachable)
    }

    @Test func aReplayLoserStillClaimsWhereTheWinnerIsAbsent() {
        let a = mode("a", key: "command", bundles: ["com.apple.TextEdit"])
        let x = mode("x", key: "command")
        let c = mode("c", key: "right_command", bundles: ["com.apple.Notes"])
        let conflict = TriggerKeyConflicts.conflict(for: c, in: [a, x, c])
        #expect(conflict?.kind == .unreachable)
        #expect(conflict?.modeId == "x")
    }

    @Test func aModeKilledByDifferentClaimantsInDifferentAppsIsNotReported() {
        let a = mode("a", key: "command", bundles: ["com.apple.TextEdit"])
        let x = mode("x", key: "command")
        let c = mode("c", key: "right_command")
        #expect(TriggerKeyConflicts.conflict(for: c, in: [a, x, c])?.kind != .unreachable)
    }
}
