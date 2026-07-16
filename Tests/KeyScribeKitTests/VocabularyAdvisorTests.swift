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

    @Test func literalRowPreemptedByAnEarlierRegexIsAdvised() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("colou?r", "color", regex: true), rule("colour", "colour scheme")]))
        #expect(advisories[0].isEmpty)
        let preempted = advisories[1].filter { $0.kind == .preempted }
        #expect(preempted.count == 1)
        #expect(preempted.first?.message.contains("“colou?r”") == true)
        #expect(preempted.first?.message.contains("“color”") == true)
    }

    @Test func noPreemptionAdvisoryWhenTheRuleStillMatchesTheTransformedPhrase() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("big", "BIG"), rule("the big one", "El Grande")]))
        #expect(advisories == [[], []])
    }

    @Test func regexRowPreemptedByAnEarlierLiteralIsAdvised() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("foo", "bar"), rule(#"\bfoo\b"#, "X", regex: true)]))
        let preempted = advisories[1].filter { $0.kind == .preempted }
        #expect(preempted.count == 1)
        #expect(preempted.first?.message.contains("“foo”") == true)
        #expect(preempted.first?.message.contains("“bar”") == true)
    }

    @Test func regexRowPreemptedByAnEarlierRegexUsesALaterLiteralWitness() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [
                rule("colou?r", "color", regex: true),
                rule("colour", "alternate", regex: true),
                rule("colour", "preferred"),
            ]))

        #expect(advisories[1].contains { $0.kind == .preempted })
        #expect(advisories[1].contains { $0.message.contains("When you say “colour”") })
    }

    @Test func rowWhoseOutputCascadesIntoALaterRuleIsAdvised() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("foo", "barn"), rule("barn", "qux")]))
        let cascades = advisories[0].filter { $0.kind == .cascades }
        #expect(cascades.count == 1)
        #expect(cascades.first?.message.contains("“barn”") == true)
        #expect(cascades.first?.message.contains("“qux”") == true)
        #expect(advisories[1].isEmpty)
    }

    @Test func regexWithoutAConcreteInputWitnessDoesNotClaimACascade() {
        let rules = [rule(#"(?<=a)x(?=b)"#, "bar", regex: true), rule("bar", "baz")]
        var context = PipelineContext(text: "axb")
        ReplacementsStage(rules: rules.toReplacementRules()).apply(&context)

        #expect(context.text == "abarb")
        #expect(VocabularyAdvisor.ruleAdvisories(in: global(rules: rules))[0].isEmpty)
    }

    @Test func regexCascadeUsesALaterLiteralPhraseAsAConcreteWitness() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("colou?r", "colour", regex: true), rule("colour", "preferred")]))

        #expect(advisories[0].contains { $0.kind == .cascades })
        #expect(advisories[0].contains { $0.message.contains("When you say “colour”") })
    }

    @Test func preemptedRuleDoesNotAlsoClaimThatItsOutputCascades() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("foo", "bar"), rule("foo", "baz"), rule("baz", "qux")]))

        #expect(advisories[1].contains { $0.kind == .preempted })
        #expect(advisories[1].allSatisfy { $0.kind != .cascades })
    }

    @Test func earlierRulesNeverCascadeIntoLaterOutput() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("bar", "qux"), rule("foo", "bar")]))
        #expect(advisories == [[], []])
    }

    @Test func literalMatchingUsesWordBoundariesNotSubstrings() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("pipeline", "PIPELINE"), rule("pipe", "|")]))
        #expect(advisories == [[], []])
    }

    @Test func modeRowAdvisoriesUseTheMergedGlobalThenLocalOrder() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: mode(rules: [rule("colour", "colour scheme")],
                     globalRules: [rule("colou?r", "color", regex: true)]))
        #expect(advisories.count == 1)
        #expect(advisories[0].contains { $0.kind == .preempted })
    }

    @Test func modeLocalRuleAdvisesWhenItChangesAnIncludedGlobalRulesOutput() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: mode(rules: [rule("bar", "baz")], globalRules: [rule("foo", "bar")]))

        #expect(advisories[0].contains { $0.kind == .cascades })
        #expect(advisories[0].contains { $0.message.contains("global replacement for “foo”") })
    }

    @Test func modeLocalRuleAdvisesWhenItChangesWitnessedGlobalRegexOutput() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: mode(rules: [rule("colour", "preferred")],
                     globalRules: [rule("colou?r", "colour", regex: true)]))

        #expect(advisories[0].contains { $0.kind == .cascades })
        #expect(advisories[0].contains { $0.message.contains("global replacement for “colou?r”") })
    }

    @Test func excludedGlobalRulesDoNotAdviseModeRows() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: mode(rules: [rule("colour", "colour scheme")], includeGlobalRules: false,
                     globalRules: [rule("colou?r", "color", regex: true)]))
        #expect(advisories == [[]])
    }

    @Test func aLocalOverrideIsNotPreemptedByTheGlobalRuleItDisplaces() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: mode(rules: [rule("foo", "baz")], globalRules: [rule("foo", "bar")]))
        #expect(advisories == [[]])
    }

    @Test func globalPaneRowsIgnoreModeRules() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("colour", "colour scheme")]))
        #expect(advisories == [[]])
    }

    @Test func captureReferenceTemplatesSkipOutputChecks() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule(#"(\d+) bucks"#, "$1 dollars", regex: true), rule("dollars", "USD")]))
        #expect(advisories[0].allSatisfy { $0.kind != .cascades })
    }

    @Test func unsafeRegexRulesAreNeverExecutedForAnalysis() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("aaa", "b"), rule("(a+)+$", "x", regex: true)]))
        #expect(advisories == [[], []])
    }

    @Test func invalidRegexRulesYieldNoAdvisories() {
        let advisories = VocabularyAdvisor.ruleAdvisories(
            in: global(rules: [rule("foo", "bar"), rule("(foo", "x", regex: true)]))
        #expect(advisories == [[], []])
    }

    @Test func emptyRuleListYieldsNoAdvisories() {
        #expect(VocabularyAdvisor.ruleAdvisories(in: global()) == [])
        #expect(VocabularyAdvisor.ruleAdvisories(in: mode()) == [])
    }
}
