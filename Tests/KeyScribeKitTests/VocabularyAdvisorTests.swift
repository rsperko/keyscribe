import Foundation
import Testing
@testable import KeyScribeKit

struct VocabularyAdvisorTests {
    private func rule(_ heard: String, _ replace: String, regex: Bool = false) -> ReplacementsSet.Rule {
        ReplacementsSet.Rule(heard: heard, replace: replace, regex: regex)
    }

    private func global(words: [String] = [], rules: [ReplacementsSet.Rule] = []) -> VocabularyScope {
        VocabularyScope(globalWords: words, globalRules: rules)
    }

    private func mode(
        words: [String] = [], rules: [ReplacementsSet.Rule] = [],
        includeGlobalWords: Bool = true, includeGlobalRules: Bool = true,
        globalWords: [String] = [], globalRules: [ReplacementsSet.Rule] = []
    ) -> VocabularyScope {
        VocabularyScope(
            globalWords: globalWords, globalRules: globalRules,
            local: VocabularyScope.Local(
                words: words, rules: rules,
                includeGlobalWords: includeGlobalWords, includeGlobalRules: includeGlobalRules))
    }

    @Test func overrideAdvisoryBoundsAHugeGlobalReplacement() {
        let huge = String(repeating: "a", count: 1_000)
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "foo", replace: "short", regex: false),
            in: mode(globalRules: [rule("foo", huge)]))
        guard let advisory = analysis.advisories.first(where: { $0.kind == .overridesGlobal }) else {
            Issue.record("expected an overridesGlobal advisory")
            return
        }
        #expect(advisory.message.count < 300)
        #expect(advisory.message.contains("…"))
    }

    @Test func newWordIsAnAdd() {
        let analysis = VocabularyAdvisor.analyze(.word("Kubernetes"), in: global(words: ["Postgres"]))
        #expect(analysis.action == .addWord)
        #expect(analysis.advisories.isEmpty)
    }

    @Test func globalWordDuplicateWithMatchingCasingIsNoChange() {
        let analysis = VocabularyAdvisor.analyze(.word("Kubernetes"), in: global(words: ["Kubernetes"]))
        #expect(analysis.action == .noChange(.wordAlreadyListed))
    }

    @Test func globalWordCanRecaseAnExistingWord() {
        let analysis = VocabularyAdvisor.analyze(.word("Kubernetes"), in: global(words: ["kubernetes"]))
        #expect(analysis.action == .updateWord(currentWord: "kubernetes"))
    }

    @Test func modeLocalWordDuplicateWithMatchingCasingIsNoChange() {
        let analysis = VocabularyAdvisor.analyze(.word("Postgres"), in: mode(words: ["Postgres"]))
        #expect(analysis.action == .noChange(.wordAlreadyListed))
    }

    @Test func modeLocalWordCanRecaseAnExistingWord() {
        let analysis = VocabularyAdvisor.analyze(.word("Postgres"), in: mode(words: ["postgres"]))
        #expect(analysis.action == .updateWord(currentWord: "postgres"))
    }

    @Test func modeWordCoveredByIncludedGlobalWithMatchingCasing() {
        let analysis = VocabularyAdvisor.analyze(.word("Postgres"), in: mode(globalWords: ["Postgres"]))
        #expect(analysis.action == .noChange(.wordCoveredByGlobal))
    }

    @Test func modeWordCanOverrideIncludedGlobalCasing() {
        let analysis = VocabularyAdvisor.analyze(.word("Postgres"), in: mode(globalWords: ["postgres"]))
        #expect(analysis.action == .addWord)
    }

    @Test func modeWordIsAnAddWhenGlobalWordsAreExcluded() {
        let analysis = VocabularyAdvisor.analyze(
            .word("postgres"), in: mode(includeGlobalWords: false, globalWords: ["Postgres"]))
        #expect(analysis.action == .addWord)
    }

    @Test func wordProposalNeverCarriesAdvisories() {
        let analysis = VocabularyAdvisor.analyze(
            .word("foo"), in: global(rules: [rule("foo", "bar")]))
        #expect(analysis.action == .addWord)
        #expect(analysis.advisories.isEmpty)
    }

    @Test func literalWithSameHeardAndSameOutputIsNoChange() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "Foo", replace: "bar", regex: false),
            in: global(rules: [rule("foo", "bar")]))
        #expect(analysis.action == .noChange(.replacementAlreadyListed))
    }

    @Test func literalWithSameHeardAndDifferentOutputIsAnUpdate() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "foo", replace: "baz", regex: false),
            in: global(rules: [rule("Foo", "bar")]))
        #expect(analysis.action == .updateReplacement(currentReplace: "bar"))
    }

    @Test func regexWithSameSourceAndSameOutputIsNoChange() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: #"\bfoo\b"#, replace: "bar", regex: true),
            in: global(rules: [rule(#"\bfoo\b"#, "bar", regex: true)]))
        #expect(analysis.action == .noChange(.replacementAlreadyListed))
    }

    @Test func regexWithSameSourceAndDifferentOutputIsAnUpdate() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: #"\bfoo\b"#, replace: "baz", regex: true),
            in: global(rules: [rule(#"\bfoo\b"#, "bar", regex: true)]))
        #expect(analysis.action == .updateReplacement(currentReplace: "bar"))
    }

    @Test func regexIdentityIsCaseSensitive() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "Foo", replace: "bar", regex: true),
            in: global(rules: [rule("foo", "bar", regex: true)]))
        #expect(analysis.action == .addReplacement)
    }

    @Test func literalAndRegexOccupySeparateIdentityKeyspaces() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "foo", replace: "baz", regex: true),
            in: global(rules: [rule("foo", "bar")]))
        #expect(analysis.action == .addReplacement)
    }

    @Test func modeReplacementCoveredByIdenticalIncludedGlobalIsNoChange() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "foo", replace: "bar", regex: false),
            in: mode(globalRules: [rule("Foo", "bar")]))
        #expect(analysis.action == .noChange(.replacementCoveredByGlobal))
    }

    @Test func modeReplacementIsAnAddWhenGlobalRulesAreExcluded() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "foo", replace: "bar", regex: false),
            in: mode(includeGlobalRules: false, globalRules: [rule("foo", "bar")]))
        #expect(analysis.action == .addReplacement)
        #expect(analysis.advisories.isEmpty)
    }

    @Test func modeReplacementOverridingAGlobalOutputAdvisesTheOverride() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "foo", replace: "baz", regex: false),
            in: mode(globalRules: [rule("foo", "bar")]))
        #expect(analysis.action == .addReplacement)
        let overrides = analysis.advisories.filter { $0.kind == .overridesGlobal }
        #expect(overrides.count == 1)
        #expect(overrides.first?.message.contains("“foo”") == true)
        #expect(overrides.first?.message.contains("“bar”") == true)
    }

    @Test func modeLocalIdentityWinsOverGlobalIdentityForUpdates() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "foo", replace: "qux", regex: false),
            in: mode(rules: [rule("foo", "baz")], globalRules: [rule("foo", "bar")]))
        #expect(analysis.action == .updateReplacement(currentReplace: "baz"))
    }

    @Test func analyzeCarriesNoOverlapAdvisories() {
        let analysis = VocabularyAdvisor.analyze(
            .replacement(heard: "colour", replace: "colour scheme", regex: false),
            in: global(rules: [rule("colou?r", "color", regex: true)]))
        #expect(analysis.action == .addReplacement)
        #expect(analysis.advisories.isEmpty)
    }

}
