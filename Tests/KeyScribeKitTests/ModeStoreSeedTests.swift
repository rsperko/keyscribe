import Foundation
import Testing
@testable import KeyScribeKit

struct ModeStoreSeedTests {
    @Test func starterSetMatchesCatalog() {
        let starters = ModeStore.starterModes()
        #expect(starters.map(\.id) == [
            "polish", "message", "email", "edit-selection", "ai-prompt", "code",
            "markdown", "shell",
        ])

        // Plain Dictation is no longer a starter — the Direct floor fills that role; all starters ship
        // disabled. Polish and Edit Selection carry a default trigger key so a first AI connection makes
        // them reachable; Email carries a voice-routing phrase; the rest stay triggerless.
        #expect(starters.allSatisfy { !$0.enabled })

        let polish = starters.first { $0.id == "polish" }
        #expect(polish?.name == "Polish")
        #expect(polish?.triggerKeys == [.init(key: "right_option")])

        let email = starters.first { $0.id == "email" }
        #expect(email?.triggerPhrases == ["as an email"])
        #expect(email?.triggerKeys.isEmpty == true)

        let selection = starters.first { $0.id == "edit-selection" }
        #expect(selection?.name == "Edit Selection")
        #expect(selection?.triggerKeys == [.init(key: "right_command")])

        let triggerless = starters.filter { !["polish", "edit-selection"].contains($0.id) }
        #expect(triggerless.allSatisfy { $0.triggerKeys.isEmpty })
        #expect(selection?.source == .selection)
        #expect(selection?.output == .replaceSelection)
        #expect(selection?.trailing == Mode.Trailing.none)

        for mode in starters where mode.source == .dictation && mode.id != "shell" {
            #expect(mode.trailing == .space)
        }
        let shell = starters.first { $0.id == "shell" }
        #expect(shell?.trailing == Mode.Trailing.none)

        for mode in starters {
            #expect(mode.aiRewrite != nil)
            #expect(mode.aiRewrite?.connection == "")
            let promptLength = mode.aiRewrite?.prompt.count ?? 0
            #expect(promptLength > 0)
        }
    }

    @Test func seedThenLoadRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-modeseed-test")
        try? FileManager.default.removeItem(at: dir)

        ModeStore.seedStartersIfEmpty(in: dir)
        let loaded = ModeStore.loadAll(in: dir)
        #expect(Set(loaded.map(\.id)) == [
            "polish", "message", "email", "edit-selection", "ai-prompt", "code",
            "markdown", "shell",
        ])
        #expect(loaded.first { $0.id == "edit-selection" }?.source == .selection)
        #expect(loaded.first { $0.id == "email" }?.aiRewrite?.prompt.contains("professional email") == true)
        #expect(loaded.first { $0.id == "ai-prompt" }?.enabled == false)
        #expect(loaded.first { $0.id == "code" }?.enabled == false)
        #expect(loaded.first { $0.id == "shell" }?.enabled == false)
        #expect(loaded.first { $0.id == "markdown" }?.enabled == false)

        ModeStore.seedStartersIfEmpty(in: dir)
        #expect(ModeStore.loadAll(in: dir).count == 8)

        try? FileManager.default.removeItem(at: dir)
    }

    @Test func loadAllOnMissingDirIsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-nope-xyz")
        #expect(ModeStore.loadAll(in: missing).isEmpty)
    }

    @Test func writeThenDeletePersistsOneMode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-mode-write-test")
        try? FileManager.default.removeItem(at: dir)
        let mode = Mode(id: "notes", name: "Notes")

        try ModeStore.write(mode, to: dir)
        #expect(ModeStore.loadAll(in: dir) == [mode])

        try ModeStore.delete(mode, from: dir)
        #expect(ModeStore.loadAll(in: dir).isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func ensureSystemModesSeedsDirectAndIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-system-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        ModeStore.ensureSystemModes(in: dir)
        let loaded = ModeStore.loadAll(in: dir)
        let direct = try #require(loaded.first { $0.id == Mode.directId })
        #expect(direct.name == "Plain Dictation")
        #expect(direct.isSystem)
        #expect(direct.aiRewrite == nil)
        #expect(!direct.excludeFromHistory)                  // records per global setting by default
        #expect(direct.triggerKeys == [.init(key: "fn")])    // fresh install: Fn is free → Direct takes it

        ModeStore.ensureSystemModes(in: dir)
        #expect(ModeStore.loadAll(in: dir).filter { $0.id == Mode.directId }.count == 1)
    }

    @Test func systemModeKeepsEditableTriggerButReNormalizesLockedFieldsOnLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-system-tamper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        // A hand-edited Direct file that sets editable fields AND tries to weaken the locked ones.
        var tampered = Mode.direct
        tampered.triggerKeys = [.init(key: "right_option")]   // editable — must survive
        tampered.insertion = .type                            // editable — must survive
        tampered.excludeFromHistory = true                   // editable — must survive
        tampered.aiRewrite = Mode.AIRewrite(connection: "x", prompt: "leak")  // locked — must be stripped
        tampered.source = .selection                         // locked — must be forced back
        try ModeStore.write(tampered, to: dir)

        let direct = try #require(ModeStore.loadAll(in: dir).first { $0.id == Mode.directId })
        #expect(direct.triggerKeys == [.init(key: "right_option")])
        #expect(direct.insertion == .type)
        #expect(direct.excludeFromHistory)                   // editable, preserved
        #expect(direct.aiRewrite == nil)
        #expect(direct.source == .dictation)
    }

    @Test func ensureSystemModesHealsATamperedDirectFileOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-system-heal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var tampered = Mode.direct
        tampered.triggerKeys = [.init(key: "right_option")]   // editable — must survive
        tampered.aiRewrite = Mode.AIRewrite(connection: "x", prompt: "leak")  // locked — must be healed
        try ModeStore.write(tampered, to: dir)

        ModeStore.ensureSystemModes(in: dir)

        let toml = try String(contentsOf: dir.appendingPathComponent("\(Mode.directId).toml"), encoding: .utf8)
        let healed = try ModeStore.decode(from: toml, id: Mode.directId)
        #expect(healed.aiRewrite == nil)
        #expect(healed.triggerKeys == [.init(key: "right_option")])
    }

    @Test func ensureSystemModesLeavesAnUndecodableDirectFileUntouchedWithNoLKG() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-system-undecodable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("\(Mode.directId).toml")
        let garbage = "this is not [[[ valid toml"
        try garbage.write(to: url, atomically: true, encoding: .utf8)

        ModeStore.ensureSystemModes(in: dir)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == garbage)
    }

    @Test func ensureSystemModesRecoversAnUndecodableDirectFileFromLKG() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-system-undecodable-lkg-\(UUID().uuidString)")
        let lkgDir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-system-undecodable-lkg-store-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: lkgDir)
        }

        var lastGood = Mode.direct
        lastGood.triggerKeys = [.init(key: "right_option")]
        lastGood.excludeFromHistory = true
        try ModeStore.write(lastGood, to: lkgDir)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Mode.directId).toml")
        try "this is not [[[ valid toml".write(to: url, atomically: true, encoding: .utf8)

        ModeStore.ensureSystemModes(in: dir, lkgDir: lkgDir)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        let recovered = try ModeStore.decode(from: onDisk, id: Mode.directId)
        #expect(recovered.triggerKeys == [.init(key: "right_option")])
        #expect(recovered.excludeFromHistory)
        #expect(recovered.aiRewrite == nil)
    }

    @Test func ensureSystemModesLeavesANewerSchemaDirectFileUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-system-newer-schema-\(UUID().uuidString)")
        let lkgDir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-system-newer-schema-lkg-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: lkgDir)
        }

        var lastGood = Mode.direct
        lastGood.triggerKeys = [.init(key: "fn")]
        try ModeStore.write(lastGood, to: lkgDir)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Mode.directId).toml")
        let newerSchema = "schema_version = 5\nname = \"Plain Dictation\""
        try newerSchema.write(to: url, atomically: true, encoding: .utf8)

        ModeStore.ensureSystemModes(in: dir, lkgDir: lkgDir)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == newerSchema)
    }

    @Test func migrationRemovesStockPlainDictationAndDirectInheritsItsTrigger() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-mig-stock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var plain = ModeStore.legacyPlainDictationSeed
        plain.triggerKeys = [.init(key: "fn")]
        try ModeStore.write(plain, to: dir)

        ModeStore.ensureSystemModes(in: dir)   // first run → migration

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("plain-dictation.toml").path))
        let direct = try #require(ModeStore.loadAll(in: dir).first { $0.id == Mode.directId })
        #expect(direct.triggerKeys == [.init(key: "fn")])
    }

    @Test func migrationCarriesARemappedTriggerOntoDirect() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-mig-remap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var plain = ModeStore.legacyPlainDictationSeed   // stock shape, only the trigger moved
        plain.triggerKeys = [.init(key: "right_option")]
        try ModeStore.write(plain, to: dir)

        ModeStore.ensureSystemModes(in: dir)

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("plain-dictation.toml").path))
        let direct = try #require(ModeStore.loadAll(in: dir).first { $0.id == Mode.directId })
        #expect(direct.triggerKeys == [.init(key: "right_option")])
    }

    @Test func migrationKeepsACustomizedPlainDictationAndDirectStaysTriggerless() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-mig-custom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var custom = ModeStore.legacyPlainDictationSeed
        custom.triggerKeys = [.init(key: "fn")]
        custom.aiRewrite = Mode.AIRewrite(connection: "c", prompt: "clean it up")   // user customization
        try ModeStore.write(custom, to: dir)

        ModeStore.ensureSystemModes(in: dir)

        // The user's customized mode is never deleted; Direct does not steal its key.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("plain-dictation.toml").path))
        let direct = try #require(ModeStore.loadAll(in: dir).first { $0.id == Mode.directId })
        #expect(direct.triggerKeys.isEmpty)
    }

    @Test func deleteRefusesSystemModes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-system-del-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        ModeStore.ensureSystemModes(in: dir)
        try ModeStore.delete(.direct, from: dir)
        #expect(ModeStore.loadAll(in: dir).contains { $0.id == Mode.directId })
    }

    @Test func newIDNormalizesNamesAndAvoidsExistingIDs() {
        #expect(ModeStore.newID(for: "  Work on Notes! ", existing: []) == "work-on-notes")
        #expect(ModeStore.newID(for: "Work on Notes", existing: ["work-on-notes"]) == "work-on-notes-2")
    }
}
