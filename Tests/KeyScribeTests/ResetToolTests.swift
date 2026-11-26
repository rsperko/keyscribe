import Foundation
import Testing
@testable import KeyScribeApp
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

    private func isolatedTool(_ dir: URL, _ defaults: UserDefaults) -> ResetTool {
        var tool = ResetTool(supportDir: dir, defaults: defaults)
        tool.modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        tool.captureArchiveDir = URL(fileURLWithPath: dir.path + "-captures", isDirectory: true)
        tool.modelLoadDiagFile = URL(fileURLWithPath: dir.path + "-model-load.log")
        tool.requestAdaptationsFile = URL(fileURLWithPath: dir.path + "-request-adaptations.json")
        tool.wireOverridesFile = URL(fileURLWithPath: dir.path + "-wire-overrides.json")
        tool.temporaryDir = URL(fileURLWithPath: dir.path + "-tmp", isDirectory: true)
        tool.eraseKeychain = { [] }
        tool.resetTCCService = { _, _ in "" }
        return tool
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
        defaults.set(true, forKey: ResetTool.accessibilityAtLastLaunchKey)

        isolatedTool(dir, defaults).run(.onboarding)

        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
        #expect(defaults.object(forKey: ResetTool.accessibilityAtLastLaunchKey) == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("models/parakeet/weights.bin").path))
    }

    @Test func configWipesEverythingExceptModelsAndClearsFlag() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ephemeralDefaults()
        let fm = FileManager.default

        isolatedTool(dir, defaults).run(.config)

        #expect(fm.fileExists(atPath: dir.appendingPathComponent("models/parakeet/weights.bin").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("modes/custom-junk.toml").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("fragments/sig.md").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
    }

    @Test func configResetKeepsTheUsersOwnAgentInstructions() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "mine".write(to: dir.appendingPathComponent("AGENTS.override.md"), atomically: true, encoding: .utf8)

        isolatedTool(dir, ephemeralDefaults()).run(.config)

        #expect(try String(contentsOf: dir.appendingPathComponent("AGENTS.override.md"), encoding: .utf8) == "mine")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
    }

    @Test func allWipesConfigButKeepsNestedSharedModels() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ephemeralDefaults()
        let fm = FileManager.default

        var tool = isolatedTool(dir, defaults)
        tool.modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        tool.run(.all)

        #expect(fm.fileExists(atPath: dir.appendingPathComponent("models/parakeet/weights.bin").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("modes/custom-junk.toml").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
    }

    @Test func allRemovesSupportDirWhenModelsLiveOutsideIt() throws {
        let dir = try makeSupportDir()
        let modelsDir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: modelsDir) }
        let defaults = ephemeralDefaults()
        let fm = FileManager.default

        var tool = isolatedTool(dir, defaults)
        tool.modelsDir = modelsDir.appendingPathComponent("models", isDirectory: true)
        tool.run(.all)

        #expect(!fm.fileExists(atPath: dir.path))
        #expect(fm.fileExists(atPath: modelsDir.appendingPathComponent("models/parakeet/weights.bin").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == false)
    }

    @Test func eraseAllWipesConfigKeepsModelsAndErasesKeychain() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ephemeralDefaults()
        let fm = FileManager.default
        var keychainErased = false
        var tccCalls: [String] = []

        var tool = isolatedTool(dir, defaults)
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

    @Test func eraseAllRemovesClipboardFilesSavedForAgents() throws {
        let dir = try makeSupportDir()
        let tool = isolatedTool(dir, ephemeralDefaults())
        defer { for url in [dir, tool.temporaryDir] { try? FileManager.default.removeItem(at: url) } }
        let saved = AgentClipboard.folder(in: tool.temporaryDir)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: saved.appendingPathComponent("clipboard-1-a.png"))

        let actions = tool.run(.eraseAll)

        #expect(!FileManager.default.fileExists(atPath: saved.path))
        #expect(actions.contains { $0.contains("1 clipboard file") })
    }

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

        var tool = isolatedTool(dir, ephemeralDefaults())
        tool.modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        tool.captureArchiveDir = captures
        tool.eraseKeychain = { [] }
        tool.resetTCCService = { _, _ in "" }
        let actions = tool.run(.eraseAll)

        #expect(!fm.fileExists(atPath: captures.path))
        #expect(actions.contains { $0.contains("2 retained recordings") })
    }

    @Test func eraseAllRemovesTheModelLoadLogAndAbandonedRecordingsButSparesAFreshLegacyOne() throws {
        let dir = try makeSupportDir()
        var tool = isolatedTool(dir, ephemeralDefaults())
        defer {
            for url in [dir, tool.temporaryDir, tool.modelLoadDiagFile] { try? FileManager.default.removeItem(at: url) }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: tool.temporaryDir, withIntermediateDirectories: true)
        try "engine failed".write(to: tool.modelLoadDiagFile, atomically: true, encoding: .utf8)
        let abandoned = CaptureLeftovers.newURL(in: tool.temporaryDir, pid: 4242)
        try Data("wav".utf8).write(to: abandoned)
        let legacy = tool.temporaryDir.appendingPathComponent("\(CaptureLeftovers.prefix)\(UUID().uuidString).wav")
        try Data("wav".utf8).write(to: legacy)
        tool.isProcessAlive = { _ in false }
        tool.run(.eraseAll)

        #expect(!fm.fileExists(atPath: tool.modelLoadDiagFile.path))
        #expect(!fm.fileExists(atPath: abandoned.path))
        #expect(fm.fileExists(atPath: legacy.path))
    }

    @Test func eraseAllRemovesWhatTheAIServicesAccepted() throws {
        let dir = try makeSupportDir()
        let tool = isolatedTool(dir, ephemeralDefaults())
        let files = [tool.requestAdaptationsFile, tool.wireOverridesFile]
        defer { for url in [dir] + files { try? FileManager.default.removeItem(at: url) } }
        for file in files { try #"{"work\nmodel\nhttps://proxy.example/v1":"responses"}"#.write(to: file, atomically: true, encoding: .utf8) }

        tool.run(.eraseAll)

        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func eraseAllReportsRecordingsItCouldNotErase() throws {
        let dir = try makeSupportDir()
        let captures = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyScribeTest-captures-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captures.path)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: captures)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: captures, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: captures.appendingPathComponent("commit-a.wav"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: captures.path)

        var tool = isolatedTool(dir, ephemeralDefaults())
        tool.modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        tool.captureArchiveDir = captures
        tool.eraseKeychain = { [] }
        tool.resetTCCService = { _, _ in "" }
        let actions = tool.run(.eraseAll)

        #expect(fm.fileExists(atPath: captures.appendingPathComponent("commit-a.wav").path))
        #expect(!actions.contains { $0.hasPrefix("Erased") && $0.contains("retained recording") })
        #expect(actions.contains { $0.hasPrefix("Could not erase") && $0.contains("retained recording") })
    }

    enum StuckStep: CaseIterable {
        case supportChild, wholeSupportDir, captureArchive, agentClipboard, cachedFiles, modes, config
    }

    @Test(arguments: StuckStep.allCases)
    func aStepThatCannotDeleteReportsFailureInsteadOfSuccess(_ step: StuckStep) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("keyscribe-reset-stuck-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("support", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("modes"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("modes/custom-junk.toml"), atomically: true, encoding: .utf8)
        try "schema_version = 1\n".write(to: dir.appendingPathComponent("settings.toml"), atomically: true, encoding: .utf8)
        var locked: [URL] = []
        defer {
            for url in locked { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            try? fm.removeItem(at: root)
        }
        func lock(_ url: URL, _ mode: Int) throws {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            locked.append(url)
        }
        var tool = ResetTool(supportDir: dir, defaults: ephemeralDefaults())
        tool.modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        let cached = root.appendingPathComponent("cached", isDirectory: true)
        try fm.createDirectory(at: cached, withIntermediateDirectories: true)
        tool.modelLoadDiagFile = cached.appendingPathComponent("model-load.log")
        tool.requestAdaptationsFile = cached.appendingPathComponent("request-adaptations.json")
        tool.wireOverridesFile = cached.appendingPathComponent("wire-overrides.json")
        tool.captureArchiveDir = root.appendingPathComponent("captures", isDirectory: true)
        tool.temporaryDir = root.appendingPathComponent("tmp", isDirectory: true)
        tool.eraseKeychain = { [] }
        tool.resetTCCService = { _, _ in "" }

        let target: ResetTarget
        let success: String
        switch step {
        case .supportChild:
            try lock(dir, 0o555)
            (target, success) = (.eraseAll, "Reset all config")
        case .wholeSupportDir:
            tool.modelsDir = root.appendingPathComponent("models", isDirectory: true)
            try lock(dir, 0o555)
            (target, success) = (.eraseAll, "Removed \(dir.path)")
        case .captureArchive:
            try fm.createDirectory(at: tool.captureArchiveDir, withIntermediateDirectories: true)
            try Data("wav".utf8).write(to: tool.captureArchiveDir.appendingPathComponent("commit-a.wav"))
            try lock(tool.captureArchiveDir, 0o000)
            (target, success) = (.eraseAll, "retained recording")
        case .agentClipboard:
            let folder = AgentClipboard.folder(in: tool.temporaryDir)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try "clip".write(to: folder.appendingPathComponent("clip.txt"), atomically: true, encoding: .utf8)
            try lock(folder, 0o000)
            (target, success) = (.eraseAll, "clipboard file")
        case .cachedFiles:
            for file in [tool.modelLoadDiagFile, tool.requestAdaptationsFile, tool.wireOverridesFile] {
                try "x".write(to: file, atomically: true, encoding: .utf8)
            }
            try lock(cached, 0o555)
            (target, success) = (.eraseAll, tool.modelLoadDiagFile.path)
        case .modes:
            try lock(dir.appendingPathComponent("modes"), 0o555)
            (target, success) = (.modes, "Reset modes")
        case .config:
            try lock(dir, 0o555)
            (target, success) = (.config, "Wiped config")
        }

        let actions = tool.run(target)

        #expect(!actions.contains { $0.contains(success) && !$0.hasPrefix("Could not") }, "\(actions)")
        #expect(actions.contains { $0.hasPrefix("Could not") }, "\(actions)")
        if step == .cachedFiles {
            let named = [tool.modelLoadDiagFile, tool.requestAdaptationsFile, tool.wireOverridesFile].map(\.path)
            #expect(actions.contains { line in line.hasPrefix("Could not erase") && named.allSatisfy { line.contains($0) } })
        }
    }

    @Test func aModesResetThatCannotRemoveTheLedgerStillLeavesTheSystemModes() throws {
        let dir = try makeSupportDir()
        let lkg = dir.appendingPathComponent("lkg", isDirectory: true)
        try FileManager.default.createDirectory(at: lkg, withIntermediateDirectories: true)
        try "x".write(to: lkg.appendingPathComponent("ledger.json"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lkg.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lkg.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)

        let actions = isolatedTool(dir, ephemeralDefaults()).run(.modes)

        #expect(actions.contains { $0.hasPrefix("Could not reset modes") })
        let modes = ModeStore.loadAll(in: modesDir)
        #expect(!modes.isEmpty)
        #expect(!modes.contains { $0.id == "custom-junk" })
    }

    @Test func eraseAllReportsNoRecordingsWhenTheArchiveIsAbsent() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var tool = isolatedTool(dir, ephemeralDefaults())
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

        var tool = isolatedTool(dir, defaults)
        tool.bundleID = "com.keyscribe.app"
        tool.resetTCCService = { service, bundleID in
            calls.append("\(service):\(bundleID)")
            return "Reset \(service)"
        }
        let actions = tool.run(.permissions)

        #expect(calls == ["Microphone:com.keyscribe.app", "Accessibility:com.keyscribe.app", "AppleEvents:com.keyscribe.app"])
        #expect(actions.contains { $0.contains("Relaunch") })
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.toml").path))
        #expect(defaults.bool(forKey: ResetTool.firstRunKey) == true)
    }

    @Test func modesWipesToOnlyDirectAndRecordsStarterOffers() throws {
        let dir = try makeSupportDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modesDir = dir.appendingPathComponent("modes")

        isolatedTool(dir, ephemeralDefaults()).run(.modes)

        let tomls = (try? FileManager.default.contentsOfDirectory(at: modesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "toml" }) ?? []
        let stems = Set(tomls.map { $0.deletingPathExtension().lastPathComponent })
        #expect(stems == [Mode.directId])
        #expect(!stems.contains("custom-junk"))
        let ledger = ModeStore.loadLedger(in: dir.appendingPathComponent("lkg", isDirectory: true))
        #expect(Set(ledger?.entries.map(\.seedId) ?? []) == Set(ModeStore.starterModes().map(\.id)))
    }
}
