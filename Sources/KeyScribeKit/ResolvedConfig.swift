import Foundation

// One config generation, frozen: the modes/vocabulary/connections/fragments a dictation needs,
// plus the expensive per-mode artifacts derived from them (merged dictionary, compiled post-STT
// text stages) memoized once and reused across dictations until the config changes.
//
// A new instance is built per ConfigCache generation (see ConfigCache.resolved) and handed to a
// dictation at record-start. Because every input is captured by value at construction, a config
// reload mid-dictation produces a *new* ResolvedConfig without mutating the one an in-flight
// dictation already holds — so a single dictation always observes one coherent config (the
// correctness fix). Memoization is guarded by a lock (the RegexCache/Tokenizer pattern) so the
// instance is freely Sendable.
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

    public init(
        modes: [Mode], dictionary: DictionarySet, replacements: ReplacementsSet,
        connections: ConnectionSet, fragments: [String: String]
    ) {
        self.modes = modes
        self.dictionary = dictionary
        self.replacements = replacements
        self.connections = connections
        self.fragments = fragments
    }

    public func connection(id: String) -> Connection? { connections.connection(id: id) }

    // Shared fragment bodies for a mode's rewrite, in the requested order, blanks dropped. Resolved
    // from the frozen map captured at construction (never re-read from disk mid-dictation).
    public func fragmentBodies(ids: [String]) -> [String] {
        ids.compactMap { fragments[$0] }.filter { !$0.isEmpty }
    }

    // Global ⊕ mode dictionary (VocabularyMerge dedups in stable order), memoized per mode.
    public func mergedDictionary(for mode: Mode?) -> [String] {
        let key = mode?.id ?? Self.nilModeKey
        lock.lock(); defer { lock.unlock() }
        if let cached = mergedDictionaryCache[key] { return cached }
        let words = mode.map { m in
            VocabularyMerge.words(
                global: dictionary.words, local: m.dictionary.words, includeGlobal: m.dictionary.includeGlobal)
        } ?? dictionary.words
        mergedDictionaryCache[key] = words
        return words
    }

    // Merged dictionary trimmed of whitespace with blanks dropped, ready for engine recognition bias.
    // Memoized per mode so the per-dictation bias path is a cache hit, not a fresh map+filter.
    public func recognitionBiasTerms(for mode: Mode?) -> [String] {
        let key = mode?.id ?? Self.nilModeKey
        lock.lock(); defer { lock.unlock() }
        if let cached = biasTermsCache[key] { return cached }
        let terms = mergedDictionaryUnlocked(for: mode)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        biasTermsCache[key] = terms
        return terms
    }

    // Post-STT TEXT stages for a mode (live edits → replacements → numbers → fuzzy), memoized per
    // mode. Verbatim/redaction tokenizers are per-dictation and added separately by the host; these
    // stages are pure config so they compile once and are reused (fuzzy precomputes its tables here).
    public func postSTTTextStages(for mode: Mode?) -> [any PipelineStage] {
        let key = mode?.id ?? Self.nilModeKey
        lock.lock(); defer { lock.unlock() }
        if let cached = textStageCache[key] { return cached }
        let stages = buildTextStages(for: mode)
        textStageCache[key] = stages
        return stages
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
        if mode?.commands.fuzzyCorrection ?? false {
            stages.append(FuzzyStage(terms: mergedDictionaryUnlocked(for: mode)))
        }
        return stages
    }

    // mergedDictionary, assuming the lock is already held (buildTextStages runs inside it).
    private func mergedDictionaryUnlocked(for mode: Mode?) -> [String] {
        let key = mode?.id ?? Self.nilModeKey
        if let cached = mergedDictionaryCache[key] { return cached }
        let words = mode.map { m in
            VocabularyMerge.words(
                global: dictionary.words, local: m.dictionary.words, includeGlobal: m.dictionary.includeGlobal)
        } ?? dictionary.words
        mergedDictionaryCache[key] = words
        return words
    }
}
