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
