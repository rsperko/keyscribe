import Testing
@testable import KeyScribeKit

struct HotkeyConflictsTests {
    private func reg(_ id: String, _ key: String, enabled: Bool = true) -> HotkeyConflicts.Registrant {
        HotkeyConflicts.Registrant(id: id, key: key, enabled: enabled)
    }

    @Test func noShadowsWhenAllDistinct() {
        let shadowed = HotkeyConflicts.shadowed([
            reg("a", "fn"), reg("b", "right_option"), reg("dict", "control+option+d"),
        ])
        #expect(shadowed.isEmpty)
    }

    @Test func laterDuplicateIsShadowed() {
        let shadowed = HotkeyConflicts.shadowed([
            reg("first", "control+option+e"), reg("second", "control+option+e"),
        ])
        #expect(shadowed == ["second"])
    }

    @Test func globalShadowedByMode() {
        let shadowed = HotkeyConflicts.shadowed([
            reg("mode", "control+option+e"), reg("global:vocab", "control+option+e"),
        ])
        #expect(shadowed == ["global:vocab"])
    }

    @Test func threeWayCollisionShadowsAllButFirst() {
        let shadowed = HotkeyConflicts.shadowed([
            reg("a", "control+option+e"), reg("b", "control+option+e"), reg("c", "control+option+e"),
        ])
        #expect(shadowed == ["b", "c"])
    }

    // Collision stopped being transitive the moment a sideless member could stand in for either key:
    // right_command ~ command ~ left_command, but right_command and left_command cannot both engage. A
    // binding that LOST was never registered, so it must not claim the press away from a later one.
    @Test func aShadowedRegistrantDoesNotItselfShadowALaterOne() {
        let shadowed = HotkeyConflicts.shadowed([
            reg("right", "right_command"), reg("either", "command"), reg("left", "left_command"),
        ])
        #expect(shadowed == ["either"])
    }

    // …but a registrant that actually claimed still shadows everything it overlaps.
    @Test func aSidelessClaimShadowsBothSidedSpellingsAfterIt() {
        let shadowed = HotkeyConflicts.shadowed([
            reg("either", "command"), reg("right", "right_command"), reg("left", "left_command"),
        ])
        #expect(shadowed == ["right", "left"])
    }

    @Test func oppositeSidesOfOneModifierBothRegister() {
        let shadowed = HotkeyConflicts.shadowed([
            reg("left", "left_command"), reg("right", "right_command"),
        ])
        #expect(shadowed.isEmpty)
    }

    @Test func disabledRegistrantDoesNotClaim() {
        let shadowed = HotkeyConflicts.shadowed([
            reg("mode", "control+option+e", enabled: false),
            reg("global:vocab", "control+option+e"),
        ])
        #expect(shadowed.isEmpty)
    }

    @Test func disabledRegistrantIsNotShadowed() {
        let shadowed = HotkeyConflicts.shadowed([
            reg("mode", "control+option+e"),
            reg("global:vocab", "control+option+e", enabled: false),
        ])
        #expect(shadowed.isEmpty)
    }

    @Test func emptyKeysIgnored() {
        let shadowed = HotkeyConflicts.shadowed([reg("a", ""), reg("b", "")])
        #expect(shadowed.isEmpty)
    }
}
