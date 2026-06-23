import Foundation
import Testing
@testable import KeyScribeKit

struct ModeStoreSeedTests {
    @Test func starterSetMatchesCatalog() {
        let starters = ModeStore.starterModes()
        #expect(starters.map(\.id) == [
            "plain-dictation", "polished-dictation", "message", "email", "prompt", "work-on-selection",
            "markdown", "shell",
        ])

        // Markdown and Shell ship disabled as examples; the resolver ignores them until enabled.
        #expect(starters.filter { !$0.enabled }.map(\.id) == ["markdown", "shell"])
        #expect(starters.filter { $0.id == "markdown" || $0.id == "shell" }.allSatisfy { !$0.enabled })
        #expect(starters.filter { $0.id != "markdown" && $0.id != "shell" }.allSatisfy { $0.enabled })
        let plain = starters[0]
        #expect(plain.commands.liveEdits)                       // plain has live edits
        #expect(plain.aiRewrite == nil)                         // plain is local-only
        #expect(plain.triggerKeys == [.init(key: "fn")])

        let selection = starters.first { $0.id == "work-on-selection" }
        #expect(selection?.source == .selection)
        #expect(selection?.output == .replaceSelection)

        // Only the default mode owns a trigger key; the rest are picked from the menu.
        #expect(starters.filter { !$0.triggerKeys.isEmpty }.map(\.id) == ["plain-dictation"])

        // Every non-default mode carries an inert (empty-connection) rewrite with a non-empty prompt.
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
            "plain-dictation", "polished-dictation", "message", "email", "prompt", "work-on-selection",
            "markdown", "shell",
        ])
        #expect(loaded.first { $0.id == "work-on-selection" }?.source == .selection)
        #expect(loaded.first { $0.id == "email" }?.aiRewrite?.prompt.contains("professional email") == true)
        #expect(loaded.first { $0.id == "shell" }?.enabled == false)
        #expect(loaded.first { $0.id == "markdown" }?.enabled == false)

        // Seeding again is a no-op (does not clobber existing files).
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

    @Test func newIDNormalizesNamesAndAvoidsExistingIDs() {
        #expect(ModeStore.newID(for: "  Work on Notes! ", existing: []) == "work-on-notes")
        #expect(ModeStore.newID(for: "Work on Notes", existing: ["work-on-notes"]) == "work-on-notes-2")
    }
}
