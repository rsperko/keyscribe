import Foundation
import Testing
@testable import KeyScribe
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

        // A later malformed edit must surface an error AND fall back to the last good copy, not empty —
        // otherwise every replacement silently stops running with no signal (P2-14).
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

        // Delete the file — the correct state is empty, and last-good must follow it.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(ReplacementsStore.fileName))
        cache.invalidate()
        #expect(cache.replacements == ReplacementsSet())

        // A malformed file appearing now must fall back to the post-delete empty state, not the stale rules.
        try "schema_version = 1\n[[rules]\nheard = \"x\"".write(
            to: dir.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)
        cache.invalidate()
        #expect(cache.replacements == ReplacementsSet())
        #expect(cache.configFileError != nil)
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
