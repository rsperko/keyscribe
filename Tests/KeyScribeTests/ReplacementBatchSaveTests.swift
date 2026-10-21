import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct ReplacementBatchSaveTests {
    private func repository() -> (ConfigRepository, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-batch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir)), dir)
    }

    private func rule(_ heard: String, _ replace: String = "Yugabyte") -> ReplacementsSet.Rule {
        .init(heard: heard, replace: replace, regex: false)
    }

    @Test func savesTheWholeBatchToGlobalInOneWrite() throws {
        let (repo, dir) = repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        try repo.mutateReplacements { $0 = ReplacementsSet(rules: [rule("slash resume", "/resume")]) }
        try repo.mutateDictionary { $0.adding(word: "Yugabyte") }
        var notified = 0
        repo.onChange = { notified += 1 }
        let proposed = [rule("slash resume", "/resume"), rule("Ugabyte"), rule("Yuga Bite")]
        let outcome = try repo.saveReplacementBatch(
            to: .global, expected: [rule("slash resume", "/resume")], proposed: proposed, requiringWord: "Yugabyte")
        #expect(outcome == .saved)
        #expect(repo.replacementRules() == proposed)
        #expect(repo.dictionaryWords() == ["Yugabyte"])
        #expect(notified == 1)
    }

    @Test func writesNothingWhenTheRulesChangedSinceTheReview() throws {
        let (repo, dir) = repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        try repo.mutateReplacements { $0 = ReplacementsSet(rules: [rule("added elsewhere", "x")]) }
        let outcome = try repo.saveReplacementBatch(
            to: .global, expected: [], proposed: [rule("Ugabyte")], requiringWord: nil)
        #expect(outcome == .stale(.rulesChanged))
        #expect(repo.replacementRules() == [rule("added elsewhere", "x")])
    }

    @Test func writesNothingWhenTheWordWasRemoved() throws {
        let (repo, dir) = repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = try repo.saveReplacementBatch(
            to: .global, expected: [], proposed: [rule("Ugabyte")], requiringWord: "Yugabyte")
        #expect(outcome == .stale(.wordRemoved))
        #expect(repo.replacementRules().isEmpty)
    }

    @Test func savesIntoTheModeAndLeavesGlobalAlone() throws {
        let (repo, dir) = repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        var mode = Mode(id: "notes", name: "Notes")
        mode.dictionary.words = ["Yugabyte"]
        try repo.writeMode(mode)
        let outcome = try repo.saveReplacementBatch(
            to: .mode("notes"), expected: [], proposed: [rule("Ugabyte")], requiringWord: "Yugabyte")
        #expect(outcome == .saved)
        let saved = try ModeStore.decode(
            from: String(contentsOf: repo.modesDir.appendingPathComponent("notes.toml"), encoding: .utf8), id: "notes")
        #expect(saved.replacements.rules == [rule("Ugabyte")])
        #expect(saved.dictionary.words == ["Yugabyte"])
        #expect(repo.replacementRules().isEmpty)
    }

    @Test func aMissingModeIsReportedAndNeverFallsBackToGlobal() throws {
        let (repo, dir) = repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = try repo.saveReplacementBatch(
            to: .mode("gone"), expected: [], proposed: [rule("Ugabyte")], requiringWord: nil)
        #expect(outcome == .stale(.destinationMissing))
        #expect(repo.replacementRules().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo.modesDir.appendingPathComponent("gone.toml").path))
    }
}
