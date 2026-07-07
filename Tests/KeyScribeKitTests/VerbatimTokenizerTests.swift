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

    // Verbatim spans are NOT folded into a preceding clause (unlike inline clipboard pastes): a
    // user-delimited span that the speaker set off stays its own clause. (Previously folded to
    // "the config foo. Next"; that merge was wrong for a standalone span — see the pause-around-markers
    // report and standaloneVerbatimWithPausesIsNotMerged below.)
    @Test func verbatimIsNotFoldedIntoThePrecedingClause() {
        let (out, t) = tokenize("the config. begin verbatim foo end verbatim. Next")
        #expect(out == "the config. ⟦SN:VERB:1⟧. Next")
        #expect(t.restore(out) == "the config. foo. Next")
    }

    // A terminator GLUED to the begin marker (the STT ending the "begin verbatim" clause on a pause) is
    // a command artifact and is stripped — distinct from a space-separated content-leading terminal
    // like ".config" (leadingPeriodInContentPreserved), which survives.
    @Test func terminatorGluedToBeginMarkerIsStripped() {
        let (out, t) = tokenize("Begin verbatim. keep this end verbatim")
        #expect(t.restore(out) == "keep this")
    }

    // The reported case: pausing around the markers makes the STT terminate each clause with a period
    // ("…sentence. Begin verbatim. …contents. End verbatim. This…"). The begin-marker-glued period is
    // stripped, the span is not merged into the previous sentence, and the redundant post-end-marker
    // period collapses into the content's own — so the whole utterance reads cleanly.
    @Test func standaloneVerbatimWithPausesReadsCleanly() {
        let (out, t) = tokenize(
            "This is the start of the sentence. Begin verbatim. Insert the board contents. End verbatim. This is the end of the sentence.")
        let restored = t.restore(out)
        #expect(!restored.contains("sentence . Insert"))   // no floating space-period (was the bug)
        #expect(!restored.contains("sentence Insert"))      // not merged into the previous clause
        #expect(!restored.contains("contents.."))           // no double period (was the bug)
        #expect(restored == "This is the start of the sentence. Insert the board contents. This is the end of the sentence.")
    }

    // Safe trailing-collapse: the content already ends a clause, so the redundant period the STT put
    // after the end marker (a pause artifact) is dropped — the content's terminator stands.
    @Test func redundantPostMarkerTerminatorCollapses() {
        let (out, t) = tokenize("say begin verbatim done. end verbatim. Next")
        #expect(t.restore(out) == "say done. Next")
    }

    // The collapse NEVER strips the content's own terminator: an intended "Hello!" survives, and only
    // the redundant post-marker period is dropped.
    @Test func intendedContentTerminatorSurvivesTheCollapse() {
        let (out, t) = tokenize("say begin verbatim Hello! end verbatim. Next")
        #expect(t.restore(out) == "say Hello! Next")
    }

    // A wall of pause commas around the markers must resolve (and not backtrack pathologically).
    @Test func manyCommasAroundMarkersResolve() {
        let (out, t) = tokenize("begin verbatim ,,, X ,,, end verbatim")
        #expect(out == "⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "X")
    }

    // Unclosed span keeps "begin verbatim" visible; the preceding pause comma is still absorbed.
    @Test func unterminatedTrimsLeadingCommaAndKeepsMarker() {
        let (out, t) = tokenize("the note, begin verbatim my secret")
        #expect(out == "the note ⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "the note begin verbatim my secret")
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

    // A pause-comma BETWEEN the trigger words ("begin, verbatim") must still fire the marker — the STT
    // transcribes a spoken pause mid-phrase as a comma. Shared with the clipboard command joiner.
    @Test func pauseCommaInsideTriggerWordsStillFires() {
        let (out, t) = tokenize("say begin, verbatim KeepThis end, verbatim done")
        #expect(out == "say ⟦SN:VERB:1⟧ done")
        #expect(t.restore(out) == "say KeepThis done")
    }

    // No end heard: protect to end of utterance, keeping "begin verbatim" visible as the tell.
    @Test func unterminatedTokenizesToEndKeepingMarker() {
        let (out, t) = tokenize("the password is begin verbatim hunter2 more")
        #expect(out == "the password is ⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "the password is begin verbatim hunter2 more")
    }

    // The kept marker is INSIDE the token value (not plain text beside it), so it survives an LLM
    // rewrite — the post-LLM gate only guarantees nonce tokens, not surrounding prose.
    @Test func unterminatedMarkerIsProtectedInsideToken() {
        let (out, t) = tokenize("begin verbatim my secret")
        #expect(!out.contains("begin verbatim"))
        #expect(t.restore(out) == "begin verbatim my secret")
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

    @Test func unterminatedAtStartKeepsMarkerNoLeadingSpace() {
        let (out, t) = tokenize("begin verbatim secret stuff")
        #expect(out == "⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "begin verbatim secret stuff")
    }

    @Test func bareBeginVerbatimWithNoContentIsLeftAlone() {
        let (out, _) = tokenize("just text begin verbatim")
        #expect(out == "just text begin verbatim")
    }

    // A misheard "end verbatim" (Apple's "and"↔"end" vowel swap) still closes the span.
    @Test func rescueClosesOnEndLikeAndVerbatim() {
        let (out, t) = tokenize("begin verbatim foo and verbatim bar")
        #expect(out == "⟦SN:VERB:1⟧ bar")
        #expect(t.restore(out) == "foo bar")
    }

    // Parakeet's real mishear drops the final consonant ("en verbatim"); the phonetic prefix still closes it.
    @Test func rescueClosesOnEnVerbatim() {
        let (out, t) = tokenize("begin verbatim foo en verbatim bar")
        #expect(out == "⟦SN:VERB:1⟧ bar")
        #expect(t.restore(out) == "foo bar")
    }

    // A non-"end" lookalike ("send" → phonetic key "253", not a prefix of "53") is not a closer.
    @Test func rescueRejectsNonEndLikeLookalike() {
        let (out, t) = tokenize("begin verbatim send verbatim files")
        #expect(out == "⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "begin verbatim send verbatim files")
    }

    // Exact "end verbatim" wins: a stray "and verbatim" earlier stays content, not an early close.
    @Test func exactEndPreferredOverRescue() {
        let (out, t) = tokenize("begin verbatim foo and verbatim bar end verbatim baz")
        #expect(out == "⟦SN:VERB:1⟧ baz")
        #expect(t.restore(out) == "foo and verbatim bar baz")
    }

    // With no open begin there is nothing to rescue — prose containing "and verbatim" is untouched.
    @Test func loneEndLikePhraseWithoutBeginIsInert() {
        let (out, _) = tokenize("quote it and verbatim please")
        #expect(out == "quote it and verbatim please")
    }

    // Characterization: spans are flat (first begin ↔ first end); a leftover marker stays literal.
    @Test func nestedBeginsTakeFirstEndAndLeaveTrailingMarkerLiteral() {
        let (out, t) = tokenize("begin verbatim outer begin verbatim inner end verbatim tail end verbatim")
        #expect(out == "⟦SN:VERB:1⟧ tail end verbatim")
        #expect(t.restore(out) == "outer begin verbatim inner tail end verbatim")
    }

    @Test func twoEndsOneBeginLeavesSecondEndLiteral() {
        let (out, t) = tokenize("begin verbatim A end verbatim B end verbatim")
        #expect(out == "⟦SN:VERB:1⟧ B end verbatim")
        #expect(t.restore(out) == "A B end verbatim")
    }

    @Test func twoBeginsOneEndSwallowsInnerBeginAsContent() {
        let (out, t) = tokenize("begin verbatim A begin verbatim B end verbatim")
        #expect(out == "⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "A begin verbatim B")
    }
}
