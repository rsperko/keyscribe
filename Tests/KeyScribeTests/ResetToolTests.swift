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

    // Production layout: models are nested inside the support dir, so `all` wipes config but keeps them.
    @Test func allWipesConfigButKeepsNestedSharedModels() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ephemeralDefaults()
        let fm = FileManager.default

        var tool = ResetTool(supportDir: dir, defaults: defaults)
        tool.modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        tool.run(.all)

        #expect(fm.fileExists(atPath: dir.appendingPathComponent("models/parakeet/weights.bin").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("modes/custom-junk.toml").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
    }

    // Dev layout: models live outside the support dir, so `all` removes the whole support dir and the
    // shared cache (elsewhere) is untouched.
    @Test func allRemovesSupportDirWhenModelsLiveOutsideIt() throws {
        let dir = try makeSupportDir()
        let modelsDir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: modelsDir) }
        let defaults = ephemeralDefaults()
        let fm = FileManager.default

        var tool = ResetTool(supportDir: dir, defaults: defaults)
        tool.modelsDir = modelsDir.appendingPathComponent("models", isDirectory: true)
        tool.run(.all)

        #expect(!fm.fileExists(atPath: dir.path))
        #expect(fm.fileExists(atPath: modelsDir.appendingPathComponent("models/parakeet/weights.bin").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
    }

    // eraseAll = all (wipe config, keep shared models) PLUS erasing the BYOK Keychain keys. The Keychain
    // seam is injected so the test never touches the real login keychain; TCC is left untouched.
    @Test func eraseAllWipesConfigKeepsModelsAndErasesKeychain() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ephemeralDefaults()
        let fm = FileManager.default
        var keychainErased = false
        var tccCalls: [String] = []

        var tool = ResetTool(supportDir: dir, defaults: defaults)
        tool.modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        tool.eraseKeychain = { keychainErased = true; return ["Erased 2 saved AI keys from the Keychain."] }
        tool.resetTCCService = { service, _ in tccCalls.append(service); return "" }
        tool.run(.eraseAll)

        #expect(keychainErased)
        #expect(tccCalls.isEmpty)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("models/parakeet/weights.bin").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("modes/custom-junk.toml").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
    }

    @Test func permissionsResetsEachTCCServiceWithoutTouchingFilesOrFlag() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ephemeralDefaults()
        var calls: [String] = []

        var tool = ResetTool(supportDir: dir, defaults: defaults)
        tool.bundleID = "com.keyscribe.app"
        tool.resetTCCService = { service, bundleID in
            calls.append("\(service):\(bundleID)")
            return "Reset \(service)"
        }
        let actions = tool.run(.permissions)

        #expect(calls == ["Microphone:com.keyscribe.app", "Accessibility:com.keyscribe.app", "AppleEvents:com.keyscribe.app"])
        #expect(actions.contains { $0.contains("Relaunch") })
        // A permissions reset is TCC-only: config files and the first-run flag are untouched.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == true)
    }

    @Test func modesWipesAndReseedsStarters() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modesDir = dir.appendingPathComponent("modes")

        ResetTool(supportDir: dir, defaults: ephemeralDefaults()).run(.modes)

        let tomls = (try? FileManager.default.contentsOfDirectory(at: modesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "toml" }) ?? []
        let stems = Set(tomls.map { $0.deletingPathExtension().lastPathComponent })
        // Reset reseeds the starters AND the system Direct floor.
        #expect(stems == Set(ModeStore.starterModes().map { $0.id }).union([Mode.directId]))
        #expect(!stems.contains("custom-junk"))
    }
}
