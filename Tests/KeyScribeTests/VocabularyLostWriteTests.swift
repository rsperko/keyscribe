import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct VocabularyLostWriteTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vocab-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The Vocabulary pane is open (its model holds an in-memory list). The global Add-to-Vocabulary
    // hotkey writes a new term through ConfigRepository. Removing a DIFFERENT word in the pane must not
    // resurrect the pane's stale list and drop the hotkey-added term.
    @Test func dictionaryRemovePreservesAWordAddedConcurrentlyOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DictionaryStore.write(DictionarySet(words: ["Postgres", "Kubernetes"]), to: dir)

        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let model = DictionarySettingsModel(repository: repo)  // snapshots [Postgres, Kubernetes]

        repo.addDictionaryWord("Redis")                        // disk now has the third word

        model.remove("Postgres")                               // pane removes an unrelated word

        let onDisk = Set(DictionaryStore.loadOrDefault(supportDir: dir).words)
        #expect(onDisk.contains("Redis"))
        #expect(onDisk.contains("Kubernetes"))
        #expect(!onDisk.contains("Postgres"))
    }

    @Test func replacementRemovePreservesARuleAddedConcurrentlyOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ReplacementsStore.write(
            ReplacementsSet(rules: [
                .init(heard: "teh", replace: "the", regex: false),
                .init(heard: "wont", replace: "won't", regex: false),
            ]), to: dir)

        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let model = ReplacementsSettingsModel(repository: repo)  // snapshots two rules

        repo.addReplacement(heard: "recieve", replace: "receive")

        model.remove(at: 0)                                    // pane removes the first displayed rule

        let onDisk = ReplacementsStore.loadOrDefault(supportDir: dir).rules
        #expect(onDisk.contains { $0.heard == "recieve" })
        #expect(onDisk.contains { $0.heard == "wont" })
        #expect(!onDisk.contains { $0.heard == "teh" })
    }

    @Test func modeDictionaryAddWritesOnlyToThatMode() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        var mode = Mode(id: "code", name: "Code")
        mode.dictionary.words = ["Postgres"]
        try ModeStore.write(mode, to: repo.modesDir)

        #expect(repo.addDictionaryWord("Kubernetes", toMode: "code"))

        let global = DictionaryStore.loadOrDefault(supportDir: dir)
        let updated = try ModeStore.decode(
            from: String(contentsOf: repo.modesDir.appendingPathComponent("code.toml"), encoding: .utf8),
            id: "code")
        #expect(global.words.isEmpty)
        #expect(updated.dictionary.words == ["Postgres", "Kubernetes"])
    }

    @Test func modeReplacementAddWritesOnlyToThatMode() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let mode = Mode(id: "code", name: "Code")
        try ModeStore.write(mode, to: repo.modesDir)

        #expect(repo.addReplacement(heard: "cube cuddle", replace: "kubectl", toMode: "code"))

        let global = ReplacementsStore.loadOrDefault(supportDir: dir)
        let updated = try ModeStore.decode(
            from: String(contentsOf: repo.modesDir.appendingPathComponent("code.toml"), encoding: .utf8),
            id: "code")
        #expect(global.rules.isEmpty)
        #expect(updated.replacements.rules == [.init(heard: "cube cuddle", replace: "kubectl", regex: false)])
    }
}
