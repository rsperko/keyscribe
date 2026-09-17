import Foundation

// One config generation, frozen: the modes/vocabulary/connections/fragments a dictation needs, plus the
// expensive per-mode artifacts (merged dictionary, compiled post-STT stages) memoized once. Built per
// ConfigCache generation and captured by value, so a config reload mid-dictation builds a *new* instance
// without mutating the one an in-flight dictation holds — each dictation sees one coherent config. The
// memoization lock (RegexCache/Tokenizer pattern) makes it freely Sendable.
public final class ResolvedConfig: @unchecked Sendable {
    public let modes: [Mode]
    public let dictionary: DictionarySet
    public let replacements: ReplacementsSet
    public let connections: ConnectionSet
    private let fragments: [String: String]

    private let lock = NSLock()
    private var mergedDictionaryCache: [String: [String]] = [:]
    private var biasTermsCache: [String: [String]] = [:]
    private var textStageCache: [String: [any PipelineStage]] = [:]
    private static let nilModeKey = "\u{0}nil"
    private let onBuildTextStages: (@Sendable (String) -> Void)?

    public convenience init(
        modes: [Mode], dictionary: DictionarySet, replacements: ReplacementsSet,
        connections: ConnectionSet, fragments: [String: String]
    ) {
        self.init(
            modes: modes, dictionary: dictionary, replacements: replacements, connections: connections,
            fragments: fragments, onBuildTextStages: nil)
    }

    init(
        modes: [Mode], dictionary: DictionarySet, replacements: ReplacementsSet,
        connections: ConnectionSet, fragments: [String: String],
        onBuildTextStages: (@Sendable (String) -> Void)?
    ) {
        self.modes = modes
        self.dictionary = dictionary
        self.replacements = replacements
        self.connections = connections
        self.fragments = fragments
        self.onBuildTextStages = onBuildTextStages
    }

    public func connection(id: String) -> Connection? { connections.connection(id: id) }

    // Resolved from the frozen map captured at construction — never re-read from disk mid-dictation.
    public func fragmentBodies(ids: [String]) -> [String] {
        ids.compactMap { fragments[$0] }.filter { !$0.isEmpty }
    }

    // Each memo below is built OUTSIDE the lock and published under it, so a mode compiling its stages (a
    // background prewarm) never blocks a main-actor lookup for another mode. A race builds twice; the first
    // published result wins, which is harmless because a build is a pure function of this frozen config.
    public func mergedDictionary(for mode: Mode?) -> [String] {
        memoized(mode, in: \.mergedDictionaryCache) {
            mode.map { m in
                VocabularyMerge.words(
                    global: dictionary.words, local: m.dictionary.words, includeGlobal: m.dictionary.includeGlobal)
            } ?? dictionary.words
        }
    }

    // Memoized per mode so the per-dictation bias path is a cache hit, not a fresh map+filter.
    public func recognitionBiasTerms(for mode: Mode?) -> [String] {
        memoized(mode, in: \.biasTermsCache) {
            mergedDictionary(for: mode)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    var cachedTextStageModeIds: Set<String> { lock.withLock { Set(textStageCache.keys) } }
    var cachedBiasTermModeIds: Set<String> { lock.withLock { Set(biasTermsCache.keys) } }

    // Verbatim/redaction tokenizers are per-dictation and added separately by the host; these stages
    // are pure config.
    public func postSTTTextStages(for mode: Mode?) -> [any PipelineStage] {
        memoized(mode, in: \.textStageCache) {
            onBuildTextStages?(mode?.id ?? Self.nilModeKey)
            return buildTextStages(for: mode)
        }
    }

    private func memoized<Value>(
        _ mode: Mode?, in cache: ReferenceWritableKeyPath<ResolvedConfig, [String: Value]>,
        build: () -> Value
    ) -> Value {
        let key = mode?.id ?? Self.nilModeKey
        if let cached = lock.withLock({ self[keyPath: cache][key] }) { return cached }
        let built = build()
        return lock.withLock {
            if let raced = self[keyPath: cache][key] { return raced }
            self[keyPath: cache][key] = built
            return built
        }
    }

    private func buildTextStages(for mode: Mode?) -> [any PipelineStage] {
        var stages: [any PipelineStage] = []
        if mode?.commands.liveEdits ?? true { stages.append(LiveEditsStage()) }
        let rules = VocabularyMerge.rules(
            global: replacements.toRules(),
            local: mode?.replacements.toRules() ?? [],
            includeGlobal: mode?.replacements.includeGlobal ?? true)
        stages.append(ReplacementsStage(rules: rules))
        if mode?.commands.numbers ?? false { stages.append(NumbersStage()) }
        let terms = mergedDictionary(for: mode)
        if !terms.isEmpty { stages.append(FuzzyStage(terms: terms)) }
        return stages
    }
}
