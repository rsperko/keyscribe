import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct SharedVocabulariesModelTests {
    private func makeModel() throws -> (SharedVocabulariesModel, ConfigRepository, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-shared-model-\(UUID().uuidString)", isDirectory: true)
        let modesDir = support.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try ModeStore.write(Mode(id: "code", name: "Code"), to: modesDir)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        return (SharedVocabulariesModel(repository: repository), repository, support)
    }

    @Test func creatingReturnsTheNewVocabularyAndANameProblemCreatesNothing() throws {
        let (model, _, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(model.create(named: "Programming") == .created("programming"))
        #expect(model.vocabularies.map(\.name) == ["Programming"])
        #expect(model.create(named: "Global") == .problem("\u{201C}Global\u{201D} is the vocabulary every mode can use. Choose another name."))
        #expect(model.vocabularies.count == 1)
    }

    private func rule(_ heard: String, _ replace: String, alone: Bool = false) -> ReplacementsSet.Rule {
        ReplacementsSet.Rule(heard: heard, replace: replace, regex: false, wholeDictation: alone)
    }

    private func mode(_ support: URL, _ id: String) -> Mode? {
        ModeStore.loadAll(in: support.appendingPathComponent("modes")).first { $0.id == id }
    }

    private func created(_ model: SharedVocabulariesModel, _ name: String) throws -> String {
        guard case .created(let id) = model.create(named: name) else { throw CancellationError() }
        return id
    }

    @Test func entriesAndModesAreSavedAndShown() throws {
        let (model, repository, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        let id = try created(model, "Programming")
        #expect(model.applyEdit("Word wasn’t saved", of: id, settlements: [:]) { try SharedEdit.add([.word("Kubernetes")]).apply(to: &$0) })
        #expect(model.applyEdit("x", of: id, settlements: [:]) { try SharedEdit.add([.rule(self.rule("pain", "pane"))]).apply(to: &$0) })
        #expect(model.applyMembership(of: id, selected: ["code"], settlements: [:]) == nil)
        #expect(model.vocabularies.first?.words == ["Kubernetes"])
        #expect(model.vocabularies.first?.rules.map(\.heard) == ["pain"])
        #expect(ModeStore.loadAll(in: repository.modesDir).first?.sharedVocabularies == [id])
        model.removeWord("Kubernetes", from: id)
        model.removeRule(at: 0, from: id)
        #expect(model.vocabularies.first?.words == [])
        #expect(model.vocabularies.first?.rules == [])
        #expect(model.rename(id, to: "Software") == nil)
        #expect(model.vocabularies.first?.name == "Software")
        #expect(model.delete(id))
        #expect(model.vocabularies.isEmpty)
        #expect(ModeStore.loadAll(in: repository.modesDir).first?.sharedVocabularies == [])
    }

    @Test func aFailedSaveSaysSoAndKeepsWhatWasShown() throws {
        let (model, repository, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        let id = try created(model, "Programming")
        try "schema_version = 1\nname = [".write(
            to: SharedVocabularyStore.fileURL(id: id, in: repository.sharedVocabularyDir), atomically: true, encoding: .utf8)
        #expect(!model.applyEdit("Word wasn’t saved", of: id, settlements: [:]) { try SharedEdit.add([.word("Kubernetes")]).apply(to: &$0) })
        #expect(model.notice?.title == "Word wasn’t saved")
    }

    @Test func anEditThatMakesTwoVocabulariesDisagreeInAModeMustBeSettledThereWithTheWholeRule() throws {
        let (model, _, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        let programming = try created(model, "Programming")
        let medical = try created(model, "Medical")
        #expect(model.applyEdit("x", of: medical, settlements: [:]) { $0.rules = [self.rule("pain", "pain.", alone: true)] })
        #expect(model.applyChoice(for: try #require(mode(support, "code")), selected: [programming, medical], settlements: [:]) == nil)
        let edit = SharedEdit.add([.rule(rule("pain", "pane"))])
        let review = model.reviewEdit(of: programming) { try edit.apply(to: &$0) }
        let pending = try #require(review.pending.first)
        #expect(review.pending.count == 1)
        #expect(pending.mode.id == "code")
        let chosen = SharedVocabularyMove.Entry.rule(rule("pain", "pain.", alone: true))
        #expect(PendingAttachment.unsettled(review.pending, choices: [:]))
        let settlements = PendingAttachment.settlements(review.pending, choices: [pending.id: chosen])
        #expect(model.applyEdit("x", of: programming, settlements: settlements) { try edit.apply(to: &$0) })
        #expect(mode(support, "code")?.replacements.rules == [rule("pain", "pain.", alone: true)])
        #expect(model.vocabulary(programming)?.rules == [rule("pain", "pane")])
    }

    @Test func reopeningAChooserShowsADisagreementLeftUnsettled() throws {
        let (model, repository, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        let programming = try created(model, "Programming")
        let medical = try created(model, "Medical")
        try repository.mutateSharedVocabulary(id: programming) { $0.words = ["Kubernetes"] }
        try repository.mutateSharedVocabulary(id: medical) { $0.words = ["kubernetes"] }
        model.reload()
        try repository.mutateMode(id: "code") { $0.sharedVocabularies = [programming, medical] }
        let code = try #require(mode(support, "code"))
        #expect(model.reviewChoice(for: code, selected: [programming, medical]).pending.map(\.competition.key) == ["w:kubernetes"])
        #expect(model.reviewMembership(of: programming, selected: ["code"]).pending.count == 1)
    }

    @Test func aMembershipChangeThatCannotBeSavedChangesNothingAndSaysWhy() throws {
        let (model, repository, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        try ModeStore.write(Mode(id: "docs", name: "Docs"), to: repository.modesDir)
        let programming = try created(model, "Programming")
        try "schema_version = [".write(
            to: repository.modesDir.appendingPathComponent("docs.toml"), atomically: true, encoding: .utf8)
        let failure = try #require(model.applyMembership(of: programming, selected: ["code", "docs"], settlements: [:]))
        #expect(failure.title == "Modes weren’t changed")
        #expect(failure.message == "modes/docs.toml needs fixing. Nothing was changed.")
        #expect(failure.fileURL?.lastPathComponent == "docs.toml")
        #expect(failure.details?.isEmpty == false)
        #expect(mode(support, "code")?.sharedVocabularies == [])
    }

    @Test func aMoveIsCheckedInEveryModeThatUsesTheDestination() throws {
        let (model, repository, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        try ModeStore.write(Mode(id: "docs", name: "Docs"), to: repository.modesDir)
        let programming = try created(model, "Programming")
        let medical = try created(model, "Medical")
        #expect(model.applyEdit("x", of: medical, settlements: [:]) { $0.rules = [self.rule("pain", "pain.")] })
        try repository.mutateMode(id: "docs") { $0.sharedVocabularies = [programming, medical] }
        try repository.mutateMode(id: "code") { $0.replacements.rules = [self.rule("pain", "pane")] }
        let code = try #require(mode(support, "code"))
        let review = model.reviewMove(.rule(rule("pain", "pane")), from: code, to: try #require(model.vocabulary(programming)))
        #expect(review.pending.map(\.mode.id) == ["docs"])
    }

    @Test func aMoveIntoANewVocabularyThatFailsLeavesNoEmptyVocabularyBehind() throws {
        let (model, repository, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        try "schema_version = [".write(
            to: repository.modesDir.appendingPathComponent("code.toml"), atomically: true, encoding: .utf8)
        let failure = model.move(.word("Kubernetes"), fromMode: "code", to: nil, newName: "Programming", settlements: [:])
        #expect(failure != nil)
        #expect(model.vocabularies.isEmpty)
        #expect(repository.sharedVocabularies().isEmpty)
    }

    @Test func aFailedRollbackNeverClaimsNothingChanged() {
        let incomplete = ConfigRepository.IncompleteRestore(underlying: CocoaError(.fileWriteNoPermission), unrestored: ["Code"])
        let notice = SharedVocabulariesModel.notice("Modes weren’t changed", incomplete, sharedId: nil, in: URL(fileURLWithPath: "/tmp"))
        #expect(notice.title == "Only part of the change was saved")
        #expect(!notice.message.contains("Nothing was changed"))
        #expect(notice.message.hasPrefix("Code couldn’t be put back"))
    }

    @Test func editingARuleThatChangedElsewhereKeepsItAndSaysSo() throws {
        let (model, repository, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        let id = try created(model, "Programming")
        try repository.mutateSharedVocabulary(id: id) { $0.rules = [self.rule("pain", "pane")] }
        model.reload()
        try repository.mutateSharedVocabulary(id: id) { $0.rules = [self.rule("pain", "changed elsewhere")] }
        let edit = SharedEdit.update(rule("pain", "pane"), rule("pain", "panel"))
        #expect(!model.applyEdit("x", of: id, settlements: [:]) { try edit.apply(to: &$0) })
        #expect(model.notice == nil)
        #expect(model.vocabulary(id)?.rules == [rule("pain", "changed elsewhere")])
    }

    @Test func aChangeLeavingADisagreementIsRefusedWhereverItComesFrom() throws {
        let (model, repository, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        let programming = try created(model, "Programming")
        let medical = try created(model, "Medical")
        try repository.mutateSharedVocabulary(id: medical) { $0.rules = [self.rule("pain", "pain.")] }
        try repository.mutateMode(id: "code") { $0.sharedVocabularies = [programming, medical] }
        model.reload()
        #expect(!model.applyEdit("Replacement wasn’t saved", of: programming, settlements: [:]) {
            $0.rules = [self.rule("pain", "pane")]
        })
        #expect(model.notice?.message
            == "This would make Programming and Medical disagree about “pain” in Code. Add it from Settings ▸ Vocabulary ▸ Programming instead, where you can choose which one Code uses.")
        #expect(repository.addReplacement(heard: "pain", replace: "pane", to: .shared(programming))
            == .needsChoice(try #require(model.notice?.message), vocabularyId: programming))
        #expect(try repository.saveReplacementBatch(
            to: .shared(programming), expected: [], proposed: [rule("pain", "pane")], requiringWord: nil)
            == .disagreement(try #require(model.notice?.message)))
        #expect(model.vocabulary(programming)?.rules == [])
        #expect(repository.addReplacement(heard: "kube", replace: "k8s", to: .shared(programming)) == .saved)
    }
}
