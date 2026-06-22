import Testing
@testable import KeyScribeKit

struct TriggerKeyConflictTests {
    private func mode(_ id: String, key: String?, enabled: Bool = true) -> Mode {
        var m = Mode(id: id, name: id.capitalized)
        m.enabled = enabled
        m.triggerKeys = key.map { [.init(key: $0)] } ?? []
        return m
    }

    @Test func findsConflictAcrossModes() throws {
        let modes = [mode("a", key: "fn"), mode("b", key: "control+option+e")]
        let descriptor = try KeyDescriptor(parsing: "fn")
        let conflict = TriggerKeyConflicts.conflict(for: descriptor, excludingModeId: "b", in: modes)
        #expect(conflict?.modeId == "a")
    }

    @Test func ignoresTheModeBeingEdited() throws {
        let modes = [mode("a", key: "fn")]
        let descriptor = try KeyDescriptor(parsing: "fn")
        #expect(TriggerKeyConflicts.conflict(for: descriptor, excludingModeId: "a", in: modes) == nil)
    }

    @Test func ignoresDisabledModes() throws {
        let modes = [mode("a", key: "fn", enabled: false)]
        let descriptor = try KeyDescriptor(parsing: "fn")
        #expect(TriggerKeyConflicts.conflict(for: descriptor, excludingModeId: "b", in: modes) == nil)
    }

    @Test func noConflictForDistinctKeys() throws {
        let modes = [mode("a", key: "fn"), mode("b", key: "right_option")]
        let descriptor = try KeyDescriptor(parsing: "control+option+e")
        #expect(TriggerKeyConflicts.conflict(for: descriptor, excludingModeId: "c", in: modes) == nil)
    }
}
