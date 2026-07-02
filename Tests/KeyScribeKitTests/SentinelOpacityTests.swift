import Testing
@testable import KeyScribeKit

// W4: sentinel tokens (⟦SN:VERB:1⟧ etc.) must be opaque to the post-STT text stages. A user rule like
// literal `verb` or regex `\d+` matches inside the plain-ASCII token body; the stages transform only
// the runs between sentinels so a token is never corrupted (design.md §4.2).
struct SentinelOpacityTests {
    @Test func utilityLeavesTokensIntactAndTransformsBetween() {
        let out = SentinelText.mappingOutsideSentinels("a ⟦SN:VERB:1⟧ b ⟦SN:CLIP:2⟧ c") { $0.uppercased() }
        #expect(out == "A ⟦SN:VERB:1⟧ B ⟦SN:CLIP:2⟧ C")
    }

    @Test func utilityWithNoSentinelTransformsWhole() {
        #expect(SentinelText.mappingOutsideSentinels("hello") { $0.uppercased() } == "HELLO")
    }

    @Test func literalRuleDoesNotMatchInsideTokenBody() {
        // `\bverb\b` matches "VERB" inside ⟦SN:VERB:1⟧ (colons are word boundaries) — but must not fire.
        var ctx = PipelineContext(text: "hello ⟦SN:VERB:1⟧ world")
        ReplacementsStage(rules: [ReplacementRule(heard: "verb", replace: "X", isRegex: false)]).apply(&ctx)
        #expect(ctx.text == "hello ⟦SN:VERB:1⟧ world")
    }

    @Test func regexRuleDoesNotRewriteTokenIndex() {
        var ctx = PipelineContext(text: "hello ⟦SN:VERB:1⟧ world")
        ReplacementsStage(rules: [ReplacementRule(heard: #"\d+"#, replace: "9", isRegex: true)]).apply(&ctx)
        #expect(ctx.text == "hello ⟦SN:VERB:1⟧ world")
    }

    @Test func replacementStillFiresOutsideTokens() {
        var ctx = PipelineContext(text: "teh ⟦SN:VERB:1⟧ teh")
        ReplacementsStage(rules: [ReplacementRule(heard: "teh", replace: "the", isRegex: false)]).apply(&ctx)
        #expect(ctx.text == "the ⟦SN:VERB:1⟧ the")
    }

    // The review's headline test: verbatim + replacements composed in one pipeline; the verbatim
    // content must survive forward+reverse and no sentinel may remain.
    @Test func verbatimContentSurvivesReplacementsRoundTrip() {
        let pipeline = Pipeline([
            ReplacementsStage(rules: [ReplacementRule(heard: "verb", replace: "X", isRegex: false)]),
            TokenizingStage.verbatim(),
        ])
        let payload = pipeline.forward("begin verbatim hunter2 end verbatim")
        let restored = pipeline.restore(payload.text)
        #expect(restored.contains("hunter2"))
        #expect(!restored.contains("⟦SN:"))
    }

    @Test func numbersStageLeavesTokenIndexAlone() {
        var ctx = PipelineContext(text: "call ⟦SN:VERB:1⟧ back")
        NumbersStage().apply(&ctx)
        #expect(ctx.text == "call ⟦SN:VERB:1⟧ back")
    }

    @Test func fuzzyStageDoesNotSnapTokenFragment() {
        // A dictionary term close to "VERB" must not fuzzy-correct the token fragment.
        var ctx = PipelineContext(text: "x ⟦SN:VERB:1⟧ y")
        FuzzyStage(terms: ["Verbatim", "Verb"]).apply(&ctx)
        #expect(ctx.text == "x ⟦SN:VERB:1⟧ y")
    }

    // A whole-utterance replacement over text carrying a protected token must not fire (fall through).
    @Test func bareReplacementSkippedWhenSentinelPresent() {
        let stage = ReplacementsStage(rules: [ReplacementRule(heard: "verb", replace: "X", isRegex: false)])
        #expect(stage.bareReplacement(for: "⟦SN:VERB:1⟧") == nil)
    }
}
