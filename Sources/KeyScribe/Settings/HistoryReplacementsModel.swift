import Foundation
import KeyScribeKit

@MainActor
final class HistoryReplacementsModel: ObservableObject, Identifiable {
    enum Step: Equatable { case find, choose, review }

    struct Vocabulary: Sendable, Equatable {
        let global: ReplacementsSet
        let globalWords: [String]
        let modes: [Mode]
    }

    struct Dependencies {
        var loadSnapshot: @Sendable () throws -> HistorySnapshot
        var fingerprint: @Sendable () -> HistorySnapshot.Fingerprint
        var vocabulary: () -> Vocabulary
        var save: (ReplacementPreview.Destination, [ReplacementsSet.Rule], [ReplacementsSet.Rule], String?) throws
            -> ConfigRepository.BatchOutcome
        var now: () -> Date = Date.init
    }

    struct Excerpt: Equatable {
        let before: String
        let match: String
        let after: String
    }

    let id = UUID()
    let word: String
    let destination: ReplacementPreview.Destination
    let destinationName: String
    let historyEnabled: Bool
    private let dependencies: Dependencies
    private let onSaved: (Int) -> Void

    @Published private(set) var step: Step = .find
    @Published private(set) var snapshot: HistorySnapshot?
    @Published private(set) var loadFailed = false
    @Published var scope: HistorySearchScope { didSet { if scope != oldValue { invalidateFindings() } } }
    @Published private(set) var isWorking = false
    @Published private(set) var findings: [AliasDiscovery.Finding] = []
    @Published private(set) var handledCount = 0
    @Published private(set) var searchedCount = 0
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var preview: ReplacementPreview?
    @Published private(set) var issue: String?

    private var searchedItems: [HistorySnapshot.Item] = []
    private var reviewBase: [ReplacementsSet.Rule] = []
    private var reviewedVocabulary: Vocabulary?
    private var generation = 0
    private var work: Task<Void, Never>?

    init(
        word: String, destination: ReplacementPreview.Destination, destinationName: String,
        historyEnabled: Bool, dependencies: Dependencies, onSaved: @escaping (Int) -> Void
    ) {
        self.word = word
        self.destination = destination
        self.destinationName = destinationName
        self.historyEnabled = historyEnabled
        self.dependencies = dependencies
        self.onSaved = onSaved
        scope = HistorySearchScope(period: HistorySearchScope.defaultPeriod, model: .all)
    }

    var matchingCount: Int {
        guard let snapshot else { return 0 }
        return scope.matching(snapshot.items, now: dependencies.now()).count
    }

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

    func load() async {
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
        scope = HistorySearchScope.defaults(in: result.items, now: dependencies.now())
    }

    func find() async {
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
                issue = "Could not read History. Try again."
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
        let result = await offMain { () -> (open: [AliasDiscovery.Finding], handled: [AliasDiscovery.Finding]) in
            let texts = items.map(\.entry.heard)
            let found = AliasDiscovery.find(target: target, in: texts, dictionary: words)
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
        findings = result.open
        handledCount = result.handled.count
        selected = []
        preview = nil
        step = .choose
    }

    func isSelected(_ finding: AliasDiscovery.Finding) -> Bool { selected.contains(finding.key) }

    func toggle(_ finding: AliasDiscovery.Finding) {
        if selected.contains(finding.key) { selected.remove(finding.key) } else { selected.insert(finding.key) }
        preview = nil
        issue = nil
    }

    func review() async {
        guard let snapshot else { return }
        let phrases = findings.filter { selected.contains($0.key) }.map(\.phrase)
        guard !phrases.isEmpty else { return }
        let token = begin()
        let vocabulary = dependencies.vocabulary()
        let base = destinationRules(vocabulary)
        let destination = destination, target = word
        let searched = Set(searchedItems.map(\.reference))
        let result = await offMain { () -> Result<ReplacementPreview, Error> in
            Result {
                try ReplacementPreview.make(
                    phrases: phrases, replacement: target, destination: destination,
                    global: vocabulary.global, modes: vocabulary.modes,
                    history: snapshot.items, searched: searched)
            }
        }
        guard isCurrent(token) else { return }
        isWorking = false
        switch result {
        case .success(let made):
            reviewBase = base
            reviewedVocabulary = vocabulary
            preview = made
            step = .review
        case .failure:
            issue = "Could not review the changes because \(destinationName) no longer exists. Close this and choose a scope again."
        }
    }

    func add() async {
        guard let preview, let snapshot, !isWorking else { return }
        let token = begin()
        let fingerprint = dependencies.fingerprint
        let current = await offMain { fingerprint() }
        guard isCurrent(token) else { return }
        isWorking = false
        guard current == snapshot.fingerprint else {
            issue = "History changed since you searched. Find again to include the latest dictations."
            self.preview = nil
            return
        }
        guard dependencies.vocabulary() == reviewedVocabulary else {
            issue = "Words or replacements changed since this review. Review again before adding."
            self.preview = nil
            return
        }
        do {
            let outcome = try dependencies.save(destination, reviewBase, preview.proposedRules, requiredWord)
            switch outcome {
            case .saved:
                onSaved(preview.replacementCount)
            case .stale(.rulesChanged):
                issue = "Replacements in \(destinationName) changed since this review. Review again before adding."
                self.preview = nil
            case .stale(.wordRemoved):
                issue = "“\(word)” is no longer in \(destinationName). Nothing was added."
                self.preview = nil
            case .stale(.destinationMissing):
                issue = "\(destinationName) no longer exists. Nothing was added."
                self.preview = nil
            }
        } catch {
            issue = "Could not save the replacements. Nothing was added. Try again."
        }
    }

    func back() {
        cancelWork()
        issue = nil
        switch step {
        case .review: step = .choose
        case .choose: step = .find
        case .find: break
        }
    }

    @discardableResult
    func searchAllAvailableHistory() -> Task<Void, Never> {
        scope.period = .all
        return perform { await $0.find() }
    }

    func close() {
        cancelWork()
        snapshot = nil
        findings = []
        preview = nil
        searchedItems = []
        reviewedVocabulary = nil
    }

    func excerpt(for finding: AliasDiscovery.Finding) -> Excerpt? {
        guard let occurrence = finding.occurrences.first, searchedItems.indices.contains(occurrence.entry) else { return nil }
        let text = searchedItems[occurrence.entry].entry.heard
        return Self.excerpt(text, range: occurrence.range)
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

    private func invalidateFindings() {
        guard isWorking || step != .find || !findings.isEmpty else { return }
        cancelWork()
        findings = []
        selected = []
        preview = nil
        step = .find
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
        issue = nil
        return generation
    }

    private func isCurrent(_ token: Int) -> Bool { token == generation && !Task.isCancelled }

    private func cancelWork() {
        work?.cancel()
        generation += 1
        isWorking = false
    }
}
