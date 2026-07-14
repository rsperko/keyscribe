import Foundation
import AppKit
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

    @Test func replacementDropRejectsBoundariesThatWouldNotMoveTheRule() {
        #expect(!ReplacementDropValidation.isValid(source: 0, proposedRow: 0))
        #expect(!ReplacementDropValidation.isValid(source: 0, proposedRow: 1))
        #expect(ReplacementDropValidation.isValid(source: 0, proposedRow: 2))
        #expect(ReplacementDropValidation.isValid(source: 2, proposedRow: 1))
        #expect(!ReplacementDropValidation.isValid(source: 2, proposedRow: 2))
        #expect(!ReplacementDropValidation.isValid(source: 2, proposedRow: 3))
    }

    @Test func replacementMoveRejectsStaleIndicesAndInvalidDestinations() {
        #expect(ReplacementMoveValidation.isValid(source: IndexSet(integer: 1), destination: 0, count: 2))
        #expect(!ReplacementMoveValidation.isValid(source: IndexSet(integer: 2), destination: 0, count: 2))
        #expect(!ReplacementMoveValidation.isValid(source: IndexSet(integer: 0), destination: 3, count: 2))
        #expect(!ReplacementMoveValidation.isValid(source: [], destination: 0, count: 2))
    }

    @Test func replacementTableLayoutInvalidatesWhenItsWidthChanges() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 100))
        var invalidationCount = 0
        let observer = ReplacementTableFrameObserver(view: view) {
            invalidationCount += 1
        }

        view.setFrameSize(NSSize(width: 300, height: 100))
        #expect(invalidationCount == 1)

        view.setFrameSize(NSSize(width: 300, height: 200))
        #expect(invalidationCount == 1)
        _ = observer
    }

    @Test func vocabularyRemovalConfirmationNamesTheEntryAndScope() {
        #expect(VocabularyRemovalCopy.dictionary("Kubernetes", scope: .global).title
            == "Remove “Kubernetes” from Words to Recognize?")
        #expect(VocabularyRemovalCopy.dictionary("Kubernetes", scope: .mode).message
            == "This mode-only word will be removed. This cannot be undone.")
        #expect(VocabularyRemovalCopy.replacement("code fence", scope: .global).title
            == "Delete the replacement for “code fence”?")
        #expect(VocabularyRemovalCopy.replacement("code fence", scope: .mode).message
            == "This mode-only replacement will be removed. This cannot be undone.")
    }

    // Removing a DIFFERENT word in the pane must not resurrect the pane's stale in-memory list and drop
    // a term the global Add-to-Vocabulary hotkey wrote concurrently through ConfigRepository.
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

    @Test func replacementEditPreservesARuleAddedConcurrentlyOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = ReplacementsSet.Rule(heard: "teh", replace: "the", regex: false)
        try ReplacementsStore.write(ReplacementsSet(rules: [original]), to: dir)

        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let model = ReplacementsSettingsModel(repository: repo)
        repo.addReplacement(heard: "recieve", replace: "receive")

        model.update(original, to: .init(heard: "teh", replace: "The", regex: false))

        let onDisk = ReplacementsStore.loadOrDefault(supportDir: dir).rules
        #expect(onDisk == [
            .init(heard: "teh", replace: "The", regex: false),
            .init(heard: "recieve", replace: "receive", regex: false),
        ])
    }

    @Test func replacementEditReportsWhenTheOriginalVanishedFromDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = ReplacementsSet.Rule(heard: "teh", replace: "the", regex: false)
        try ReplacementsStore.write(ReplacementsSet(rules: [original]), to: dir)

        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let model = ReplacementsSettingsModel(repository: repo)
        try ReplacementsStore.write(ReplacementsSet(), to: dir)

        let updated = model.update(original, to: .init(heard: "teh", replace: "The", regex: false))

        #expect(!updated)
        #expect(ReplacementsStore.loadOrDefault(supportDir: dir).rules.isEmpty)
    }

    @Test func replacementReorderPreservesARuleAddedConcurrentlyOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = ReplacementsSet.Rule(heard: "first", replace: "1", regex: false)
        let second = ReplacementsSet.Rule(heard: "second", replace: "2", regex: false)
        try ReplacementsStore.write(ReplacementsSet(rules: [first, second]), to: dir)

        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let model = ReplacementsSettingsModel(repository: repo)
        repo.addReplacement(heard: "added", replace: "3")

        model.move(from: IndexSet(integer: 1), to: 0)

        let onDisk = ReplacementsStore.loadOrDefault(supportDir: dir).rules
        #expect(onDisk == [second, first, .init(heard: "added", replace: "3", regex: false)])
    }

    @Test func replacementReorderIgnoresAStaleDragIndex() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = ReplacementsSet.Rule(heard: "first", replace: "1", regex: false)
        let second = ReplacementsSet.Rule(heard: "second", replace: "2", regex: false)
        try ReplacementsStore.write(ReplacementsSet(rules: [first, second]), to: dir)

        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let model = ReplacementsSettingsModel(repository: repo)

        model.move(from: IndexSet(integer: 2), to: 0)

        #expect(ReplacementsStore.loadOrDefault(supportDir: dir).rules == [first, second])
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

    // A subsequent editor control toggle full-file-writes the whole mode, and must not resurrect the
    // pane's stale draft and drop a term the Add-to-Vocabulary hotkey routed in concurrently.
    @Test func modeEditorControlEditPreservesAVocabTermAddedConcurrentlyOnDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        var mode = Mode(id: "code", name: "Code")
        mode.trailing = .space
        try ModeStore.write(mode, to: repo.modesDir)

        let model = ModesSettingsModel(repository: repo)   // snapshots "code" with no vocabulary
        model.selectedID = "code"

        #expect(repo.addDictionaryWord("kubectl", toMode: "code"))   // disk now has the term

        var edited = try #require(model.selected)                    // build from the (refreshed) draft
        edited.trailing = .newline
        model.update(edited)                                         // full-file save of the whole mode

        let onDisk = try ModeStore.decode(
            from: String(contentsOf: repo.modesDir.appendingPathComponent("code.toml"), encoding: .utf8),
            id: "code")
        #expect(onDisk.dictionary.words == ["kubectl"])
        #expect(onDisk.trailing == .newline)
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

    // Mirrors the FSEvents reload path (AppDelegate.reloadConfig calls notifyExternalChange) for an
    // edit made outside the app while the Vocabulary pane is open.
    @Test func externalEditNotificationRefreshesPaneModels() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DictionaryStore.write(DictionarySet(words: ["Postgres"]), to: dir)
        try ReplacementsStore.write(
            ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: false)]), to: dir)

        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let dictionary = DictionarySettingsModel(repository: repo)
        let replacements = ReplacementsSettingsModel(repository: repo)

        try DictionaryStore.write(DictionarySet(words: ["Postgres", "Redis"]), to: dir)
        try ReplacementsStore.write(
            ReplacementsSet(rules: [.init(heard: "wont", replace: "won't", regex: false)]), to: dir)
        repo.notifyExternalChange()

        #expect(dictionary.words == ["Postgres", "Redis"])
        #expect(replacements.rules == [.init(heard: "wont", replace: "won't", regex: false)])
    }
}
