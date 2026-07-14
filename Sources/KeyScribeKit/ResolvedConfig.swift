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

    // Resolved from the frozen map captured at construction — never re-read from disk mid-dictation.
    public func fragmentBodies(ids: [String]) -> [String] {
        ids.compactMap { fragments[$0] }.filter { !$0.isEmpty }
    }

    public func mergedDictionary(for mode: Mode?) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return mergedDictionaryUnlocked(for: mode)
    }

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

    // Verbatim/redaction tokenizers are per-dictation and added separately by the host; these stages
    // are pure config.
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
        let terms = mergedDictionaryUnlocked(for: mode)
        if !terms.isEmpty { stages.append(FuzzyStage(terms: terms)) }
        return stages
    }

    // PRECONDITION: caller holds `lock` — mergedDictionary and buildTextStages both hold it.
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
