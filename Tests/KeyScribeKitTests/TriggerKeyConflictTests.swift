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
}
