import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct ConfigCacheErrorTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-configcache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func cleanConfigHasNoFileError() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ReplacementsStore.write(ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: false)]), to: dir)
        try ConnectionStore.write(ConnectionSet(), to: dir)
        #expect(ConfigCache(supportDir: dir).configFileError == nil)
    }

    @Test func malformedReplacementsSurfacesAndKeepsLastGood() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: false)])
        try ReplacementsStore.write(good, to: dir)
        let cache = ConfigCache(supportDir: dir)
        #expect(cache.replacements == good)
        #expect(cache.configFileError == nil)

        // Must surface an error AND fall back to the last good copy, not empty — otherwise every
        // replacement silently stops running with no signal.
        try "schema_version = 1\n[[rules]\nheard = \"x\"".write(
            to: dir.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)
        cache.invalidate()
        #expect(cache.replacements == good)
        let message = try #require(cache.configFileError)
        #expect(message.contains(ReplacementsStore.fileName))
    }

    @Test func deletedThenMalformedFileDoesNotResurrectThePreDeleteRules() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: false)])
        try ReplacementsStore.write(good, to: dir)
        let cache = ConfigCache(supportDir: dir)
        #expect(cache.replacements == good)

        try FileManager.default.removeItem(at: dir.appendingPathComponent(ReplacementsStore.fileName))
        cache.invalidate()
        #expect(cache.replacements == ReplacementsSet())

        try "schema_version = 1\n[[rules]\nheard = \"x\"".write(
            to: dir.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)
        cache.invalidate()
        #expect(cache.replacements == ReplacementsSet())
        #expect(cache.configFileError != nil)
    }

    @Test func onlyAFileThatLoadedBeforeClaimsItsPreviousVersionIsStillInUse() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(ReplacementsStore.fileName)
        let malformed = "schema_version = 1\n[[rules]\nheard = \"x\""

        try malformed.write(to: url, atomically: true, encoding: .utf8)
        let cache = ConfigCache(supportDir: dir)
        let atLaunch = try #require(cache.configFileError)
        #expect(!atLaunch.contains("previous version"))
        #expect(atLaunch.contains("ignored until fixed"))

        try ReplacementsStore.write(ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: false)]), to: dir)
        cache.invalidate()
        #expect(cache.configFileError == nil)

        try malformed.write(to: url, atomically: true, encoding: .utf8)
        cache.invalidate()
        #expect(try #require(cache.configFileError).contains("previous version still in use"))

        try FileManager.default.removeItem(at: url)
        cache.invalidate()
        #expect(cache.configFileError == nil)
        try malformed.write(to: url, atomically: true, encoding: .utf8)
        cache.invalidate()
        #expect(try #require(cache.configFileError).contains("ignored until fixed"))
    }

    @Test func aKeyNothingReadsIsReportedAsAWarningUntilItIsFixed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        let url = modesDir.appendingPathComponent("notes.toml")
        try "schema_version = 2\nname = \"Notes\"\ntrigger_key = [\"fn\"]\n".write(to: url, atomically: true, encoding: .utf8)

        let cache = ConfigCache(supportDir: dir)
        #expect(cache.configFileError == nil)
        #expect(cache.fileWarnings.map(\.oneLine) == ["notes.toml — “trigger_key” (did you mean “trigger_keys”?) has no effect"])
        #expect(cache.fileWarnings.map(\.relativePath) == ["modes/notes.toml"])

        try "schema_version = 2\nname = \"Notes\"\ntrigger_keys = [{ key = \"fn\" }]\n".write(to: url, atomically: true, encoding: .utf8)
        cache.invalidate()
        #expect(cache.fileWarnings.isEmpty)
    }

    @Test func malformedModeFileSurfacesAsFileError() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try "name = \"Broken\"\nnot = [valid".write(
            to: modesDir.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8)

        let cache = ConfigCache(supportDir: dir)
        let message = try #require(cache.configFileError)
        #expect(message.contains("broken"))
    }

    @Test func unsafeRoutingExpressionLeavesTheModeAvailableForRepair() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try "schema_version = 1\nname = \"Unsafe\"\ntrigger_phrases = ['(a+)+$']".write(
            to: modesDir.appendingPathComponent("unsafe.toml"), atomically: true, encoding: .utf8)

        let cache = ConfigCache(supportDir: dir)
        #expect(cache.configFileError == nil)
        #expect(cache.modes.first?.invalidRoutingPatternFields == ["trigger_phrases"])
    }

    @Test func newerSchemaConnectionsSurfacesAsFileError() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "schema_version = 99".write(
            to: dir.appendingPathComponent(ConnectionStore.fileName), atomically: true, encoding: .utf8)
        let cache = ConfigCache(supportDir: dir)
        #expect(cache.connections.connections.isEmpty)
        let message = try #require(cache.configFileError)
        #expect(message.contains(ConnectionStore.fileName))
    }
}
