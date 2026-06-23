import Testing
@testable import KeyScribeKit

// Verbatim/redaction as pipeline commands (design.md §4.2.1): verbatim sorts before the text stages
// so its span is protected from everything except STT; redaction sorts after; reverse() unwinds
// both in strict LIFO.
struct TokenizingStageTests {
    @Test func verbatimContentSurvivesTextStages() {
        // "cat"→"dog" must transform the loose word but never the verbatim-wrapped one.
        let p = Pipeline([
            VerbatimStage(tokenizer: Tokenizer()),
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
            VerbatimStage(tokenizer: Tokenizer()),
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
            RedactionStage(tokenizer: Tokenizer()),
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
            VerbatimStage(tokenizer: Tokenizer()),
            RedactionStage(tokenizer: Tokenizer()),
        ])
        var ctx = PipelineContext(text: "begin verbatim my note end verbatim contact alice@example.com")
        p.forward(&ctx)
        #expect(ctx.text.contains("⟦SN:VERB:1⟧"))
        #expect(ctx.text.contains("⟦SN:REDACT:1⟧"))
        #expect(p.issuedTokens.count == 2)
        p.reverse(&ctx)
        #expect(ctx.text == "my note contact alice@example.com")
    }

    // The gate's issuedTokens survive an LLM that preserves them; reverse then restores the originals.
    @Test func tokensSurviveAPreservingRewriteThenRestore() {
        let v = Tokenizer()
        let p = Pipeline([VerbatimStage(tokenizer: v)])
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
