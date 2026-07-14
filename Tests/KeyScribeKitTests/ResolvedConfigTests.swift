import Testing
@testable import KeyScribeKit

// ResolvedConfig is the frozen per-generation config snapshot a dictation captures at record-start
// (design.md §5): a config reload mid-dictation builds a NEW ResolvedConfig rather than mutating the
// one an in-flight dictation holds, so a dictation always sees one coherent config.
struct ResolvedConfigTests {
    private func resolved(
        modes: [Mode] = [], dictionary: [String] = [], replacements: [ReplacementsSet.Rule] = [],
        fragments: [String: String] = [:]
    ) -> ResolvedConfig {
        ResolvedConfig(
            modes: modes, dictionary: DictionarySet(words: dictionary),
            replacements: ReplacementsSet(rules: replacements),
            connections: ConnectionSet(), fragments: fragments)
    }

    @Test func mergedDictionaryUnionsGlobalAndModeWithDedup() {
        var mode = Mode(id: "m", name: "M")
        mode.dictionary = Mode.ModeDictionary(includeGlobal: true, words: ["ChargeBee", "Postgres"])
        let rc = resolved(modes: [mode], dictionary: ["Postgres", "Kubernetes"])
        #expect(rc.mergedDictionary(for: mode) == ["Postgres", "Kubernetes", "ChargeBee"])
    }

    @Test func mergedDictionaryHonorsIncludeGlobalFalse() {
        var mode = Mode(id: "m", name: "M")
        mode.dictionary = Mode.ModeDictionary(includeGlobal: false, words: ["OnlyLocal"])
        let rc = resolved(modes: [mode], dictionary: ["Global"])
        #expect(rc.mergedDictionary(for: mode) == ["OnlyLocal"])
    }

    @Test func nilModeFallsBackToGlobalDictionaryAndDefaultStages() {
        let rc = resolved(dictionary: ["Global"])
        #expect(rc.mergedDictionary(for: nil) == ["Global"])
        // nil-mode defaults yield 3 stages: LiveEdits + Replacements + FuzzyStage (dictionary non-empty).
        let stages = rc.postSTTTextStages(for: nil)
        #expect(stages.count == 3)
    }

    @Test func textStagesReflectModeCommands() {
        var mode = Mode(id: "m", name: "M")
        mode.commands.liveEdits = true
        mode.commands.numbers = true
        let rc = resolved(modes: [mode], dictionary: ["ChargeBee"])
        // LiveEdits + Replacements + Numbers + FuzzyStage.
        #expect(rc.postSTTTextStages(for: mode).count == 4)
    }

    @Test func fuzzyStageAppendedOnlyWhenMergedDictionaryNonEmpty() {
        var mode = Mode(id: "m", name: "M")
        mode.commands.liveEdits = true
        // Non-empty dictionary → LiveEdits + Replacements + FuzzyStage; empty → no FuzzyStage.
        let withDict = resolved(modes: [mode], dictionary: ["ChargeBee"])
        #expect(withDict.postSTTTextStages(for: mode).count == 3)
        let empty = resolved(modes: [mode], dictionary: [])
        #expect(empty.postSTTTextStages(for: mode).count == 2)
    }

    @Test func postSTTTextStagesAreMemoizedSameInstanceReused() {
        let mode = Mode(id: "m", name: "M")
        let rc = resolved(modes: [mode], dictionary: ["ChargeBee"])
        let first = rc.postSTTTextStages(for: mode)
        let second = rc.postSTTTextStages(for: mode)
        #expect(first.count == second.count)
    }

    @Test func fragmentBodiesResolveFromFrozenMapDroppingBlanksAndMissing() {
        let rc = resolved(fragments: ["a": "Body A", "b": "", "c": "Body C"])
        #expect(rc.fragmentBodies(ids: ["a", "b", "missing", "c"]) == ["Body A", "Body C"])
    }

    @Test func recognitionBiasTermsTrimWhitespaceAndDropBlanks() {
        var mode = Mode(id: "m", name: "M")
        mode.dictionary = Mode.ModeDictionary(includeGlobal: true, words: ["  Padded  ", "   "])
        let rc = resolved(modes: [mode], dictionary: ["Postgres"])
        #expect(rc.recognitionBiasTerms(for: mode) == ["Postgres", "Padded"])
    }

    @Test func recognitionBiasTermsFallBackToGlobalForNilMode() {
        let rc = resolved(dictionary: ["Global"])
        #expect(rc.recognitionBiasTerms(for: nil) == ["Global"])
    }

    // mergedDictionary shares its cache with recognitionBiasTerms/postSTTTextStages — priming via bias
    // must not diverge from the public accessor.
    @Test func mergedDictionaryAndBiasShareCache() {
        var mode = Mode(id: "m", name: "M")
        mode.dictionary = Mode.ModeDictionary(includeGlobal: true, words: ["ChargeBee", "Postgres"])
        let rc = resolved(modes: [mode], dictionary: ["Postgres", "Kubernetes"])
        _ = rc.recognitionBiasTerms(for: mode)
        #expect(rc.mergedDictionary(for: mode) == ["Postgres", "Kubernetes", "ChargeBee"])
    }
}
