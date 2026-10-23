import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct ConfigRepositoryTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-repo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    @Test func writingSeveralModesNotifiesOnce() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigCache(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: config)
        var notified = 0
        repo.onChange = { notified += 1 }
        try repo.writeModes([Mode(id: "a", name: "A"), Mode(id: "b", name: "B")], restoring: [])
        #expect(config.modes.contains { $0.id == "a" } && config.modes.contains { $0.id == "b" })
        #expect(notified == 1)
    }

    @Test func aFailedMultiModeWriteRestoresWhatItAlreadyWrote() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        var a = Mode(id: "a", name: "A")
        a.triggerKeys = [.init(key: "f12")]
        try repo.writeMode(a)
        var movedA = a
        movedA.triggerKeys = []
        #expect(throws: (any Error).self) {
            try repo.writeModes([movedA, Mode(id: "b", name: "B")], restoring: [a, Mode(id: "b", name: "B")]) { mode in
                guard mode.id == "a" else { throw ConfigError.invalid("disk full") }
                try ModeStore.write(mode, to: repo.modesDir)
            }
        }
        let onDisk = try ModeStore.decode(
            from: String(contentsOf: repo.modesDir.appendingPathComponent("a.toml"), encoding: .utf8), id: "a")
        #expect(onDisk.triggerKeys == a.triggerKeys)
    }

    @Test func aMultiModeWriteRefusesToReplaceAModeFileThatDoesNotLoad() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        try repo.writeMode(Mode(id: "a", name: "A"))
        let broken = "schema_version = 2\nname = \"B\"\ntrigger_keys = [\n"
        let bURL = repo.modesDir.appendingPathComponent("b.toml")
        try broken.write(to: bURL, atomically: true, encoding: .utf8)
        var movedA = Mode(id: "a", name: "A")
        movedA.triggerKeys = [.init(key: "f12")]
        #expect(throws: ConfigRepository.UnreadableModeFile.self) {
            try repo.writeModes([movedA, Mode(id: "b", name: "B")], restoring: [])
        }
        #expect(try String(contentsOf: bURL, encoding: .utf8) == broken)
        let a = try ModeStore.decode(
            from: String(contentsOf: repo.modesDir.appendingPathComponent("a.toml"), encoding: .utf8), id: "a")
        #expect(a.triggerKeys.isEmpty)
    }

    @Test func aRestoreThatAlsoFailsIsReportedAndStillRefreshesTheCache() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigCache(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: config)
        var notified = 0
        repo.onChange = { notified += 1 }
        let a = Mode(id: "a", name: "A")
        let b = Mode(id: "b", name: "B")
        var calls = 0
        do {
            try repo.writeModes([a, b], restoring: [a, b]) { mode in
                calls += 1
                if calls == 1 { try ModeStore.write(mode, to: repo.modesDir); return }
                throw ConfigError.invalid("disk full")
            }
            Issue.record("expected a failure")
        } catch let error as ConfigRepository.IncompleteRestore {
            #expect(error.unrestored == ["A"])
        }
        #expect(notified == 1)
        #expect(config.modes.contains { $0.id == "a" })
    }

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

    @Test func addingAReplacementStartsTrackingItsUseAndRemovingItDropsIt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usage = ReplacementUsageStore(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir), replacementUsage: usage)
        #expect(repo.addReplacement(heard: "teh", replace: "the"))
        usage.flush()
        #expect(usage.snapshot().rules["global|l|teh"]?.count == 0)
        _ = try repo.mutateReplacements { $0 = ReplacementsSet() }
        usage.flush()
        #expect(usage.snapshot().rules.isEmpty)
    }

    @Test func renamingAModeKeepsTheUseOfItsReplacements() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usage = ReplacementUsageStore(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir), replacementUsage: usage)
        var mode = Mode(id: "code", name: "Code")
        mode.replacements = .init(rules: [.init(heard: "teh", replace: "the", regex: false)])
        try repo.writeMode(mode)
        usage.record([ReplacementRule(heard: "teh", replace: "the", isRegex: false, origin: .mode("code"))])
        try repo.renameMode(mode, to: "coding")
        usage.flush()
        #expect(usage.snapshot().rules["mode:coding|l|teh"]?.count == 1)
        #expect(usage.snapshot().rules["mode:code|l|teh"] == nil)
    }

    private func prependUnreadKey(to file: URL) throws -> String {
        let withKey = "unread_key = 1\n" + (try String(contentsOf: file, encoding: .utf8))
        try withKey.write(to: file, atomically: true, encoding: .utf8)
        return withKey
    }

    private func dropUnreadKey(from file: URL) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        try String(text.dropFirst("unread_key = 1\n".count)).write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func everyInAppWriteRefusesToDeleteAKeyTheAppDoesNotRead() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        try DictionaryStore.write(DictionarySet(words: ["Redis"]), to: dir)
        try ReplacementsStore.write(ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: false)]), to: dir)
        try ConnectionStore.write(ConnectionSet(connections: []), to: dir)
        try VoiceCommandStore.write(VoiceCommandConfig(), to: dir)
        try repo.writeMode(Mode(id: "notes", name: "Notes"))
        let writes: [(file: String, write: () throws -> Void)] = [
            (DictionaryStore.fileName, { try repo.mutateDictionary { $0.adding(word: "Kafka") } }),
            (ReplacementsStore.fileName, { try repo.mutateReplacements { $0 = $0.adding(heard: "recieve", replace: "receive", regex: false) } }),
            (ConnectionStore.fileName, {
                try repo.upsertConnection(Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"))
            }),
            (VoiceCommandStore.fileName, { try repo.mutateVoiceCommands { $0.commands.append(.place(VoiceCommandPlace(name: "Mail", target: .url("https://mail.example.net/")))) } }),
            ("modes/notes.toml", { try repo.mutateMode(id: "notes") { $0.dictionary.words = ["Kafka"] } }),
            ("modes/notes.toml", { var mode = Mode(id: "notes", name: "Notes"); mode.enabled = false; try repo.writeMode(mode) }),
        ]
        for (relativePath, write) in writes {
            let file = dir.appendingPathComponent(relativePath)
            let withKey = try prependUnreadKey(to: file)
            #expect(throws: ConfigRepository.UnreadKeys.self, "\(relativePath)") { try write() }
            #expect(try String(contentsOf: file, encoding: .utf8) == withKey, "\(relativePath)")
            try dropUnreadKey(from: file)
            try write()
        }
    }

    @Test func aRefusedCorrectionNamesTheFileAndKey() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        try DictionaryStore.write(DictionarySet(words: ["Redis"]), to: dir)
        _ = try prependUnreadKey(to: dir.appendingPathComponent(DictionaryStore.fileName))
        guard case .refused(let message) = repo.addDictionaryWord("Kafka", to: .global) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(message.hasPrefix("dictionary.toml has “unread_key”"))
        #expect(repo.dictionaryWords() == ["Redis"])
    }

    @Test func turningVoiceCommandsOffAndOnKeepsTheUseOfItsReplacements() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usage = ReplacementUsageStore(supportDir: dir)
        let config = ConfigCache(supportDir: dir)
        config.voiceCommandsEnabled = true
        let repo = ConfigRepository(supportDir: dir, config: config, replacementUsage: usage)
        var commands = Mode.voiceCommands
        commands.replacements.rules = [.init(heard: "male", replace: "mail", regex: false)]
        try repo.writeMode(commands)
        usage.record([ReplacementRule(heard: "male", replace: "mail", isRegex: false, origin: .mode(Mode.voiceCommandsId))])
        usage.flush()
        let key = "mode:\(Mode.voiceCommandsId)|l|male"
        let tracked = try #require(usage.snapshot().rules[key])
        #expect(tracked.count == 1)

        config.voiceCommandsEnabled = false
        repo.reconcileReplacementUsage()
        usage.flush()
        #expect(usage.snapshot().rules[key] == tracked)

        let relaunched = ReplacementUsageStore(supportDir: dir)
        config.voiceCommandsEnabled = true
        ConfigRepository(supportDir: dir, config: config, replacementUsage: relaunched).reconcileReplacementUsage()
        relaunched.flush()
        #expect(relaunched.snapshot().rules[key] == tracked)
    }

    @Test func aBrokenReplacementsFileDoesNotWipeTrackedUse() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usage = ReplacementUsageStore(supportDir: dir)
        let config = ConfigCache(supportDir: dir)
        let repo = ConfigRepository(supportDir: dir, config: config, replacementUsage: usage)
        #expect(repo.addReplacement(heard: "teh", replace: "the"))
        usage.record([ReplacementRule(heard: "teh", replace: "the", isRegex: false, origin: .global)])
        try "not = [valid".write(
            to: dir.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)
        config.invalidate()
        repo.notifyExternalChange()
        usage.flush()
        #expect(usage.snapshot().rules["global|l|teh"]?.count == 1)
    }
}
