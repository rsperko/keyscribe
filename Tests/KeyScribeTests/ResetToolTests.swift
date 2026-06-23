import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct ResetToolTests {
    private func makeSupportDir() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("keyscribe-reset-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("modes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("fragments"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("models/parakeet"), withIntermediateDirectories: true)
        try "schema_version = 1\n".write(to: dir.appendingPathComponent("settings.toml"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("modes/custom-junk.toml"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("fragments/sig.md"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: dir.appendingPathComponent("models/parakeet/weights.bin"))
        return dir
    }

    private func ephemeralDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "reset-test-\(UUID().uuidString)")!
        d.set(true, forKey: ResetTool.firstRunKey)
        return d
    }

    @Test func onboardingClearsFlagOnly() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ephemeralDefaults()

        ResetTool(supportDir: dir, defaults: defaults).run(.onboarding)

        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("models/parakeet/weights.bin").path))
    }

    @Test func configWipesEverythingExceptModelsAndClearsFlag() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ephemeralDefaults()
        let fm = FileManager.default

        ResetTool(supportDir: dir, defaults: defaults).run(.config)

        #expect(fm.fileExists(atPath: dir.appendingPathComponent("models/parakeet/weights.bin").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("modes/custom-junk.toml").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("fragments/sig.md").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
    }

    @Test func allWipesEntireSupportDirIncludingModels() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ephemeralDefaults()

        ResetTool(supportDir: dir, defaults: defaults).run(.all)

        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
    }

    @Test func modesWipesAndReseedsStarters() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modesDir = dir.appendingPathComponent("modes")

        ResetTool(supportDir: dir, defaults: ephemeralDefaults()).run(.modes)

        let tomls = (try? FileManager.default.contentsOfDirectory(at: modesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "toml" }) ?? []
        let stems = Set(tomls.map { $0.deletingPathExtension().lastPathComponent })
        #expect(stems == Set(ModeStore.starterModes().map { $0.id }))
        #expect(!stems.contains("custom-junk"))
    }
}
