import Foundation
import Testing
@testable import KeyScribeKit

struct ConfigEncodeTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-encode-\(UUID().uuidString)")
    }

    private func contents(_ dir: URL, _ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func everyWrittenConfigFileEndsWithANewlineSoAnAppendedTableStartsOnItsOwnLine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ModeStore.write(Mode(id: "notes", name: "Notes"), to: dir)
        try SettingsStore.write(.defaults, to: dir)
        try ConnectionStore.write(ConnectionSet(), to: dir)
        try DictionaryStore.write(DictionarySet(words: ["Postgres"]), to: dir)
        try ReplacementsStore.write(ReplacementsSet(), to: dir)

        for name in ["notes.toml", SettingsStore.fileName, ConnectionStore.fileName,
                     DictionaryStore.fileName, ReplacementsStore.fileName] {
            let toml = try contents(dir, name)
            #expect(toml.hasSuffix("\n"), "\(name) has no trailing newline")
            #expect(!toml.hasSuffix("\n\n"), "\(name) has a doubled trailing newline")
        }
    }

    @Test func aRuleAppendedWithShellRedirectStillDecodes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var mode = Mode(id: "notes", name: "Notes")
        mode.replacements.rules = [.init(heard: "recieve", replace: "receive", regex: false)]
        try ModeStore.write(mode, to: dir)
        let url = dir.appendingPathComponent("notes.toml")
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("[[replacements.rules]]\nheard = \"teh\"\nreplace = \"the\"\n".utf8))
        try handle.close()

        let decoded = try ModeStore.decode(from: String(contentsOf: url, encoding: .utf8), id: "notes")
        #expect(decoded.replacements.rules.map(\.heard) == ["recieve", "teh"])
    }
}

struct ConfigLoadFailureMessageTests {
    @Test func aMalformedModeFileReportsItsLineInPlainWords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-failmsg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "schema_version = 1\nname = 'Notes'\nbroken = 'it''s'\n"
            .write(to: dir.appendingPathComponent("notes.toml"), atomically: true, encoding: .utf8)

        let failure = try #require(ModeStore.load(in: dir, previous: []).failures.first)

        #expect(failure.message.contains("line 3"))
        #expect(!failure.message.contains("invalid("))
    }

    @Test func schemaErrorsReadAsSentences() {
        #expect(ConfigError.missingSchemaVersion.summary == "missing schema_version")
        #expect(ConfigError.newerSchemaVersion(found: 3, supported: 1).summary
            == "schema 3 is newer than this build supports (1)")
        #expect(ConfigError.invalid("bad").summary == "bad")
    }
}

struct SettingsWriteGuardTests {
    @Test func aSettingsFileThatFailsToLoadIsNeverReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-settings-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(SettingsStore.fileName)
        let broken = "schema_version = 1\n[during_dictation\nsounds = false\n"
        try broken.write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) { try SettingsStore.write(.defaults, to: dir) }
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    }

    @Test func aReadableOrAbsentSettingsFileIsWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-settings-guard-ok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try SettingsStore.write(.defaults, to: dir)
        var changed = Settings.defaults
        changed.duringDictation.sounds = !changed.duringDictation.sounds
        try SettingsStore.write(changed, to: dir)
        #expect(try SettingsStore.loadOrCreate(supportDir: dir) == changed)
    }
}

struct ConfigReadFailureTests {
    @Test func aFileThatCannotBeReadIsReportedAsUnreadableNotInvalid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let notText = Data([0xFF, 0xFE, 0x00, 0xC3])
        try notText.write(to: dir.appendingPathComponent(ReplacementsStore.fileName))
        try notText.write(to: dir.appendingPathComponent("modes/notes.toml"))
        try notText.write(to: dir.appendingPathComponent(SettingsStore.fileName))

        guard case .failed(.unreadableFile) = ReplacementsStore.load(supportDir: dir) else {
            Issue.record("replacements read failure was not unreadableFile"); return
        }
        let modeFailure = try #require(ModeStore.load(in: dir.appendingPathComponent("modes"), previous: []).failures.first)
        guard case .unreadableFile = modeFailure.error else {
            Issue.record("mode read failure was \(modeFailure.error)"); return
        }
        #expect(throws: ConfigError.self) { try SettingsStore.loadOrCreate(supportDir: dir) }
        do { _ = try SettingsStore.loadOrCreate(supportDir: dir) } catch let error as ConfigError {
            guard case .unreadableFile = error else { Issue.record("settings read failure was \(error)"); return }
        }
    }
}
