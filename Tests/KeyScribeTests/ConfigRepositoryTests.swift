import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct ConfigRepositoryTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-repo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The whole point of routing writes through the repository: the change is visible on the NEXT
    // config read without waiting on the FSEvents watcher, and the host is notified.
    @Test func aModeWriteInvalidatesTheCacheAndNotifies() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigCache(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: config)
        var notified = 0
        repo.onChange = { notified += 1 }

        _ = config.modes                              // populate the cache

        var mode = Mode(id: "note", name: "Note")
        mode.aiRewrite = .init(connection: "", prompt: "x")
        try repo.writeMode(mode)

        #expect(config.modes.contains { $0.id == "note" })   // cache re-read from disk
        #expect(notified == 1)
    }

    @Test func aConnectionWriteInvalidatesTheCacheAndNotifies() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigCache(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: config)
        var notified = 0
        repo.onChange = { notified += 1 }

        _ = config.connections
        try repo.upsertConnection(
            Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"))

        #expect(config.connections.connections.map(\.id) == ["c"])
        #expect(notified == 1)
    }

    @Test func mutateDictionaryReadsModifiesWritesAndReturnsTheSet() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DictionaryStore.write(DictionarySet(words: ["Postgres"]), to: dir)
        let config = ConfigCache(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: config)

        let updated = try repo.mutateDictionary { $0.adding(word: "Redis") }

        #expect(Set(updated.words) == ["Postgres", "Redis"])
        #expect(Set(DictionaryStore.loadOrDefault(supportDir: dir).words) == ["Postgres", "Redis"])
    }

    @Test func deletingAModeRemovesTheFileAndInvalidates() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigCache(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: config)
        var mode = Mode(id: "temp", name: "Temp")
        mode.aiRewrite = .init(connection: "", prompt: "x")
        try repo.writeMode(mode)
        #expect(config.modes.contains { $0.id == "temp" })

        try repo.deleteMode(mode)
        #expect(!config.modes.contains { $0.id == "temp" })
    }

    // Connection writes must read-modify-write from disk (like the vocabulary stores), not clobber a whole
    // caller-supplied set: a connection another surface added between one model's snapshot and its save
    // must survive a subsequent delete of an unrelated connection.
    @Test func deletingAConnectionPreservesOneAddedConcurrentlyOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ConnectionStore.write(ConnectionSet(connections: [
            Connection(id: "a", name: "A", provider: .gemini, model: "m", keyRef: "ka"),
            Connection(id: "b", name: "B", provider: .gemini, model: "m", keyRef: "kb"),
        ]), to: dir)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))

        // Another surface adds C to disk...
        try repo.upsertConnection(Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "kc"))
        // ...then this surface removes an unrelated connection (from a FRESH read, not a stale set).
        let after = try repo.deleteConnection(id: "a")

        #expect(after.connections.map(\.id).sorted() == ["b", "c"])
        #expect(ConnectionStore.loadOrDefault(supportDir: dir).connections.map(\.id).sorted() == ["b", "c"])
    }

    @Test func upsertConnectionReplacesByIdNotDuplicates() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ConnectionStore.write(ConnectionSet(connections: [
            Connection(id: "a", name: "A", provider: .gemini, model: "m", keyRef: "ka"),
        ]), to: dir)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))

        let set = try repo.upsertConnection(
            Connection(id: "a", name: "A renamed", provider: .gemini, model: "m2", keyRef: "ka"))

        #expect(set.connections.count == 1)
        #expect(set.connections.first?.name == "A renamed")
        #expect(set.connections.first?.model == "m2")
    }

    // A rename is one operation: the new file lands and the old file is gone — never both (no duplicate).
    @Test func renameModeLeavesNoDuplicateFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        var mode = Mode(id: "old", name: "Old")
        mode.aiRewrite = .init(connection: "", prompt: "x")
        try repo.writeMode(mode)

        try repo.renameMode(mode, to: "new")

        let ids = ModeStore.loadAll(in: repo.modesDir).map(\.id)
        #expect(ids.contains("new"))
        #expect(!ids.contains("old"))
    }
}
