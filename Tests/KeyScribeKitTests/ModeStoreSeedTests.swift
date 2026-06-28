import Foundation
import Testing
@testable import KeyScribeKit

struct ModeStoreSeedTests {
    @Test func starterSetMatchesCatalog() {
        let starters = ModeStore.starterModes()
        #expect(starters.map(\.id) == [
            "plain-dictation", "polish", "message", "email", "edit-selection", "ai-prompt", "code",
            "markdown", "shell",
        ])

        #expect(starters.filter { $0.enabled }.map(\.id) == ["plain-dictation"])
        let plain = starters[0]
        #expect(plain.commands.liveEdits)
        #expect(plain.aiRewrite == nil)
        #expect(plain.triggerKeys == [.init(key: "fn")])

        let polish = starters.first { $0.id == "polish" }
        #expect(polish?.name == "Polish")

        let selection = starters.first { $0.id == "edit-selection" }
        #expect(selection?.name == "Edit Selection")
        #expect(selection?.source == .selection)
        #expect(selection?.output == .replaceSelection)
        #expect(selection?.trailing == Mode.Trailing.none)

        for mode in starters where mode.source == .dictation && mode.id != "shell" {
            #expect(mode.trailing == .space)
        }
        let shell = starters.first { $0.id == "shell" }
        #expect(shell?.trailing == Mode.Trailing.none)

        #expect(starters.filter { !$0.triggerKeys.isEmpty }.map(\.id) == ["plain-dictation"])

        for mode in starters where mode.id != "plain-dictation" {
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
            "plain-dictation", "polish", "message", "email", "edit-selection", "ai-prompt", "code",
            "markdown", "shell",
        ])
        #expect(loaded.first { $0.id == "edit-selection" }?.source == .selection)
        #expect(loaded.first { $0.id == "email" }?.aiRewrite?.prompt.contains("professional email") == true)
        #expect(loaded.first { $0.id == "ai-prompt" }?.enabled == false)
        #expect(loaded.first { $0.id == "code" }?.enabled == false)
        #expect(loaded.first { $0.id == "shell" }?.enabled == false)
        #expect(loaded.first { $0.id == "markdown" }?.enabled == false)

        ModeStore.seedStartersIfEmpty(in: dir)
        #expect(ModeStore.loadAll(in: dir).count == 9)

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

    @Test func newIDNormalizesNamesAndAvoidsExistingIDs() {
        #expect(ModeStore.newID(for: "  Work on Notes! ", existing: []) == "work-on-notes")
        #expect(ModeStore.newID(for: "Work on Notes", existing: ["work-on-notes"]) == "work-on-notes-2")
    }
}
