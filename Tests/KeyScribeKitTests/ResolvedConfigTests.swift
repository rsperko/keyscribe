import Testing
@testable import KeyScribeKit

// The frozen per-generation config snapshot a dictation captures at record-start (design.md §5; the
// correctness fix is that a config reload mid-dictation builds a NEW ResolvedConfig without mutating
// the one an in-flight dictation holds — so a dictation always sees one coherent config).
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
        // nil mode defaults: live edits on, replacements, no numbers/fuzzy → LiveEdits + Replacements.
        let stages = rc.postSTTTextStages(for: nil)
        #expect(stages.count == 2)
    }

    @Test func textStagesReflectModeCommands() {
        var mode = Mode(id: "m", name: "M")
        mode.commands.liveEdits = true
        mode.commands.numbers = true
        mode.commands.fuzzyCorrection = true
        let rc = resolved(modes: [mode], dictionary: ["ChargeBee"])
        // LiveEdits + Replacements + Numbers + Fuzzy.
        #expect(rc.postSTTTextStages(for: mode).count == 4)
    }

    @Test func postSTTTextStagesAreMemoizedSameInstanceReused() {
        var mode = Mode(id: "m", name: "M")
        mode.commands.fuzzyCorrection = true
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
}
