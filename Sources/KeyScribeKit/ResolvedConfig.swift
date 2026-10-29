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
    private let voiceCommands: VoiceCommandConfig

    private let lock = NSLock()
    private var mergedDictionaryCache: [String: [String]] = [:]
    private var biasTermsCache: [String: [String]] = [:]
    private var textStageCache: [String: [any PipelineStage]] = [:]
    private static let nilModeKey = "\u{0}nil"
    private let onBuildTextStages: (@Sendable (String) -> Void)?

    public convenience init(
        modes: [Mode], dictionary: DictionarySet, replacements: ReplacementsSet,
        connections: ConnectionSet, fragments: [String: String], voiceCommands: VoiceCommandConfig = VoiceCommandConfig()
    ) {
        self.init(
            modes: modes, dictionary: dictionary, replacements: replacements, connections: connections,
            fragments: fragments, voiceCommands: voiceCommands, onBuildTextStages: nil)
    }

    init(
        modes: [Mode], dictionary: DictionarySet, replacements: ReplacementsSet,
        connections: ConnectionSet, fragments: [String: String], voiceCommands: VoiceCommandConfig = VoiceCommandConfig(),
        onBuildTextStages: (@Sendable (String) -> Void)?
    ) {
        self.modes = modes
        self.dictionary = dictionary
        self.replacements = replacements
        self.connections = connections
        self.fragments = fragments
        self.voiceCommands = voiceCommands
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
            let words = mergedDictionary(for: mode)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard mode?.runsVoiceCommands == true else { return words }
            var seen = Set(words.map { $0.lowercased() })
            let names = voiceCommands.commands.flatMap(\.candidate.spokenForms)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            return words + names
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

    public func voiceCommandText(
        heard: String, places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = []
    ) -> String {
        guard let mode = modes.first(where: { $0.id == Mode.voiceCommandsId }) else { return heard }
        return voiceCommandText(heard: heard, mode: mode, places: places, scripts: scripts)
    }

    public func voiceCommandText(
        heard: String, mode: Mode?, places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = []
    ) -> String {
        voiceCommandReading(heard: heard, mode: mode, places: places, scripts: scripts).text
    }

    // The dictionary may correct an app or place being switched to, the words after a saved command's name, and
    // the words a whole-utterance rule captured. Never the command words, a whole-utterance rule's own text, or a
    // correction that would change which saved command the words name.
    public func voiceCommandReading(
        heard: String, mode: Mode?, places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = []
    ) -> (text: String, firedReplacements: [ReplacementRule]) {
        let stages = postSTTTextStages(for: mode)
        let fuzzy = stages.filter { $0 is FuzzyStage }
        let pipeline = Pipeline(stages.filter { !($0 is FuzzyStage) })
        let payload = pipeline.forward(heard)
        let read: String
        let corrected: String
        if let bare = payload.bareReplacement {
            read = bare.text
            corrected = correctingCaptures(payload.bareSegments, of: read, with: fuzzy, places: places, scripts: scripts)
                ?? read
        } else {
            read = pipeline.restore(payload.text)
            if let target = Self.correctableRange(of: read, places: places, scripts: scripts) {
                corrected = String(read[..<target.lowerBound]) + Self.correcting(String(read[target]), with: fuzzy)
            } else {
                corrected = read
            }
        }
        let sameCommand = VoiceCommandResolver.savedCommandIdentity(corrected, places: places, scripts: scripts)
            == VoiceCommandResolver.savedCommandIdentity(read, places: places, scripts: scripts)
        return (sameCommand ? corrected : read, payload.firedReplacements)
    }

    // The words a command acts on: what a "switch to" targets, or what follows a saved command's name.
    private static func correctableRange(
        of read: String, places: [VoiceCommandPlace], scripts: [VoiceCommandScript]
    ) -> Range<String.Index>? {
        VoiceCommandResolver.savedTextRange(read, places: places, scripts: scripts) ?? VoiceCommandGrammar.targetRange(in: read)
    }

    private static func correcting(_ text: String, with stages: [any PipelineStage]) -> String {
        Pipeline.joined(stages.reduce([.captured(text)]) { Pipeline.applying($1, toCapturesIn: $0) })
    }

    // A capture can hold command words ("launch", "switch to") as easily as a target, so only the part of each
    // capture that lands in the words the command acts on is corrected.
    private func correctingCaptures(
        _ segments: [BareSegment]?, of read: String, with stages: [any PipelineStage],
        places: [VoiceCommandPlace], scripts: [VoiceCommandScript]
    ) -> String? {
        guard let segments, Pipeline.joined(segments) == read,
              let target = Self.correctableRange(of: read, places: places, scripts: scripts) else { return nil }
        var corrected = ""
        var cursor = read.startIndex
        for segment in segments {
            let isCaptured: Bool
            let text: String
            switch segment {
            case .literal(let s): (isCaptured, text) = (false, s)
            case .captured(let s): (isCaptured, text) = (true, s)
            }
            let end = read.index(cursor, offsetBy: text.count)
            let low = max(cursor, target.lowerBound)
            let high = min(end, target.upperBound)
            if isCaptured, low < high {
                corrected += read[cursor..<low] + Self.correcting(String(read[low..<high]), with: stages) + read[high..<end]
            } else {
                corrected += read[cursor..<end]
            }
            cursor = end
        }
        return corrected
    }

    private func buildTextStages(for mode: Mode?) -> [any PipelineStage] {
        var stages: [any PipelineStage] = []
        if mode?.commands.liveEdits ?? true { stages.append(LiveEditsStage()) }
        let rules = VocabularyMerge.rules(
            global: replacements.toRules().map { $0.from(.global) },
            local: mode.map { m in m.replacements.toRules().map { $0.from(.mode(m.id)) } } ?? [],
            includeGlobal: mode?.replacements.includeGlobal ?? true)
        stages.append(ReplacementsStage(rules: rules))
        if mode?.commands.numbers ?? false { stages.append(NumbersStage()) }
        let terms = mergedDictionary(for: mode)
        if !terms.isEmpty { stages.append(FuzzyStage(terms: terms)) }
        return stages
    }
}
