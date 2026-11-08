import Foundation
import KeyScribeKit

// The shared vocabularies Settings lists and edits. Every change re-reads its file and writes it back
// through ConfigRepository, so an outside edit is never lost.
@MainActor
final class SharedVocabulariesModel: ObservableObject {
    enum CreateResult: Equatable {
        case created(String)
        case problem(String)
    }

    @Published private(set) var vocabularies: [SharedVocabulary] = []
    @Published private(set) var notice: PaneNotice?
    private let repository: ConfigRepository

    init(repository: ConfigRepository) {
        self.repository = repository
        reload()
    }

    func reload() {
        vocabularies = repository.sharedVocabularies()
    }

    func vocabulary(_ id: String) -> SharedVocabulary? { vocabularies.first { $0.id == id } }

    func nameProblem(_ name: String, renaming id: String? = nil) -> String? {
        SharedVocabularyStore.nameProblem(name, among: vocabularies, renaming: id)
    }

    func create(named name: String) -> CreateResult {
        do {
            let created = try repository.createSharedVocabulary(named: name)
            finish()
            return .created(created.id)
        } catch let problem as ConfigRepository.NameProblem {
            return .problem(problem.message)
        } catch {
            notice = PaneNotice(title: "Shared vocabulary wasn\u{2019}t created", message: error.localizedDescription)
            return .problem(error.localizedDescription)
        }
    }

    func rename(_ id: String, to name: String) -> String? {
        do {
            try repository.renameSharedVocabulary(id: id, to: name)
            finish()
            return nil
        } catch let problem as ConfigRepository.NameProblem {
            return problem.message
        } catch {
            fail("Shared vocabulary wasn\u{2019}t renamed", error, id: id)
            return error.localizedDescription
        }
    }

    @discardableResult
    func delete(_ id: String) -> Bool {
        attempt("Shared vocabulary wasn\u{2019}t deleted", id: id) { try repository.deleteSharedVocabulary(id: id) }
    }

    // MARK: Reviews — what a change would leave each mode it reaches to settle, judged on the state after it.

    func reviewMembership(of id: String, selected: Set<String>) -> AttachmentReview {
        guard let vocabulary = vocabulary(id) else { return AttachmentReview() }
        var review = AttachmentReview()
        for mode in eligibleModes() where selected.contains(mode.id) {
            var after = mode
            after.setUsing(id, true)
            review.pending += pending(in: after, vocabularies)
            if !mode.sharedVocabularies.contains(id) { review.changes += globalChanges(vocabulary, to: after, vocabularies) }
        }
        return review
    }

    func reviewChoice(for mode: Mode, selected: Set<String>) -> AttachmentReview {
        var after = mode
        after.sharedVocabularies = order(mode, selected)
        var review = AttachmentReview(pending: pending(in: after, vocabularies))
        for vocabulary in VocabularyMerge.using(after, vocabularies) where !mode.sharedVocabularies.contains(vocabulary.id) {
            review.changes += globalChanges(vocabulary, to: after, vocabularies)
        }
        return review
    }

    func reviewEdit(of id: String, _ transform: (inout SharedVocabulary) throws -> Void) -> AttachmentReview {
        guard var vocabulary = vocabulary(id), (try? transform(&vocabulary)) != nil else { return AttachmentReview() }
        let after = vocabularies.map { $0.id == id ? vocabulary : $0 }
        return AttachmentReview(pending: eligibleModes().filter { $0.sharedVocabularies.contains(id) }.flatMap {
            pending(in: $0, after)
        })
    }

    // The destination may be one not created yet; the mode the entry leaves is reviewed as it will be after.
    func reviewMove(_ entry: SharedVocabularyMove.Entry, from mode: Mode, to target: SharedVocabulary) -> AttachmentReview {
        var vocabulary = target
        var origin = mode
        SharedVocabularyMove.apply(entry, to: &vocabulary, from: &origin)
        let after = vocabularies.filter { $0.id != target.id } + [vocabulary]
        let others = eligibleModes().filter { $0.id != mode.id && $0.sharedVocabularies.contains(target.id) }
        var review = AttachmentReview(pending: ([origin] + others).flatMap { pending(in: $0, after) })
        if !mode.sharedVocabularies.contains(target.id) {
            var moved = vocabulary
            switch entry {
            case .word(let word): moved.words.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
            case .rule(let rule): moved.rules.removeAll { $0 == rule }
            }
            review.changes = globalChanges(moved, to: origin, after)
        }
        return review
    }

    // MARK: Changes — each is one complete write, or nothing.

    func applyMembership(of id: String, selected: Set<String>, settlements: [String: PendingAttachment.Settlement]) -> PaneNotice? {
        var changes: [String: (inout Mode) -> Void] = [:]
        let loaded = Dictionary(uniqueKeysWithValues: eligibleModes().map { ($0.id, $0) })
        for modeId in Set(loaded.keys).union(selected) {
            let uses = selected.contains(modeId)
            let settlement = settlements[modeId]
            if let current = loaded[modeId], uses == current.sharedVocabularies.contains(id), settlement == nil { continue }
            changes[modeId] = { mode in
                mode.setUsing(id, uses)
                if let settlement { mode.settle(settlement) }
            }
        }
        return report("Modes weren\u{2019}t changed", id: id) { try repository.commitVocabularyChange(modes: changes) }
    }

    func applyChoice(for mode: Mode, selected: Set<String>, settlements: [String: PendingAttachment.Settlement]) -> PaneNotice? {
        let order = order(mode, selected)
        let settlement = settlements[mode.id]
        return report("Shared vocabularies weren\u{2019}t changed", id: nil) {
            try repository.commitVocabularyChange(modes: [mode.id: { current in
                current.sharedVocabularies = order
                if let settlement { current.settle(settlement) }
            }])
        }
    }

    func applyEdit(
        _ title: String, of id: String, settlements: [String: PendingAttachment.Settlement],
        _ transform: @escaping (inout SharedVocabulary) throws -> Void
    ) -> Bool {
        do {
            try repository.commitVocabularyChange(
                shared: (id, transform), modes: settlements.mapValues { settlement in { $0.settle(settlement) } })
            finish()
            return true
        } catch is SharedEdit.Stale {
            reload()
            return false
        } catch {
            reload()
            notice = Self.notice(title, error, sharedId: id, in: repository.sharedVocabularyDir)
            return false
        }
    }

    // A vocabulary created for the move is removed again if the move fails, so nothing half-done is left.
    func move(
        _ entry: SharedVocabularyMove.Entry, fromMode modeId: String, to destination: String?, newName: String,
        settlements: [String: PendingAttachment.Settlement]
    ) -> PaneNotice? {
        var id = destination
        if id == nil {
            switch create(named: newName) {
            case .created(let created): id = created
            case .problem(let problem): return PaneNotice(title: "Entry wasn\u{2019}t moved", message: problem)
            }
        }
        guard let id else { return nil }
        let failure = report("Entry wasn\u{2019}t moved", id: id) {
            try repository.moveToSharedVocabulary(entry, fromMode: modeId, to: id, settlements: settlements)
        }
        if failure != nil, destination == nil {
            try? repository.deleteSharedVocabulary(id: id)
            reload()
        }
        return failure
    }

    private func report(_ title: String, id: String?, _ work: () throws -> Void) -> PaneNotice? {
        do {
            try work()
            finish()
            return nil
        } catch {
            reload()
            return Self.notice(title, error, sharedId: id, in: repository.sharedVocabularyDir)
        }
    }

    // Names the file that stopped the change and how to recover; never claims nothing changed when putting
    // a change back failed.
    static func notice(_ title: String, _ error: Error, sharedId: String?, in directory: URL) -> PaneNotice {
        switch error {
        case let failure as ConfigRepository.VocabularyFileFailure:
            return .failure(
                title, error: failure.underlying, file: failure.file, relativePath: failure.relativePath,
                stillRunning: "Nothing was changed.")
        case let incomplete as ConfigRepository.IncompleteRestore:
            return PaneNotice(
                title: "Only part of the change was saved",
                message: "\(ListFormatter.localizedString(byJoining: incomplete.unrestored)) couldn\u{2019}t be put back: \(incomplete.underlying.localizedDescription). Check them before trying again.")
        case let unreadable as ConfigRepository.UnreadableModeFile:
            let relativePath = "modes/\(unreadable.fileName)"
            return .failure(
                title, error: unreadable.error, file: directory.deletingLastPathComponent().appendingPathComponent(relativePath),
                relativePath: relativePath, stillRunning: "Nothing was changed.")
        case is ConfigRepository.Disagreement, is ConfigRepository.MoveConflict, is ConfigRepository.NameProblem:
            return PaneNotice(title: title, message: error.localizedDescription)
        default:
            guard let sharedId else { return PaneNotice(title: title, message: error.localizedDescription) }
            return .failure(
                title, error: error, file: SharedVocabularyStore.fileURL(id: sharedId, in: directory),
                relativePath: "\(SharedVocabularyStore.directoryName)/\(sharedId).toml", stillRunning: nil)
        }
    }

    private func eligibleModes() -> [Mode] {
        repository.resolved.modes.filter(\.hasOwnVocabulary)
    }

    private func order(_ mode: Mode, _ selected: Set<String>) -> [String] {
        mode.sharedVocabularies.filter(selected.contains)
            + vocabularies.map(\.id).filter { selected.contains($0) && !mode.sharedVocabularies.contains($0) }
    }

    private func pending(in mode: Mode, _ vocabularies: [SharedVocabulary]) -> [PendingAttachment] {
        SharedVocabularyConflicts.competitions(in: mode, shared: vocabularies).map { PendingAttachment(mode: mode, competition: $0) }
    }

    private func globalChanges(_ vocabulary: SharedVocabulary, to mode: Mode, _ vocabularies: [SharedVocabulary])
        -> [AttachmentReview.Change] {
        SharedVocabularyConflicts.globalChanges(
            attaching: vocabulary, to: mode, shared: vocabularies,
            global: repository.resolved.replacements, globalWords: repository.resolved.dictionary.words
        ).map { AttachmentReview.Change(modeName: mode.name, vocabularyName: vocabulary.name, change: $0) }
    }

    func removeWord(_ word: String, from id: String) {
        mutate("Word wasn\u{2019}t removed", id) { $0.words.removeAll { $0 == word } }
    }

    func moveRules(_ source: IndexSet, to destination: Int, in id: String) {
        mutate("Replacements weren\u{2019}t reordered", id) { vocabulary in
            guard ReplacementMoveValidation.isValid(source: source, destination: destination, count: vocabulary.rules.count)
            else { return }
            vocabulary.rules.move(fromOffsets: source, toOffset: destination)
        }
    }

    func removeRule(at index: Int, from id: String) {
        mutate("Replacement wasn\u{2019}t removed", id) { vocabulary in
            guard vocabulary.rules.indices.contains(index) else { return }
            vocabulary.rules.remove(at: index)
        }
    }

    @discardableResult
    private func mutate(_ title: String, _ id: String, _ transform: (inout SharedVocabulary) -> Void) -> Bool {
        attempt(title, id: id) { try repository.mutateSharedVocabulary(id: id, transform) }
    }

    private func attempt(_ title: String, id: String, _ work: () throws -> Void) -> Bool {
        do {
            try work()
            finish()
            return true
        } catch {
            fail(title, error, id: id)
            return false
        }
    }

    private func finish() {
        notice = nil
        reload()
    }

    private func fail(_ title: String, _ error: Error, id: String) {
        notice = Self.notice(title, error, sharedId: id, in: repository.sharedVocabularyDir)
    }
}
