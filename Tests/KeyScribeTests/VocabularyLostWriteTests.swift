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
}
