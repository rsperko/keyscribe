import Testing
@testable import KeyScribeKit

// Counts lazy clipboard-provider invocations from inside a @Sendable stage closure. The pipeline runs
// its stages synchronously on one thread in these tests, so the unchecked box never actually races.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func bump() { value += 1 }
}

// Verbatim/redaction as pipeline commands (design.md §4.2.1): verbatim sorts before the text stages
// so its span is protected from everything except STT; redaction sorts after; restore() unwinds
// both in strict LIFO.
struct TokenizingStageTests {
    @Test func verbatimContentSurvivesTextStages() {
        // "cat"→"dog" must transform the loose word but never the verbatim-wrapped one.
        let p = Pipeline([
            TokenizingStage.verbatim(),
            ReplacementsStage(rules: [ReplacementRule(heard: "cat", replace: "dog", isRegex: false)]),
        ])
        let payload = p.forward("a cat begin verbatim a cat end verbatim")
        #expect(payload.issuedTokens.count == 1)
        #expect(!payload.text.contains("end verbatim"))   // markers stripped
        #expect(p.restore(payload.text) == "a dog a cat")  // loose word replaced, wrapped word preserved
    }

    @Test func verbatimContentSurvivesNumbersStage() {
        let p = Pipeline([
            TokenizingStage.verbatim(),
            NumbersStage(),
        ])
        let payload = p.forward("twenty five begin verbatim twenty five end verbatim")
        #expect(p.restore(payload.text) == "25 twenty five")
    }

    @Test func redactionTokenizesAfterTextStagesAndRestores() {
        let p = Pipeline([
            ReplacementsStage(rules: []),
            TokenizingStage.redaction(),
        ])
        let payload = p.forward("email me at alice@example.com")
        #expect(!payload.text.contains("alice@example.com"))
        #expect(payload.issuedTokens.count == 1)
        #expect(p.restore(payload.text) == "email me at alice@example.com")
    }

    // Both stages issue tokens; restore restores redaction (last in) before verbatim (first in).
    @Test func verbatimAndRedactionUnwindLIFO() {
        let p = Pipeline([
            TokenizingStage.verbatim(),
            TokenizingStage.redaction(),
        ])
        let payload = p.forward("begin verbatim my note end verbatim contact alice@example.com")
        #expect(payload.text.contains("⟦SN:VERB:1⟧"))
        #expect(payload.text.contains("⟦SN:REDACT:1⟧"))
        #expect(payload.issuedTokens.count == 2)
        #expect(p.restore(payload.text) == "my note contact alice@example.com")
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
        #expect(p.forward("hi").issuedTokens == ["⟦SN:REDACT:1⟧"])
    }

    @Test func plainTextStageContributesNoTokens() {
        let p = Pipeline([ReplacementsStage(rules: []), NumbersStage()])
        #expect(p.forward("hi").issuedTokens.isEmpty)
    }

    // "insert clipboard contents" pulls the clipboard into a verbatim token before the text stages,
    // so the pasted content is opaque to replacements/numbers and to the LLM, then restored.
    @Test func clipboardContentSurvivesTextStages() {
        let p = Pipeline([
            TokenizingStage.clipboard(read: { "twenty five" }),
            NumbersStage(),
        ])
        let payload = p.forward("count twenty five insert clipboard contents")
        #expect(payload.issuedTokens.count == 1)
        #expect(p.restore(payload.text) == "count 25 twenty five")   // loose number converted, pasted one preserved
    }

    // A verbatim span and a clipboard paste in the SAME dictation must not collide: verbatim mints a
    // VERB token and clipboard a CLIP token, so restore keeps them independent (a shared token string
    // would let the clipboard's reverse pass overwrite the verbatim span, leaking clipboard content).
    @Test func verbatimAndClipboardDoNotCollide() {
        let p = Pipeline([
            TokenizingStage.verbatim(),
            TokenizingStage.clipboard(read: { "B" }),
        ])
        let payload = p.forward("begin verbatim A end verbatim and insert clipboard contents")
        #expect(payload.issuedTokens.count == 2)
        #expect(Set(payload.issuedTokens).count == 2)   // two DISTINCT tokens, not one string reused
        #expect(p.restore(payload.text) == "A and B")
    }

    // A clipboard phrase INSIDE a verbatim span is literal text, not a paste: verbatim sorts before
    // clipboard, so it swallows the phrase first and clipboard never fires — AND, because the read is
    // lazy, the host's clipboard is never even read (privacy: a phrase in a verbatim span must not
    // trigger a pasteboard read).
    @Test func clipboardPhraseInsideVerbatimStaysLiteral() {
        let reads = Counter()
        let p = Pipeline([
            TokenizingStage.verbatim(),
            TokenizingStage.clipboard(read: { reads.bump(); return "PASTED" }),
        ])
        let payload = p.forward("begin verbatim insert clipboard contents end verbatim")
        #expect(payload.issuedTokens.count == 1)
        #expect(p.restore(payload.text) == "insert clipboard contents")
        #expect(reads.value == 0)
    }

    // The mirror of the above: a real (unwrapped) paste DOES read the clipboard exactly once.
    @Test func clipboardPhraseOutsideVerbatimReadsOnce() {
        let reads = Counter()
        let p = Pipeline([
            TokenizingStage.verbatim(),
            TokenizingStage.clipboard(read: { reads.bump(); return "PASTED" }),
        ])
        let payload = p.forward("insert clipboard contents")
        #expect(payload.issuedTokens.count == 1)
        #expect(p.restore(payload.text) == "PASTED")
        #expect(reads.value == 1)
    }

    // Two verbatim spans with EQUAL content must stay distinct tokens (dedup: false), or a faithful
    // LLM rewrite that reproduces both occurrences can never satisfy the gate's exactly-once check
    // (H2: a deduped token appearing twice always fails ValidationGate's `count > 1` rule).
    @Test func repeatedVerbatimSpanGetsDistinctTokens() {
        let p = Pipeline([TokenizingStage.verbatim()])
        let payload = p.forward("begin verbatim hello end verbatim then begin verbatim hello end verbatim")
        #expect(payload.issuedTokens == ["⟦SN:VERB:1⟧", "⟦SN:VERB:2⟧"])
        #expect(ValidationGate.check(output: payload.text, issuedTokens: payload.issuedTokens) == .pass)
        #expect(p.restore(payload.text) == "hello then hello")
    }

    // The gate's issuedTokens survive an LLM that preserves them; restore then restores the originals.
    @Test func tokensSurviveAPreservingRewriteThenRestore() {
        let v = Tokenizer()
        let p = Pipeline([TokenizingStage.verbatim(tokenizer: v)])
        let payload = p.forward("begin verbatim keep me end verbatim please")
        let token = payload.issuedTokens.first!
        // A faithful rewrite reproduces the token verbatim while editing around it.
        let edited = payload.text.replacingOccurrences(of: "please", with: "thanks")
        #expect(ValidationGate.check(output: edited, issuedTokens: payload.issuedTokens) == .pass)
        #expect(p.restore(edited) == "keep me thanks")
        #expect(token == "⟦SN:VERB:1⟧")
    }
}
