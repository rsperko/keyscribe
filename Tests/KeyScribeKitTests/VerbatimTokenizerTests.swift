import Testing
@testable import KeyScribeKit

private func tokenize(_ text: String) -> (out: String, tok: Tokenizer) {
    let t = Tokenizer()
    return (VerbatimTokenizer.apply(text, into: t), t)
}

struct VerbatimTokenizerTests {
    @Test func pullsSpanIntoSingleToken() {
        let (out, t) = tokenize("the function is begin verbatim ProcessData end verbatim okay")
        #expect(out == "the function is ⟦SN:VERB:1⟧ okay")
        #expect(t.restore(out) == "the function is ProcessData okay")
    }

    @Test func multipleSpansDistinctTokens() {
        let (out, _) = tokenize("begin verbatim A end verbatim then begin verbatim B end verbatim")
        #expect(out == "⟦SN:VERB:1⟧ then ⟦SN:VERB:2⟧")
    }

    @Test func caseInsensitiveTriggers() {
        let (out, t) = tokenize("say Begin Verbatim KeepThis END VERBATIM done")
        #expect(out == "say ⟦SN:VERB:1⟧ done")
        #expect(t.restore(out) == "say KeepThis done")
    }

    @Test func unterminatedTokenizesToEnd() {
        let (out, t) = tokenize("the password is begin verbatim hunter2 and more")
        #expect(out == "the password is ⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "the password is hunter2 and more")
    }

    @Test func startStopTriggerAliases() {
        for (begin, end) in [("start verbatim", "end verbatim"),
                             ("begin verbatim", "stop verbatim"),
                             ("start verbatim", "stop verbatim")] {
            let (out, t) = tokenize("say \(begin) KeepThis \(end) done")
            #expect(out == "say ⟦SN:VERB:1⟧ done")
            #expect(t.restore(out) == "say KeepThis done")
        }
    }

    @Test func unterminatedStartTokenizesToEnd() {
        let (out, t) = tokenize("the password is start verbatim hunter2 and more")
        #expect(out == "the password is ⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "the password is hunter2 and more")
    }

    @Test func noVerbatimLeavesTextUnchanged() {
        let (out, _) = tokenize("just a normal sentence")
        #expect(out == "just a normal sentence")
    }

    @Test func contentNeverRemainsInTokenizedText() {
        // the whole point: the protected span must not appear in what goes to the LLM
        let (out, _) = tokenize("begin verbatim TopSecret end verbatim")
        #expect(!out.contains("TopSecret"))
    }

    @Test func unterminatedAtStartHasNoLeadingSpace() {
        let (out, t) = tokenize("begin verbatim secret stuff")
        #expect(out == "⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "secret stuff")
    }

    @Test func bareBeginVerbatimWithNoContentIsLeftAlone() {
        let (out, _) = tokenize("just text begin verbatim")
        #expect(out == "just text begin verbatim")
    }
}
