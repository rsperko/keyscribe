import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct ReplacementUsageSettingsTests {
    @Test func aRuleShowsHowOftenItWasUsedAndRefreshesAfterADictation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rule = ReplacementsSet.Rule(heard: "teh", replace: "the", regex: false)
        try ReplacementsStore.write(ReplacementsSet(rules: [rule]), to: dir)
        let usage = ReplacementUsageStore(supportDir: dir, onChange: {
            Task { @MainActor in NotificationCenter.default.post(name: .replacementUsageDidChange, object: nil) }
        })
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir), replacementUsage: usage)
        repo.reconcileReplacementUsage()
        let model = ReplacementsSettingsModel(repository: repo)
        #expect(model.usageCaption(for: rule, in: .global) == "No uses recorded yet")

        usage.record([ReplacementRule(heard: "teh", replace: "the", isRegex: false, origin: .global)])
        for _ in 0..<50 where model.usageCaption(for: rule, in: .global) == "No uses recorded yet" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.usageCaption(for: rule, in: .global) == "Used in 1 dictation · last used today")
        #expect(model.usageCaption(for: rule, in: .mode("code")) == nil)
    }

    @Test func aRuleAddedAfterTrackingBeganSaysItWasAddedToday() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let usage = ReplacementUsageStore(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir), replacementUsage: usage)
        repo.reconcileReplacementUsage()
        let model = ReplacementsSettingsModel(repository: repo)
        model.add(heard: "teh", replace: "the", regex: false)
        usage.flush()
        model.refreshUsage()
        #expect(model.usageCaption(for: .init(heard: "teh", replace: "the", regex: false), in: .global) == "Added today")
    }
}
