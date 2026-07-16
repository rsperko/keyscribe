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

    // Pausing around the markers made the STT insert commas that leaked into the protected content;
    // pause commas are absorbed on both sides.
    @Test func pauseCommasAroundMarkersAreAbsorbed() {
        let (out, t) = tokenize("make sure that the begin verbatim, new line, end verbatim, change is in place")
        #expect(out == "make sure that the ⟦SN:VERB:1⟧ change is in place")
        #expect(t.restore(out) == "make sure that the new line change is in place")
    }

    // Only pause whitespace/commas are trimmed — an intended terminator at the content edge stays.
    @Test func contentTerminatorIsPreserved() {
        let (out, t) = tokenize("say begin verbatim Hello! end verbatim done")
        #expect(t.restore(out) == "say Hello! done")
    }

    @Test func contentSemicolonIsPreserved() {
        let (out, t) = tokenize("code begin verbatim foo(); end verbatim done")
        #expect(t.restore(out) == "code foo(); done")
    }

    // A period after the end marker is a real sentence end, not a pause artifact — keep it.
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

    // Commas inside the content, not at the edges, are part of the protected literal.
    @Test func internalCommasInContentPreserved() {
        let (out, t) = tokenize("begin verbatim a, b, c end verbatim")
        #expect(t.restore(out) == "a, b, c")
    }

    @Test func leadingPeriodInContentPreserved() {
        let (out, t) = tokenize("begin verbatim .config end verbatim")
        #expect(t.restore(out) == ".config")
    }

    // Verbatim spans are NOT folded into a preceding clause (unlike inline clipboard pastes) — a
    // user-delimited span the speaker set off stays its own clause.
    @Test func verbatimIsNotFoldedIntoThePrecedingClause() {
        let (out, t) = tokenize("the config. begin verbatim foo end verbatim. Next")
        #expect(out == "the config. ⟦SN:VERB:1⟧. Next")
        #expect(t.restore(out) == "the config. foo. Next")
    }

    // A terminator glued to the begin marker (STT ending the "begin verbatim" clause on a pause) is a
    // command artifact and is stripped — unlike a space-separated content-leading terminal like
    // ".config" (leadingPeriodInContentPreserved), which survives.
    @Test func terminatorGluedToBeginMarkerIsStripped() {
        let (out, t) = tokenize("Begin verbatim. keep this end verbatim")
        #expect(t.restore(out) == "keep this")
    }

    // Pausing around the markers makes the STT terminate each clause with a period ("…sentence. Begin
    // verbatim. …contents. End verbatim. This…"). The begin-marker-glued period is stripped, the span
    // is not merged into the previous sentence, and the redundant post-end-marker period collapses into
    // the content's own.
    @Test func standaloneVerbatimWithPausesReadsCleanly() {
        let (out, t) = tokenize(
            "This is the start of the sentence. Begin verbatim. Insert the board contents. End verbatim. This is the end of the sentence.")
        let restored = t.restore(out)
        #expect(!restored.contains("sentence . Insert"))   // no floating space-period
        #expect(!restored.contains("sentence Insert"))      // not merged into the previous clause
        #expect(!restored.contains("contents.."))           // no double period
        #expect(restored == "This is the start of the sentence. Insert the board contents. This is the end of the sentence.")
    }

    // The content already ends a clause, so the redundant period the STT put after the end marker
    // (a pause artifact) is dropped — the content's own terminator stands.
    @Test func redundantPostMarkerTerminatorCollapses() {
        let (out, t) = tokenize("say begin verbatim done. end verbatim. Next")
        #expect(t.restore(out) == "say done. Next")
    }

    // The collapse never strips the content's own terminator — only the redundant post-marker period.
    @Test func intendedContentTerminatorSurvivesTheCollapse() {
        let (out, t) = tokenize("say begin verbatim Hello! end verbatim. Next")
        #expect(t.restore(out) == "say Hello! Next")
    }

    // Regex must resolve a wall of pause commas without catastrophic backtracking.
    @Test func manyCommasAroundMarkersResolve() {
        let (out, t) = tokenize("begin verbatim ,,, X ,,, end verbatim")
        #expect(out == "⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "X")
    }

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

    // No end heard: protect to end of utterance, keeping "begin verbatim" visible as the tell that it's unterminated.
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

    // With no open begin there is nothing to rescue.
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

    // "verbatim" is a rare, schwa-final word an on-device STT reliably mangles ("verbatum"); adjacent to
    // the "begin" marker word it is snapped back to the literal so the span still closes. lev<=1 with no
    // phonetic gate is safe here — "verbatim" has zero real English words within one edit.
    @Test func beginMarkerKeywordMishearIsSnapped() {
        let (out, t) = tokenize("say begin verbatum KeepThis end verbatim done")
        #expect(out == "say ⟦SN:VERB:1⟧ done")
        #expect(t.restore(out) == "say KeepThis done")
    }

    // The dropped-r mishear ("vebatim") changes the consonant skeleton, so a phonetic-key gate would
    // reject it; lev-only still catches it since the edit-distance neighbourhood is otherwise empty.
    @Test func endMarkerDroppedConsonantMishearIsSnapped() {
        let (out, t) = tokenize("say begin verbatim KeepThis end vebatim done")
        #expect(out == "say ⟦SN:VERB:1⟧ done")
        #expect(t.restore(out) == "say KeepThis done")
    }

    // Both markers mistranscribed at once ("begin verbatum … end vebatim") must still close.
    @Test func bothMarkerKeywordsMisheardStillCloses() {
        let (out, t) = tokenize("blah blah begin verbatum text in between end vebatim blah blah")
        #expect(out == "blah blah ⟦SN:VERB:1⟧ blah blah")
        #expect(t.restore(out) == "blah blah text in between blah blah")
    }

    @Test func misheardKeywordWithPauseCommaFires() {
        let (out, t) = tokenize("say begin, verbatum KeepThis end, vebatim done")
        #expect(out == "say ⟦SN:VERB:1⟧ done")
        #expect(t.restore(out) == "say KeepThis done")
    }

    // A verbatim-like word not adjacent to a marker word is content — the snap must not "correct"
    // dictated prose or corrupt the inside of a span.
    @Test func misheardKeywordAwayFromMarkerIsNotSnapped() {
        let (out, _) = tokenize("the verbatum note is here")
        #expect(out == "the verbatum note is here")
    }

    @Test func endLikeKeywordMishearWithoutAnEarlierBeginIsNotSnapped() {
        let (out, _) = tokenize("and verbatum")
        #expect(out == "and verbatum")
    }

    @Test func sentencePunctuationBetweenMarkerWordsDoesNotSnapAMishear() {
        let (out, _) = tokenize("begin. Verbatum")
        #expect(out == "begin. Verbatum")
    }

    @Test func leadingPunctuationBeforeBeginMarkerStillSnapsAMishear() {
        let (out, t) = tokenize("(begin verbatum KeepThis end verbatim")
        #expect(out == "(⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "(KeepThis")
    }

    @Test func leadingPunctuationBeforeEndLikeMarkerStillSnapsAMishear() {
        let (out, t) = tokenize("begin verbatim KeepThis (and verbatum")
        #expect(out == "⟦SN:VERB:1⟧")
        #expect(t.restore(out) == "KeepThis (")
    }
}
