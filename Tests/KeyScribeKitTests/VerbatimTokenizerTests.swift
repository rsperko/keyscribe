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

    // The reported bug: pausing around the markers made the STT insert commas, which leaked into the
    // protected content and stranded outside the markers. Pause commas are now absorbed on both sides.
    @Test func pauseCommasAroundMarkersAreAbsorbed() {
        let (out, t) = tokenize("make sure that the begin verbatim, new line, end verbatim, change is in place")
        #expect(out == "make sure that the ⟦SN:VERB:1⟧ change is in place")
        #expect(t.restore(out) == "make sure that the new line change is in place")
    }

    // Content edges keep intended terminators/semicolons — only pause whitespace/commas are trimmed.
    @Test func contentTerminatorIsPreserved() {
        let (out, t) = tokenize("say begin verbatim Hello! end verbatim done")
        #expect(t.restore(out) == "say Hello! done")
    }

    @Test func contentSemicolonIsPreserved() {
        let (out, t) = tokenize("code begin verbatim foo(); end verbatim done")
        #expect(t.restore(out) == "code foo(); done")
    }

    // A period after the end marker is a real sentence end — keep it attached, do not absorb it.
    @Test func periodAfterEndMarkerIsPreserved() {
        let (out, t) = tokenize("begin verbatim note end verbatim. Next")
        #expect(out == "⟦SN:VERB:1⟧. Next")
        #expect(t.restore(out) == "note. Next")
    }

    @Test func commaBeforeBeginMarkerIsAbsorbed() {
        let (out, t) = tokenize("note, begin verbatim X end verbatim done")
        #expect(out == "note ⟦SN:VERB:1⟧ done")
        #expect(t.restore(out) == "note X done")
    }

    // Commas INSIDE the content (not at the edges) are part of the protected literal — keep them.
    @Test func internalCommasInContentPreserved() {
        let (out, t) = tokenize("begin verbatim a, b, c end verbatim")
        #expect(t.restore(out) == "a, b, c")
    }

    @Test func leadingPeriodInContentPreserved() {
        let (out, t) = tokenize("begin verbatim .config end verbatim")
        #expect(t.restore(out) == ".config")
    }

    // Bracketed-terminator fold applies to verbatim too: a spurious leading period is dropped and
    // relocated past the (untouched) protected content.
    @Test func bracketedTerminatorFolds() {
        let (out, t) = tokenize("the config. begin verbatim foo end verbatim. Next")
        #expect(out == "the config ⟦SN:VERB:1⟧. Next")
        #expect(t.restore(out) == "the config foo. Next")
    }

    // A wall of pause commas around the markers must resolve (and not backtrack pathologically).
    @Test func manyCommasAroundMarkersResolve() {
        let (out, t) = tokenize("begin verbatim ,,, X ,,, end verbatim")
        #expect(out == "⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "X")
    }

    @Test func unterminatedTrimsLeadingCommaAndPrecedingComma() {
        let (out, t) = tokenize("the note, begin verbatim my secret")
        #expect(out == "the note ⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "the note my secret")
    }

    @Test func commaDirectlyAttachedToMarkersIsAbsorbed() {
        let (out, t) = tokenize("say begin verbatim,X,end verbatim done")
        #expect(t.restore(out) == "say X done")
    }

    @Test func multilineContentIsPreserved() {
        let (out, t) = tokenize("begin verbatim line1\nline2 end verbatim")
        #expect(t.restore(out) == "line1\nline2")
    }

    @Test func multipleSpansWithCommasBetweenAbsorb() {
        let (out, t) = tokenize("begin verbatim A end verbatim, and, begin verbatim B end verbatim")
        #expect(out == "⟦SN:VERB:1⟧ and ⟦SN:VERB:2⟧")
        #expect(t.restore(out) == "A and B")
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

    // Only "begin verbatim" / "end verbatim" are triggers now — the start/stop aliases are dropped
    // and pass through as ordinary text.
    @Test func droppedStartStopAliasesAreLiteral() {
        let (out, _) = tokenize("say start verbatim KeepThis stop verbatim done")
        #expect(out == "say start verbatim KeepThis stop verbatim done")
    }

    @Test func droppedStartVerbatimDoesNotTokenize() {
        let (out, _) = tokenize("the password is start verbatim hunter2 and more")
        #expect(out == "the password is start verbatim hunter2 and more")
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
