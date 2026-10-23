import Foundation
import KeyScribeKit

@MainActor
final class HistoryReplacementsModel: ObservableObject, Identifiable {
    struct Phrase: Identifiable, Equatable, Sendable {
        let id: String
        var heard: String
        let discovered: Bool

        var trimmed: String { heard.trimmingCharacters(in: .whitespacesAndNewlines) }
        var isBlank: Bool { trimmed.isEmpty }
    }

    struct Vocabulary: Sendable, Equatable {
        let global: ReplacementsSet
        let globalWords: [String]
        let modes: [Mode]
    }

    struct PreviewRequest: Sendable {
        let phrases: [String]
        let replacement: String
        let destination: ReplacementPreview.Destination
        let vocabulary: Vocabulary
        let history: [HistorySnapshot.Item]
        let searched: Set<HistorySnapshot.Reference>

        func make() throws -> ReplacementPreview {
            try ReplacementPreview.make(
                phrases: phrases, replacement: replacement, destination: destination,
                global: vocabulary.global, modes: vocabulary.modes, history: history, searched: searched)
        }
    }

    private struct PreviewKey: Equatable {
        let phrases: [String]
        let replacement: String
        let vocabulary: Vocabulary
        let fingerprint: HistorySnapshot.Fingerprint
        let searched: Set<HistorySnapshot.Reference>
    }

    struct Dependencies {
        var loadSnapshot: @Sendable () throws -> HistorySnapshot
        var fingerprint: @Sendable () -> HistorySnapshot.Fingerprint
        var vocabulary: () -> Vocabulary
        var save: (ReplacementPreview.Destination, [ReplacementsSet.Rule], [ReplacementsSet.Rule], String?) throws
            -> ConfigRepository.BatchOutcome
        var now: () -> Date = Date.init
        var discover: @Sendable (_ target: String, _ texts: [String], _ dictionary: [String]) -> [AliasDiscovery.Finding] = {
            AliasDiscovery.find(target: $0, in: $1, dictionary: $2)
        }
        var makePreview: @Sendable (PreviewRequest) throws -> ReplacementPreview = { try $0.make() }
    }

    struct Excerpt: Equatable {
        let before: String
        let match: String
        let after: String
    }

    struct Problem: Equatable {
        enum Recovery: Equatable { case refreshSearch }
        let message: String
        let recovery: Recovery?
    }

    struct RowEffect {
        let effect: ReplacementPreview.EntryEffect
        let changes: [ReplacementPreview.Change]
    }

    let id = UUID()
    let word: String
    let destination: ReplacementPreview.Destination
    let destinationName: String
    let historyEnabled: Bool
    private let dependencies: Dependencies
    private let onSaved: (Int) -> Void

    @Published private(set) var revision = 0
    @Published var replacement: String { didSet { if replacement != oldValue { invalidatePreview() } } }
    @Published private(set) var phrases: [Phrase] = []
    @Published private(set) var statuses: [String: ReplacementPreview.PhraseStatus.Kind] = [:]
    @Published private(set) var snapshot: HistorySnapshot?
    @Published private(set) var loadFailed = false
    @Published var scope: HistorySearchScope { didSet { if scope != oldValue { searchAgain() } } }
    @Published private(set) var isWorking = false
    @Published private(set) var findings: [AliasDiscovery.Finding] = []
    @Published private(set) var handledCount = 0
    @Published private(set) var searchedCount = 0
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var editing: Set<String> = []
    @Published private(set) var focusRequest: String?
    @Published private(set) var preview: ReplacementPreview?
    @Published private(set) var problem: Problem?
    @Published private(set) var notice: String?

    private var searchedItems: [HistorySnapshot.Item] = []
    private var reviewBase: [ReplacementsSet.Rule] = []
    private var reviewedVocabulary: Vocabulary?
    private var cachedPreview: (key: PreviewKey, preview: ReplacementPreview)?
    private var needsSearch = true
    private var closed = false
    private var generation = 0
    private var work: Task<Void, Never>?

    init(
        word: String, destination: ReplacementPreview.Destination, destinationName: String,
        historyEnabled: Bool, dependencies: Dependencies, onSaved: @escaping (Int) -> Void
    ) {
        self.word = word
        self.replacement = word
        self.destination = destination
        self.destinationName = destinationName
        self.historyEnabled = historyEnabled
        self.dependencies = dependencies
        self.onSaved = onSaved
        scope = HistorySearchScope(period: .all, model: .all)
    }

    var issue: String? { problem?.message }

    var withoutRecordedModel: Int {
        guard let snapshot else { return 0 }
        return scope.withoutRecordedModel(snapshot.items, now: dependencies.now())
    }

    var recordedModels: [String] {
        guard let snapshot else { return [] }
        var unfiltered = scope
        unfiltered.model = .all
        return HistorySearchScope.recordedModels(in: unfiltered.matching(snapshot.items, now: dependencies.now()))
    }

    var replacementIssue: String? {
        if replacement.isEmpty { return "Enter the text to use instead." }
        return UserInputValidation.promptIssue(replacement)?.message
    }

    var replacementAdvisory: String? { VocabularyDraftAnalysis.invisibleOnlyDescription(replacement) }

    var activePhrases: [Phrase] { phrases.filter { selected.contains($0.id) && !$0.isBlank } }

    func isChecked(_ id: String) -> Bool { activePhrases.contains { $0.id == id } }

    func phraseIssue(_ id: String) -> String? {
        guard let phrase = phrases.first(where: { $0.id == id }), !phrase.isBlank else { return nil }
        if let issue = UserInputValidation.phraseIssue(phrase.trimmed) { return issue.message }
        if activePhrases.contains(where: {
            $0.id != id && $0.trimmed.caseInsensitiveCompare(phrase.trimmed) == .orderedSame
        }) { return "This phrase is already selected in another row." }
        return nil
    }

    var canAdd: Bool {
        !isWorking && replacementIssue == nil && (preview?.replacementCount ?? 0) > 0
            && activePhrases.allSatisfy { phraseIssue($0.id) == nil }
    }

    var addGuidance: String {
        let active = activePhrases
        if active.isEmpty {
            return phrases.contains { !$0.discovered && $0.isBlank }
                ? "Enter a heard phrase, or select a suggestion." : "Select phrases to add."
        }
        if active.contains(where: { phraseIssue($0.id) != nil }) { return "Fix the phrase marked in red before adding." }
        if replacementIssue != nil { return "Fix Use instead before adding." }
        guard let preview else { return "Updating the preview…" }
        guard preview.replacementCount > 0 else { return "The selected phrases are already saved or conflict with saved replacements." }
        return "\(preview.changeCount) \(preview.changeCount == 1 ? "match" : "matches") in saved History."
    }

    func status(for id: String) -> ReplacementPreview.PhraseStatus.Kind? { statuses[id] }

    func discoveryExcerpts(for id: String) -> [Excerpt] {
        guard let phrase = phrases.first(where: { $0.id == id }), phrase.discovered,
              let finding = findings.first(where: { $0.key == id }), finding.phrase == phrase.heard else { return [] }
        return finding.occurrences.compactMap { occurrence in
            guard searchedItems.indices.contains(occurrence.entry) else { return nil }
            return Self.excerpt(searchedItems[occurrence.entry].entry.heard, range: occurrence.range)
        }
    }

    func effects(for id: String) -> [RowEffect] {
        guard let preview, let phrase = activePhrases.first(where: { $0.id == id }) else { return [] }
        return preview.effects.compactMap { effect in
            let changes = effect.changes.filter { $0.phrase?.caseInsensitiveCompare(phrase.trimmed) == .orderedSame }
            return changes.isEmpty ? nil : RowEffect(effect: effect, changes: changes)
        }
    }

    var unattributedChangeCount: Int {
        preview?.effects.reduce(0) { $0 + $1.changes.filter { $0.phrase == nil }.count } ?? 0
    }

    func isOnlyInCombinedPreview(_ id: String) -> Bool {
        isChecked(id) && unattributedChangeCount > 0 && effects(for: id).isEmpty
    }

    var showsCombinedPreview: Bool {
        guard let preview, !preview.effects.isEmpty else { return false }
        return activePhrases.count > 1 || unattributedChangeCount > 0
    }

    func refresh() async {
        guard !closed else { return }
        let revision = revision
        if snapshot == nil { await load() }
        guard snapshot != nil, !Task.isCancelled, !closed, self.revision == revision else { return }
        if needsSearch { await find() }
        guard !needsSearch, !Task.isCancelled, !closed, self.revision == revision else { return }
        await review()
    }

    private func load() async {
        let token = begin()
        let loader = dependencies.loadSnapshot
        let result = await offMain { try? loader() }
        guard isCurrent(token) else { return }
        isWorking = false
        guard let result else {
            loadFailed = true
            return
        }
        snapshot = result
    }

    private func find() async {
        guard var snapshot else { return }
        let token = begin()
        let fingerprint = dependencies.fingerprint
        let current = await offMain { fingerprint() }
        guard isCurrent(token) else { return }
        if current != snapshot.fingerprint {
            let loader = dependencies.loadSnapshot
            let fresh = await offMain { try? loader() }
            guard isCurrent(token) else { return }
            guard let fresh else {
                isWorking = false
                problem = Problem(message: "Could not read History. Refresh the search to try again.", recovery: .refreshSearch)
                return
            }
            snapshot = fresh
            self.snapshot = fresh
        }
        let items = scope.matching(snapshot.items, now: dependencies.now())
        let vocabulary = dependencies.vocabulary()
        let words = mergedWords(vocabulary)
        let destination = destination
        let target = word
        let discover = dependencies.discover
        let result = await offMain { () -> (open: [AliasDiscovery.Finding], handled: [AliasDiscovery.Finding]) in
            let texts = items.map(\.entry.heard)
            let found = discover(target, texts, words)
            var stagesByMode: [String: [any PipelineStage]] = [:]
            return AliasDiscovery.separatingHandled(found, in: texts, target: target) { entry in
                let mode = Self.mode(evaluating: items[entry].entry.modeName, for: destination, in: vocabulary)
                let key = mode?.id ?? ""
                if let cached = stagesByMode[key] { return cached }
                let stages = Self.currentStages(vocabulary, mode: mode)
                stagesByMode[key] = stages
                return stages
            }
        }
        guard isCurrent(token) else { return }
        isWorking = false
        searchedItems = items
        searchedCount = items.count
        let retained = phrases.filter { phrase in
            !phrase.discovered || selected.contains(phrase.id)
                || findings.first(where: { $0.key == phrase.id })?.phrase != phrase.heard
        }
        let retainedByID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        let foundIDs = Set(result.open.map(\.key))
        phrases = result.open.map { retainedByID[$0.key] ?? Phrase(id: $0.key, heard: $0.phrase, discovered: true) }
            + retained.filter { !foundIDs.contains($0.id) }
        let ids = Set(phrases.map(\.id))
        selected.formIntersection(ids)
        editing.formIntersection(ids)
        findings = result.open
        handledCount = result.handled.count
        preview = nil
        needsSearch = false
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        if phrases.first(where: { $0.id == id })?.isBlank == false { invalidatePreview() }
    }

    func updatePhrase(_ id: String, heard: String) {
        guard let index = phrases.firstIndex(where: { $0.id == id }), phrases[index].heard != heard else { return }
        let wasBlank = phrases[index].isBlank
        phrases[index].heard = heard
        if !(wasBlank && phrases[index].isBlank) { invalidatePreview() }
    }

    @discardableResult
    func addPhrase() -> String {
        let id = UUID().uuidString
        phrases.append(Phrase(id: id, heard: "", discovered: false))
        selected.insert(id)
        focusRequest = id
        return id
    }

    func toggleEditing(_ id: String) {
        if editing.remove(id) == nil {
            editing.insert(id)
            focusRequest = id
        }
    }

    func focusHandled(_ id: String) {
        if focusRequest == id { focusRequest = nil }
    }

    private func review() async {
        guard let snapshot else { return }
        let vocabulary = dependencies.vocabulary()
        let replacement = replacement
        let candidates = phrases.filter { !$0.isBlank && phraseIssue($0.id) == nil }
        do {
            statuses = try Dictionary(uniqueKeysWithValues: candidates.compactMap { phrase in
                let made = try ReplacementPreview.make(
                    phrases: [phrase.heard], replacement: replacement, destination: destination,
                    global: vocabulary.global, modes: vocabulary.modes, history: [], searched: [])
                return made.statuses.first.map { (phrase.id, $0.kind) }
            })
        } catch {
            preview = nil
            problem = Problem(
                message: "Could not preview the changes because \(destinationName) no longer exists. Close this and choose a scope again.",
                recovery: nil)
            return
        }
        let active = activePhrases
        guard replacementIssue == nil, !active.isEmpty, active.allSatisfy({ phraseIssue($0.id) == nil }) else {
            preview = nil
            return
        }
        let request = PreviewRequest(
            phrases: active.map(\.heard), replacement: replacement, destination: destination, vocabulary: vocabulary,
            history: snapshot.items, searched: Set(searchedItems.map(\.reference)))
        let key = PreviewKey(
            phrases: request.phrases, replacement: replacement, vocabulary: vocabulary,
            fingerprint: snapshot.fingerprint, searched: request.searched)
        let base = destinationRules(vocabulary)
        if let cachedPreview, cachedPreview.key == key {
            accept(cachedPreview.preview, base: base, vocabulary: vocabulary)
            return
        }
        let token = begin()
        let make = dependencies.makePreview
        let result = await offMain { Result { try make(request) } }
        guard isCurrent(token) else { return }
        isWorking = false
        switch result {
        case .success(let made):
            cachedPreview = (key, made)
            accept(made, base: base, vocabulary: vocabulary)
        case .failure:
            problem = Problem(
                message: "Could not preview the changes because \(destinationName) no longer exists. Close this and choose a scope again.",
                recovery: nil)
        }
    }

    private func accept(_ made: ReplacementPreview, base: [ReplacementsSet.Rule], vocabulary: Vocabulary) {
        reviewBase = base
        reviewedVocabulary = vocabulary
        preview = made
    }

    func add() async {
        guard canAdd, let preview, let snapshot else { return }
        let token = begin()
        let fingerprint = dependencies.fingerprint
        let current = await offMain { fingerprint() }
        guard isCurrent(token) else { return }
        isWorking = false
        notice = nil
        guard current == snapshot.fingerprint else {
            problem = Problem(
                message: "History changed. Refresh the search to include the latest dictations.", recovery: .refreshSearch)
            self.preview = nil
            return
        }
        let vocabulary = dependencies.vocabulary()
        guard vocabulary == reviewedVocabulary else {
            await recover(from: staleReason(in: vocabulary) ?? .rulesChanged)
            return
        }
        do {
            switch try dependencies.save(destination, reviewBase, preview.proposedRules, requiredWord) {
            case .saved: onSaved(preview.replacementCount)
            case .stale(let reason): await recover(from: reason)
            }
        } catch {
            problem = Problem(message: "Could not save the replacements. Nothing was added. Try again.", recovery: nil)
        }
    }

    private func staleReason(in vocabulary: Vocabulary) -> ConfigRepository.BatchOutcome.StaleReason? {
        let words: [String]
        switch destination {
        case .global:
            words = vocabulary.globalWords
        case .mode(let id):
            guard let mode = vocabulary.modes.first(where: { $0.id == id }), mode.hasOwnVocabulary else {
                return .destinationMissing
            }
            words = mode.dictionary.words
        }
        guard let requiredWord, !words.contains(where: { $0.caseInsensitiveCompare(requiredWord) == .orderedSame }) else {
            return nil
        }
        return .wordRemoved
    }

    private func recover(from reason: ConfigRepository.BatchOutcome.StaleReason) async {
        switch reason {
        case .rulesChanged:
            await rebuildAfterVocabularyChanged()
        case .wordRemoved:
            problem = Problem(message: "“\(word)” is no longer in \(destinationName). Nothing was added.", recovery: nil)
            preview = nil
        case .destinationMissing:
            problem = Problem(message: "\(destinationName) no longer exists. Nothing was added.", recovery: nil)
            preview = nil
        }
    }

    private func rebuildAfterVocabularyChanged() async {
        preview = nil
        cachedPreview = nil
        await review()
        guard preview != nil else { return }
        notice = "Words or replacements changed, so the preview was updated. Check it, then add again."
    }

    func searchAgain() {
        needsSearch = true
        loadFailed = false
        invalidatePreview()
    }

    func close() {
        closed = true
        cancelWork()
        snapshot = nil
        findings = []
        phrases = []
        statuses = [:]
        editing = []
        focusRequest = nil
        preview = nil
        cachedPreview = nil
        searchedItems = []
        reviewedVocabulary = nil
    }

    static func excerpt(_ text: String, range: Range<String.Index>, wordsAround: Int = 8) -> Excerpt {
        let before = text[..<range.lowerBound].split(whereSeparator: \.isWhitespace).suffix(wordsAround)
        let after = text[range.upperBound...].split(whereSeparator: \.isWhitespace).prefix(wordsAround)
        let leadingCut = text[..<range.lowerBound].split(whereSeparator: \.isWhitespace).count > wordsAround
        let trailingCut = text[range.upperBound...].split(whereSeparator: \.isWhitespace).count > wordsAround
        let lead = before.joined(separator: " ")
        let tail = after.joined(separator: " ")
        let spaceBefore = text[..<range.lowerBound].last?.isWhitespace == true && !lead.isEmpty ? " " : ""
        let spaceAfter = text[range.upperBound...].first?.isWhitespace == true && !tail.isEmpty ? " " : ""
        return Excerpt(
            before: (leadingCut ? "…" : "") + lead + spaceBefore,
            match: String(text[range]),
            after: spaceAfter + tail + (trailingCut ? "…" : ""))
    }

    private var requiredWord: String? { word }

    private func mergedWords(_ vocabulary: Vocabulary) -> [String] {
        guard case .mode(let id) = destination, let mode = vocabulary.modes.first(where: { $0.id == id }) else {
            return vocabulary.globalWords
        }
        return VocabularyMerge.words(
            global: vocabulary.globalWords, local: mode.dictionary.words, includeGlobal: mode.dictionary.includeGlobal)
    }

    private nonisolated static func mode(
        evaluating modeName: String, for destination: ReplacementPreview.Destination, in vocabulary: Vocabulary
    ) -> Mode? {
        if case .mode(let id) = destination { return vocabulary.modes.first { $0.id == id } }
        let named = vocabulary.modes.filter { $0.name == modeName }
        return named.count == 1 ? named.first : nil
    }

    private nonisolated static func currentStages(_ vocabulary: Vocabulary, mode: Mode?) -> [any PipelineStage] {
        let rules = VocabularyMerge.rules(
            global: vocabulary.global.toRules(), local: mode?.replacements.rules.toReplacementRules() ?? [],
            includeGlobal: mode?.replacements.includeGlobal ?? true)
        let words = mode.map {
            VocabularyMerge.words(
                global: vocabulary.globalWords, local: $0.dictionary.words, includeGlobal: $0.dictionary.includeGlobal)
        } ?? vocabulary.globalWords
        return [ReplacementsStage(rules: rules), FuzzyStage(terms: words)]
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let worker = Task.detached(priority: .userInitiated, operation: body)
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private func destinationRules(_ vocabulary: Vocabulary) -> [ReplacementsSet.Rule] {
        guard case .mode(let id) = destination else { return vocabulary.global.rules }
        return vocabulary.modes.first { $0.id == id }?.replacements.rules ?? []
    }

    private func invalidatePreview() {
        cancelWork()
        problem = nil
        notice = nil
        preview = nil
        revision += 1
    }

    @discardableResult
    func perform(_ action: @escaping @MainActor (HistoryReplacementsModel) async -> Void) -> Task<Void, Never> {
        work?.cancel()
        let task = Task { await action(self) }
        work = task
        return task
    }

    private func begin() -> Int {
        generation += 1
        isWorking = true
        problem = nil
        return generation
    }

    private func isCurrent(_ token: Int) -> Bool { token == generation && !Task.isCancelled }

    private func cancelWork() {
        work?.cancel()
        generation += 1
        isWorking = false
    }
}
