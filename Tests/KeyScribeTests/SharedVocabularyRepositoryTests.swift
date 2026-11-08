import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct SharedVocabularyRepositoryTests {
    private func makeSupport() throws -> (ConfigRepository, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-shared-repo-\(UUID().uuidString)", isDirectory: true)
        let modesDir = support.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try ModeStore.write(Mode(id: "code", name: "Code"), to: modesDir)
        try ModeStore.write(Mode(id: "docs", name: "Docs"), to: modesDir)
        try ModeStore.write(.direct, to: modesDir)
        return (ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)), support)
    }

    private func modes(_ support: URL) -> [String: Mode] {
        Dictionary(uniqueKeysWithValues: ModeStore.loadAll(in: support.appendingPathComponent("modes")).map { ($0.id, $0) })
    }

    @Test func aNewVocabularyStartsEmptyAndUsedByNoMode() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let created = try repository.createSharedVocabulary(named: " Programming ")
        #expect(created == SharedVocabulary(id: "programming", name: "Programming"))
        #expect(repository.sharedVocabularies() == [created])
        #expect(modes(support).values.allSatisfy { $0.sharedVocabularies.isEmpty })
        #expect(throws: ConfigRepository.NameProblem.self) { try repository.createSharedVocabulary(named: "programming") }
    }

    @Test func choosingModesAddsAndRemovesOnlyThatVocabularyAndNeverPlainDictation() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let programming = try repository.createSharedVocabulary(named: "Programming")
        let medical = try repository.createSharedVocabulary(named: "Medical")
        try repository.setSharedVocabulary(id: medical.id, usedBy: ["code"])
        try repository.setSharedVocabulary(id: programming.id, usedBy: ["code", "docs", Mode.directId])
        #expect(modes(support)["code"]?.sharedVocabularies == ["medical", "programming"])
        #expect(modes(support)["docs"]?.sharedVocabularies == ["programming"])
        #expect(modes(support)[Mode.directId]?.sharedVocabularies == [])
        try repository.setSharedVocabulary(id: programming.id, usedBy: ["docs"])
        #expect(modes(support)["code"]?.sharedVocabularies == ["medical"])
        #expect(repository.sharedVocabularies().count == 2)
    }

    @Test func wordsAndReplacementsSaveToTheSharedVocabularyAndEveryModeUsingItDictatesWithThem() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let programming = try repository.createSharedVocabulary(named: "Programming")
        try repository.setSharedVocabulary(id: programming.id, usedBy: ["code", "docs"])
        #expect(repository.addDictionaryWord("Kubernetes", to: .shared(programming.id)) == .saved)
        #expect(repository.addReplacement(heard: "pain", replace: "pane", to: .shared(programming.id)) == .saved)

        let plan = ConfigCache(supportDir: support).resolved
        for id in ["code", "docs"] {
            let mode = try #require(plan.modes.first { $0.id == id })
            #expect(plan.mergedDictionary(for: mode).contains("Kubernetes"))
            #expect(Pipeline(plan.postSTTTextStages(for: mode)).forward("a pain").text == "a pane")
        }
        #expect(Pipeline(plan.postSTTTextStages(for: nil)).forward("a pain").text == "a pain")
    }

    @Test func renamingKeepsEveryModesConnection() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let programming = try repository.createSharedVocabulary(named: "Programming")
        try repository.setSharedVocabulary(id: programming.id, usedBy: ["code"])
        try repository.renameSharedVocabulary(id: programming.id, to: "Software")
        #expect(repository.sharedVocabularies().map(\.name) == ["Software"])
        #expect(modes(support)["code"]?.sharedVocabularies == ["programming"])
    }

    @Test func deletingStopsEveryModeUsingItAndANewOneNeverInheritsItsPlace() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let programming = try repository.createSharedVocabulary(named: "Programming")
        try repository.setSharedVocabulary(id: programming.id, usedBy: ["code", "docs"])
        try repository.deleteSharedVocabulary(id: programming.id)
        #expect(repository.sharedVocabularies().isEmpty)
        #expect(modes(support).values.allSatisfy { $0.sharedVocabularies.isEmpty })
    }

    @Test func aNewVocabularyNeverTakesAnIdAModeStillLists() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var code = Mode(id: "code", name: "Code")
        code.sharedVocabularies = ["programming"]
        try ModeStore.write(code, to: support.appendingPathComponent("modes"))
        #expect(try repository.createSharedVocabulary(named: "Programming").id == "programming-2")
    }

    @Test func theCorrectionCheckCountsWhatAModeGetsFromASharedVocabulary() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let programming = try repository.createSharedVocabulary(named: "Programming")
        try repository.mutateSharedVocabulary(id: programming.id) { $0.words = ["Kubernetes"] }
        try repository.setSharedVocabulary(id: programming.id, usedBy: ["code"])
        #expect(VocabularyAdvisor.analyze(.word("Kubernetes"), in: repository.vocabularyScope(for: .mode("code"))).action
            == .noChange(.wordCoveredByShared("Programming")))
        #expect(VocabularyAdvisor.analyze(.word("Kubernetes"), in: repository.vocabularyScope(for: .shared(programming.id)))
            .action == .noChange(.wordAlreadyListed))
        #expect(VocabularyAdvisor.analyze(.word("Kubernetes"), in: repository.vocabularyScope(for: .global)).action
            == .addWord)
    }

    @Test func movingAModesReplacementPutsItInTheVocabularyAndTheModeStartsUsingIt() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let pain = ReplacementsSet.Rule(heard: "pain", replace: "pane", regex: false)
        try repository.mutateMode(id: "code") { $0.replacements.rules = [pain] }
        let programming = try repository.createSharedVocabulary(named: "Programming")
        let kube = ReplacementsSet.Rule(heard: "kube", replace: "kubectl", regex: false)
        try repository.moveToSharedVocabulary(
            .rule(pain), fromMode: "code", to: programming.id, settlements: ["code": .init(rules: [kube], words: [])])
        #expect(repository.sharedVocabularies().first?.rules == [pain])
        #expect(modes(support)["code"]?.replacements.rules == [kube])
        #expect(modes(support)["code"]?.sharedVocabularies == ["programming"])
    }

    @Test func aMoveThatWouldOverwriteADifferentEntryWritesNothing() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try repository.mutateMode(id: "code") { $0.dictionary.words = ["Kubernetes"] }
        let programming = try repository.createSharedVocabulary(named: "Programming")
        try repository.mutateSharedVocabulary(id: programming.id) { $0.words = ["kubernetes"] }
        #expect(throws: ConfigRepository.MoveConflict.self) {
            try repository.moveToSharedVocabulary(.word("Kubernetes"), fromMode: "code", to: programming.id, settlements: [:])
        }
        #expect(modes(support)["code"]?.dictionary.words == ["Kubernetes"])
        #expect(modes(support)["code"]?.sharedVocabularies == [])
        #expect(repository.sharedVocabularies().first?.words == ["kubernetes"])
    }
}
