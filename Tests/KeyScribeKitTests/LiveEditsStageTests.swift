import Testing
@testable import KeyScribeKit

private func run(_ text: String) -> String {
    var ctx = PipelineContext(text: text)
    LiveEditsStage().apply(&ctx)
    return ctx.text
}

struct LiveEditsStageTests {
    @Test func newLineCommand() {
        #expect(run("alpha insert new line beta") == "alpha\nbeta")
    }

    @Test func newLineArticleVariant() {
        #expect(run("alpha insert a new line beta") == "alpha\nbeta")
    }

    @Test func newLineCompoundVariant() {
        #expect(run("alpha insert a newline beta") == "alpha\nbeta")
    }

    @Test func newLineShortCompoundVariant() {
        #expect(run("alpha insert newline beta") == "alpha\nbeta")
    }

    @Test func newParagraphCommand() {
        #expect(run("alpha insert new paragraph beta") == "alpha\n\nbeta")
    }

    @Test func newParagraphArticleVariant() {
        #expect(run("alpha insert a new paragraph beta") == "alpha\n\nbeta")
    }

    @Test func tabCommandInsertsTab() {
        #expect(run("def foo insert tab character bar") == "def foo\tbar")
    }

    @Test func tabArticleVariant() {
        #expect(run("def foo insert a tab character bar") == "def foo\tbar")
    }

    @Test func commandsAreCaseInsensitive() {
        #expect(run("alpha Insert New Line beta") == "alpha\nbeta")
    }

    // Pause commas the STT hangs around a command are absorbed with it (commas only).
    @Test func absorbsPauseCommasAroundNewline() {
        #expect(run("blah, insert new line, foo") == "blah\nfoo")
    }

    @Test func absorbsPauseCommasAroundParagraph() {
        #expect(run("blah, insert new paragraph, foo") == "blah\n\nfoo")
    }

    @Test func absorbsPauseCommasAroundTab() {
        #expect(run("def foo, insert tab character, bar") == "def foo\tbar")
    }

    // A pause comma the STT hangs INSIDE a command ("insert, new line") is a prosody artifact, not
    // content — the command still fires and the comma is consumed with it.
    @Test func interiorPauseCommaStillFires() {
        #expect(run("insert, new line") == "\n")
        #expect(run("alpha insert, new line beta") == "alpha\nbeta")
    }

    @Test func interiorPauseCommaOnLaterWordFires() {
        #expect(run("insert new, paragraph") == "\n\n")
        #expect(run("insert tab, character here") == "\there")
    }

    // Same pause, tokenized as a standalone comma ("insert , new line") instead of hung on a word.
    @Test func interiorStandaloneCommaTokenStillFires() {
        #expect(run("insert , new line") == "\n")
        #expect(run("alpha insert , new line beta") == "alpha\nbeta")
        #expect(run("insert new , paragraph") == "\n\n")
    }

    @Test func interiorMultipleStandaloneCommaTokensStillFire() {
        #expect(run("insert , , new line") == "\n")
    }

    @Test func interiorPauseCommaScratchFiresAtBoundary() {
        #expect(run("drop this scratch, that") == "")
        #expect(run("drop this scratch , that") == "")
    }

    // A standalone comma inside a scratch phrase does not override the clause-boundary gate: a
    // continuing word after "that" still means literal text.
    @Test func standaloneCommaScratchWithTrailingWordIsLiteral() {
        #expect(run("scratch , that lottery ticket") == "scratch , that lottery ticket")
    }

    // Interior PERIODS are left to block a match on purpose: a real sentence boundary must survive
    // rather than be eaten by the command ("insert new." ends a sentence; "Paragraph two…" begins one).
    @Test func interiorPeriodDoesNotFireCommand() {
        #expect(run("insert new. paragraph two covers") == "insert new. paragraph two covers")
    }

    // A preceding sentence period is real punctuation, not a pause artifact — keep it.
    @Test func preservesPrecedingPeriod() {
        #expect(run("done. insert new paragraph next") == "done.\n\nnext")
    }

    @Test func absorbsStandaloneCommaTokenBeforeCommand() {
        #expect(run("blah , insert new line foo") == "blah\nfoo")
    }

    @Test func absorbsMultipleStandaloneCommasAfterCommand() {
        #expect(run("insert new line , , foo") == "\nfoo")
    }

    @Test func commandAtStartAbsorbsLeadingComma() {
        #expect(run(", insert new line foo") == "\nfoo")
    }

    @Test func commandAtEndAbsorbsTrailingComma() {
        #expect(run("foo insert new line,") == "foo\n")
    }

    @Test func multipleCommandsWithPauseCommas() {
        #expect(run("a, insert new line, b, insert new paragraph, c") == "a\nb\n\nc")
    }

    // Only commas are absorbed as pause artifacts — colon, semicolon, and terminators on a preceding
    // word are real punctuation and are preserved.
    @Test func preservesPrecedingColon() {
        #expect(run("note: insert new line body") == "note:\nbody")
    }

    @Test func preservesPrecedingSemicolon() {
        #expect(run("foo; insert new line bar") == "foo;\nbar")
    }

    @Test func preservesPrecedingQuestionMark() {
        #expect(run("really? insert new paragraph yes") == "really?\n\nyes")
    }

    @Test func adjacentCommandsWithCommaBetween() {
        #expect(run("insert new line, insert new paragraph foo") == "\n\n\nfoo")
    }

    @Test func absorbsPrecedingCommaAndCommandOwnPeriod() {
        #expect(run("he left, insert new line. home") == "he left\nhome")
    }

    @Test func trailingSeparatorOnCommandWordStillFires() {
        #expect(run("alpha insert new line; beta") == "alpha\nbeta")
    }

    @Test func multipleCommandsInSequence() {
        #expect(run("one insert new line two insert new paragraph three") == "one\ntwo\n\nthree")
    }

    @Test func scratchThatRemovesCurrentSentence() {
        #expect(run("I like cats. I like dogs, scratch that. I like fish")
            == "I like cats. I like fish")
    }

    @Test func scratchThatBackToNewline() {
        // a newline command also bounds a segment
        #expect(run("keep this insert new line drop this scratch that. final")
            == "keep this\nfinal")
    }

    @Test func plainTextPassesThrough() {
        #expect(run("just a normal sentence") == "just a normal sentence")
    }

    @Test func scratchThatAtStartIsNoOp() {
        #expect(run("scratch that. hello") == "hello")
    }

    @Test func scratchThatEmptySegmentEatsPreviousSentence() {
        // nothing dictated since the last terminator: fall back to the one previous sentence
        #expect(run("done. scratch that. more") == "more")
    }

    @Test func scratchThatEatsPreviousSentenceAcrossPeriod() {
        // a punctuating STT (e.g. Whisper) ends the clause with a period, leaving an empty
        // segment; scratch still removes the sentence just spoken, and only that one
        #expect(run("blah blah. I don't know what I am saying here. scratch that. blah blah blah")
            == "blah blah. blah blah blah")
    }

    @Test func scratchAfterNewlineCancelsTheNewline() {
        // a scratch immediately after a command cancels that command rather than reaching past it
        #expect(run("keep this insert new line scratch that. final")
            == "keep this final")
    }

    @Test func scratchThatEmptySegmentStopsAtComma() {
        // the fallback removes one clause, not the whole comma-spliced sentence
        #expect(run("eggs, milk, bread. scratch that. done")
            == "eggs, milk, done")
    }

    @Test func scratchThatEmptySegmentStopsAtSemicolon() {
        #expect(run("first part; second part. scratch that. rest")
            == "first part; rest")
    }

    @Test func scratchThatFollowedByWordIsLiteral() {
        // a continuing word means it is not a clause boundary — leave it as text
        #expect(run("I told her to scratch that lottery ticket and see if we won")
            == "I told her to scratch that lottery ticket and see if we won")
    }

    @Test func scratchThatDogIsLiteral() {
        // a continuing word after "that" is not a boundary — the trigger never fires
        #expect(run("I told them to scratch that dog")
            == "I told them to scratch that dog")
    }

    @Test func scratchThatRunOnWithoutBoundaryIsLiteral() {
        // no terminator and not end-of-utterance: the command does not fire (safe failure)
        #expect(run("I like dogs scratch that I like fish")
            == "I like dogs scratch that I like fish")
    }

    @Test func scratchThatTrailingPeriodFires() {
        #expect(run("we went up the hill, scratch that. we went down the hill")
            == "we went down the hill")
    }

    @Test func scratchThatTrailingCommaFires() {
        #expect(run("we went up the hill, scratch that, we went down the hill")
            == "we went down the hill")
    }

    @Test func scratchThatAtEndOfUtteranceFires() {
        #expect(run("keep this. drop this scratch that") == "keep this.")
    }

    @Test func scratchAfterTabRemovesOnlyWhatFollowsTheTab() {
        // tab is a segment boundary, so scratch removes only the words after it, not across it
        #expect(run("column one insert tab character column two scratch that")
            == "column one\t")
    }

    @Test func scratchImmediatelyAfterTabCancelsTheTab() {
        #expect(run("column one insert tab character scratch that")
            == "column one")
    }

    @Test func scratchImmediatelyAfterClipboardTokenCancelsIt() {
        // the user's case: a comma-joined clipboard command cancelled, surrounding text untouched
        #expect(run("blah blah ⟦SN:CLIP:1⟧, scratch that, foo foo")
            == "blah blah foo foo")
    }

    @Test func scratchDoesNotReachPastAClipboardToken() {
        // words spoken after a clipboard insert scratch away without deleting the insert
        #expect(run("alpha ⟦SN:CLIP:1⟧ beta scratch that")
            == "alpha ⟦SN:CLIP:1⟧")
    }

    @Test func scratchImmediatelyAfterVerbatimTokenCancelsIt() {
        #expect(run("⟦SN:VERB:1⟧ scratch that") == "")
    }

    @Test func stageRunsBeforeReplacements() {
        let stage = LiveEditsStage()
        #expect(stage.position == .postSTTText)
        #expect(stage.order == StageOrder.liveEdits)
        #expect(stage.order < StageOrder.replacements)
    }

    // The carrier-less phrases spoken as prose are left as text — they are no longer defaults.
    @Test func droppedBarePhrasesAreLiteral() {
        #expect(run("a new line b") == "a new line b")
        #expect(run("alpha newline beta") == "alpha newline beta")
        #expect(run("alpha line break beta") == "alpha line break beta")
        #expect(run("write a new paragraph now") == "write a new paragraph now")
        #expect(run("press the tab key now") == "press the tab key now")
        #expect(run("insert tab value") == "insert tab value")
        #expect(run("I like dogs, strike that. I like fish") == "I like dogs, strike that. I like fish")
    }

    @Test func bareTabIsNotACommand() {
        #expect(run("press the tab to indent") == "press the tab to indent")
    }

    @Test func customCommandPhrases() {
        var ctx = PipelineContext(text: "alpha next line beta")
        LiveEditsStage(commands: .init(newLine: ["next line"])).apply(&ctx)
        #expect(ctx.text == "alpha\nbeta")
    }
}
