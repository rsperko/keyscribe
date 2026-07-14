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

    // Routing writes through the repository must make the change visible on the NEXT config read
    // without waiting on the FSEvents watcher, and notify the host.
    @Test func aModeWriteInvalidatesTheCacheAndNotifies() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigCache(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: config)
        var notified = 0
        repo.onChange = { notified += 1 }

        _ = config.modes

        var mode = Mode(id: "note", name: "Note")
        mode.aiRewrite = .init(connection: "", prompt: "x")
        try repo.writeMode(mode)

        #expect(config.modes.contains { $0.id == "note" })
        #expect(notified == 1)
    }

    // Fragment files are written directly, not through `commit`, so their self-write must independently
    // invalidate + notify — otherwise the resolved plan keeps stale instruction text until relaunch.
    @Test func recordingAFragmentSelfWriteInvalidatesResolvedAndNotifies() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fragmentsDir = dir.appendingPathComponent("fragments", isDirectory: true)
        try FileManager.default.createDirectory(at: fragmentsDir, withIntermediateDirectories: true)
        let fragURL = fragmentsDir.appendingPathComponent("tone.md")
        try FragmentStore.replacingBody(inFile: "", with: "old instruction")
            .write(to: fragURL, atomically: true, encoding: .utf8)

        let config = ConfigCache(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: config)
        var notified = 0
        repo.onChange = { notified += 1 }

        var mode = Mode(id: "note", name: "Note")
        mode.aiRewrite = .init(connection: "", prompt: "x", fragments: ["tone"])
        try repo.writeMode(mode)
        #expect(config.resolved.fragmentBodies(ids: ["tone"]) == ["old instruction"])

        try FragmentStore.replacingBody(inFile: try String(contentsOf: fragURL, encoding: .utf8), with: "new instruction")
            .write(to: fragURL, atomically: true, encoding: .utf8)
        repo.recordSelfWrite(at: fragURL)

        #expect(config.resolved.fragmentBodies(ids: ["tone"]) == ["new instruction"])
        #expect(notified == 2)
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

    // A repository write records the touched file so its own echo is suppressed, but an external edit
    // still reloads.
    @Test func aRepositoryWriteRecordsIntoTheSelfWriteGate() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ConfigSelfWriteGate(baseline: ConfigTreeSnapshot.capture(supportDir: dir))
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir), selfWriteGate: gate)

        _ = try repo.mutateDictionary { $0.adding(word: "Postgres") }
        #expect(gate.shouldReload(current: ConfigTreeSnapshot.capture(supportDir: dir)) == false)

        try Data("words = [\"Postgres\", \"Redis-external-and-longer\"]\nschema_version = 1\n".utf8)
            .write(to: dir.appendingPathComponent(DictionaryStore.fileName))
        #expect(gate.shouldReload(current: ConfigTreeSnapshot.capture(supportDir: dir)) == true)
    }

    // A rename records both the created and the removed file, so neither half echoes.
    @Test func aModeRenameRecordsBothTheNewAndOldFileIntoTheGate() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        var mode = Mode(id: "old", name: "Old")
        mode.aiRewrite = .init(connection: "", prompt: "x")
        try repo.writeMode(mode)

        let gate = ConfigSelfWriteGate(baseline: ConfigTreeSnapshot.capture(supportDir: dir))
        let repo2 = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir), selfWriteGate: gate)
        try repo2.renameMode(mode, to: "new")
        #expect(gate.shouldReload(current: ConfigTreeSnapshot.capture(supportDir: dir)) == false)
    }

    @Test func mutateDictionaryRefusesMalformedExistingFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(DictionaryStore.fileName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not = [valid".utf8).write(to: file)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))

        #expect(throws: (any Error).self) {
            try repo.mutateDictionary { $0.adding(word: "Redis") }
        }
        #expect((try String(contentsOf: file, encoding: .utf8)) == "not = [valid")
    }

    @Test func addDictionaryWordReturnsFalseWhenFileMalformed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(DictionaryStore.fileName)
        try Data("not = [valid".utf8).write(to: file)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))

        #expect(repo.addDictionaryWord("Redis") == false)
        #expect((try String(contentsOf: file, encoding: .utf8)) == "not = [valid")
    }

    @Test func addReplacementReturnsFalseWhenFileMalformed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(ReplacementsStore.fileName)
        try Data("[[rules]\nheard = \"x".utf8).write(to: file)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))

        #expect(repo.addReplacement(heard: "teh", replace: "the") == false)
    }

    @Test func addDictionaryWordReturnsTrueOnSuccess() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))

        #expect(repo.addDictionaryWord("Redis") == true)
        #expect(DictionaryStore.loadOrDefault(supportDir: dir).words.contains("Redis"))
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

    // Connection writes must read-modify-write from disk, not clobber a whole caller-supplied set: a
    // connection another surface added must survive a subsequent delete of an unrelated connection.
    @Test func deletingAConnectionPreservesOneAddedConcurrentlyOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ConnectionStore.write(ConnectionSet(connections: [
            Connection(id: "a", name: "A", provider: .gemini, model: "m", keyRef: "ka"),
            Connection(id: "b", name: "B", provider: .gemini, model: "m", keyRef: "kb"),
        ]), to: dir)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))

        try repo.upsertConnection(Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "kc"))
        let after = try repo.deleteConnection(id: "a")  // must read fresh from disk, not a stale in-memory set

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

    @Test func upsertConnectionRefusesNewerSchemaExistingFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(ConnectionStore.fileName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("schema_version = 99\n".utf8).write(to: file)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))

        #expect(throws: (any Error).self) {
            try repo.upsertConnection(Connection(id: "a", name: "A", provider: .gemini, model: "m", keyRef: "ka"))
        }
        #expect((try String(contentsOf: file, encoding: .utf8)) == "schema_version = 99\n")
    }

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

    @Test func renameModeRejectsExistingDestination() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        var old = Mode(id: "old", name: "Old")
        old.aiRewrite = .init(connection: "", prompt: "x")
        var existing = Mode(id: "new", name: "Existing")
        existing.aiRewrite = .init(connection: "", prompt: "x")
        try repo.writeMode(old)
        try repo.writeMode(existing)

        #expect(throws: (any Error).self) { try repo.renameMode(old, to: "new") }

        let ids = ModeStore.loadAll(in: repo.modesDir).map(\.id)
        #expect(ids.contains("old"))
        #expect(ids.contains("new"))
        #expect(ModeStore.loadAll(in: repo.modesDir).first { $0.id == "new" }?.name == "Existing")
    }

    @Test func renameModeKeepsNewFileWhenOldFileWasAlreadyGone() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        var old = Mode(id: "old", name: "Old")
        old.aiRewrite = .init(connection: "", prompt: "x")

        try repo.renameMode(old, to: "new")

        let ids = ModeStore.loadAll(in: repo.modesDir).map(\.id)
        #expect(ids == ["new"])
    }
}
