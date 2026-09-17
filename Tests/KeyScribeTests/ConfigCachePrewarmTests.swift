import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct ConfigCachePrewarmTests {
    @Test func prewarmBuildsThePlanAndEveryEnabledModesStagesBeforeAPress() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-prewarm-\(UUID().uuidString)", isDirectory: true)
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var disabled = Mode(id: "off", name: "Off")
        disabled.enabled = false
        try ModeStore.write(Mode(id: "on", name: "On"), to: modesDir)
        try ModeStore.write(disabled, to: modesDir)
        let cache = ConfigCache(supportDir: dir)

        await cache.prewarm().value

        let plan = cache.resolved
        #expect(plan.cachedTextStageModeIds == ["on"])
        #expect(plan.cachedBiasTermModeIds == ["on"])
    }

    @Test func prewarmAfterInvalidateBuildsTheNewGenerationNotTheOld() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-prewarm-\(UUID().uuidString)", isDirectory: true)
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ModeStore.write(Mode(id: "first", name: "First"), to: modesDir)
        let cache = ConfigCache(supportDir: dir)
        await cache.prewarm().value
        let stale = cache.resolved

        try ModeStore.write(Mode(id: "second", name: "Second"), to: modesDir)
        cache.invalidate()
        await cache.prewarm().value

        #expect(cache.resolved !== stale)
        #expect(cache.resolved.cachedTextStageModeIds == ["first", "second"])
    }
}
