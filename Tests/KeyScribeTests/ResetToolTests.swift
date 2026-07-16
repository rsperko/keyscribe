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

    // Production layout: models are nested inside the support dir, so `all` must wipe config but keep them.
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

    // Dev layout: models live outside the support dir, so `all` removes the whole support dir while the
    // shared cache elsewhere stays untouched.
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
    // seam is injected so the test never touches the real login keychain.
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

    // Retained capture WAVs (`[audio] keep_captures`) live OUTSIDE supportDir, so every supportDir wipe
    // misses them. They are raw speech and the UI promises permanent deletion, so the erase must take them.
    @Test func eraseAllRemovesRetainedCaptureRecordings() throws {
        let dir = try makeSupportDir()
        let captures = dir.deletingLastPathComponent()
            .appendingPathComponent("KeyScribeTest-captures-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: captures)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: captures, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: captures.appendingPathComponent("commit-a.wav"))
        try Data("wav".utf8).write(to: captures.appendingPathComponent("commit-b.wav"))

        var tool = ResetTool(supportDir: dir, defaults: ephemeralDefaults())
        tool.modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        tool.captureArchiveDir = captures
        tool.eraseKeychain = { [] }
        tool.resetTCCService = { _, _ in "" }
        let actions = tool.run(.eraseAll)

        #expect(!fm.fileExists(atPath: captures.path))
        #expect(actions.contains { $0.contains("2 retained recordings") })
    }

    // The archive is opt-in and usually absent; an erase must not claim to have deleted recordings that
    // never existed.
    @Test func eraseAllReportsNoRecordingsWhenTheArchiveIsAbsent() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var tool = ResetTool(supportDir: dir, defaults: ephemeralDefaults())
        tool.modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        tool.captureArchiveDir = dir.deletingLastPathComponent()
            .appendingPathComponent("keyscribe-absent-\(UUID().uuidString)", isDirectory: true)
        tool.eraseKeychain = { [] }
        tool.resetTCCService = { _, _ in "" }

        #expect(!tool.run(.eraseAll).contains { $0.contains("retained recording") })
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
        // TCC-only: config files and the first-run flag are untouched.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == true)
    }

    @Test func modesWipesToOnlyDirectAndRecordsStarterOffers() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modesDir = dir.appendingPathComponent("modes")

        ResetTool(supportDir: dir, defaults: ephemeralDefaults()).run(.modes)

        let tomls = (try? FileManager.default.contentsOfDirectory(at: modesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "toml" }) ?? []
        let stems = Set(tomls.map { $0.deletingPathExtension().lastPathComponent })
        // Reset writes only the system Direct floor; the starters become ledger offers (templates), not files.
        #expect(stems == [Mode.directId])
        #expect(!stems.contains("custom-junk"))
        let ledger = ModeStore.loadLedger(in: dir.appendingPathComponent("lkg", isDirectory: true))
        #expect(Set(ledger?.entries.map(\.seedId) ?? []) == Set(ModeStore.starterModes().map(\.id)))
    }
}
