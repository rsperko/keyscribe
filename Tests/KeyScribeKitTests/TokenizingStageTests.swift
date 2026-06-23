import Testing
@testable import KeyScribeKit

// Verbatim/redaction as pipeline commands (design.md §4.2.1): verbatim sorts before the text stages
// so its span is protected from everything except STT; redaction sorts after; reverse() unwinds
// both in strict LIFO.
struct TokenizingStageTests {
    @Test func verbatimContentSurvivesTextStages() {
        // "cat"→"dog" must transform the loose word but never the verbatim-wrapped one.
        let p = Pipeline([
            TokenizingStage.verbatim(),
            ReplacementsStage(rules: [ReplacementRule(heard: "cat", replace: "dog", isRegex: false)]),
        ])
        var ctx = PipelineContext(text: "a cat begin verbatim a cat end verbatim")
        p.forward(&ctx)
        #expect(p.issuedTokens.count == 1)
        #expect(!ctx.text.contains("end verbatim"))   // markers stripped
        p.reverse(&ctx)
        #expect(ctx.text == "a dog a cat")            // loose word replaced, wrapped word preserved
    }

    @Test func verbatimContentSurvivesNumbersStage() {
        let p = Pipeline([
            TokenizingStage.verbatim(),
            NumbersStage(),
        ])
        var ctx = PipelineContext(text: "twenty five begin verbatim twenty five end verbatim")
        p.forward(&ctx)
        p.reverse(&ctx)
        #expect(ctx.text == "25 twenty five")
    }

    @Test func redactionTokenizesAfterTextStagesAndRestores() {
        let p = Pipeline([
            ReplacementsStage(rules: []),
            TokenizingStage.redaction(),
        ])
        var ctx = PipelineContext(text: "email me at alice@example.com")
        p.forward(&ctx)
        #expect(!ctx.text.contains("alice@example.com"))
        #expect(p.issuedTokens.count == 1)
        p.reverse(&ctx)
        #expect(ctx.text == "email me at alice@example.com")
    }

    // Both stages issue tokens; reverse restores redaction (last in) before verbatim (first in).
    @Test func verbatimAndRedactionUnwindLIFO() {
        let p = Pipeline([
            TokenizingStage.verbatim(),
            TokenizingStage.redaction(),
        ])
        var ctx = PipelineContext(text: "begin verbatim my note end verbatim contact alice@example.com")
        p.forward(&ctx)
        #expect(ctx.text.contains("⟦SN:VERB:1⟧"))
        #expect(ctx.text.contains("⟦SN:REDACT:1⟧"))
        #expect(p.issuedTokens.count == 2)
        p.reverse(&ctx)
        #expect(ctx.text == "my note contact alice@example.com")
    }

    // issuedTokens is part of the PipelineStage contract, not an optional downcast: any stage that
    // returns tokens is collected for the gate, and a plain text stage defaults to none — so a
    // tokenizing stage can never silently escape the validation gate by forgetting a marker protocol.
    private struct TokenIssuingStage: PipelineStage {
        let position = StagePosition.postSTTMark
        let order = 0
        func apply(_ context: inout PipelineContext) {}
        var issuedTokens: [String] { ["⟦SN:REDACT:1⟧"] }
    }

    @Test func anyStageReturningTokensIsCollected() {
        let p = Pipeline([ReplacementsStage(rules: []), TokenIssuingStage()])
        #expect(p.issuedTokens == ["⟦SN:REDACT:1⟧"])
    }

    @Test func plainTextStageContributesNoTokens() {
        let p = Pipeline([ReplacementsStage(rules: []), NumbersStage()])
        #expect(p.issuedTokens.isEmpty)
    }

    // The gate's issuedTokens survive an LLM that preserves them; reverse then restores the originals.
    @Test func tokensSurviveAPreservingRewriteThenRestore() {
        let v = Tokenizer()
        let p = Pipeline([TokenizingStage.verbatim(tokenizer: v)])
        var ctx = PipelineContext(text: "begin verbatim keep me end verbatim please")
        p.forward(&ctx)
        let token = p.issuedTokens.first!
        // A faithful rewrite reproduces the token verbatim while editing around it.
        ctx.text = ctx.text.replacingOccurrences(of: "please", with: "thanks")
        #expect(ValidationGate.check(output: ctx.text, issuedTokens: p.issuedTokens) == .pass)
        p.reverse(&ctx)
        #expect(ctx.text == "keep me thanks")
        #expect(token == "⟦SN:VERB:1⟧")
    }
}
