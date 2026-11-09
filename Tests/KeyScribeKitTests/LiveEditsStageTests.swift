import Testing
@testable import KeyScribeKit

private func run(_ text: String) -> String {
    var ctx = PipelineContext(text: text)
    LiveEditsStage().apply(&ctx)
    return ctx.text
}

private func discards(_ text: String) -> Bool {
    var ctx = PipelineContext(text: text)
    LiveEditsStage().apply(&ctx)
    return ctx.discarded
}

struct LiveEditsStageTests {
    @Test(arguments: ["Never mind.", "never mind", "I have three things. Never mind.", "Okay, start over.", "blah blah, never mind!"])
    func aDiscardPhraseSaidAloneAtTheEndThrowsAwayTheTake(_ text: String) {
        var ctx = PipelineContext(text: text)
        LiveEditsStage().apply(&ctx)
        #expect(ctx.discarded)
        #expect(ctx.text.isEmpty)
    }

    @Test(arguments: [
        "We need to start over.", "Never mind the cost, ship it.", "I said never mind to him",
        "start over with the intro", "never mind me. I am fine.",
    ])
    func aDiscardPhraseInsideASentenceStaysText(_ text: String) {
        #expect(!discards(text))
        #expect(run(text) == text)
    }

    @Test func aDiscardPhraseInsideCapturedWordsNeverEmptiesTheCapture() {
        let segments = Pipeline.applying(LiveEditsStage(), toCapturesIn: [.literal("tell bob "), .captured("never mind")])
        #expect(Pipeline.joined(segments) == "tell bob never mind")
    }

    @Test(arguments: ["Hello, my name is Robert. Stratchdat.", "first part, scratch dat.", "first part, stratch that."])
    func commonMishearingsOfScratchThatStillScratch(_ text: String) {
        #expect(!run(text).lowercased().contains("dat"))
        #expect(!run(text).lowercased().contains("stratch"))
    }

    @Test func theEditsThatRanAreRecordedInOrder() {
        var ctx = PipelineContext(text: "first insert new line second, scratch that, third insert new line done")
        LiveEditsStage().apply(&ctx)
        #expect(ctx.spokenEdits == [.newLine, .scratchThat, .newLine])
    }

    @Test func aPhraseThatStaysTextIsNotRecorded() {
        var ctx = PipelineContext(text: "I told her to scratch that lottery ticket")
        LiveEditsStage().apply(&ctx)
        #expect(ctx.spokenEdits.isEmpty)
    }

    @Test func theSummaryNamesEachEditOnceInFirstOrderWithItsCount() {
        #expect(SpokenEdit.summary([.newLine, .scratchThat, .newLine]) == "new line \u{00D7}2, scratch that")
        #expect(SpokenEdit.summary([.newParagraph, .tab]) == "new paragraph, tab")
        #expect(SpokenEdit.summary([]) == nil)
    }

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

    @Test func absorbsPauseCommasAroundNewline() {
        #expect(run("blah, insert new line, foo") == "blah\nfoo")
    }

    @Test func absorbsPauseCommasAroundParagraph() {
        #expect(run("blah, insert new paragraph, foo") == "blah\n\nfoo")
    }

    @Test func absorbsPauseCommasAroundTab() {
        #expect(run("def foo, insert tab character, bar") == "def foo\tbar")
    }

    @Test func interiorPauseCommaStillFires() {
        #expect(run("insert, new line") == "\n")
        #expect(run("alpha insert, new line beta") == "alpha\nbeta")
    }

    @Test func interiorPauseCommaOnLaterWordFires() {
        #expect(run("insert new, paragraph") == "\n\n")
        #expect(run("insert tab, character here") == "\there")
    }

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

    @Test func standaloneCommaScratchWithTrailingWordIsLiteral() {
        #expect(run("scratch , that lottery ticket") == "scratch , that lottery ticket")
    }

    @Test func interiorPeriodDoesNotFireCommand() {
        #expect(run("insert new. paragraph two covers") == "insert new. paragraph two covers")
    }

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
        #expect(run("done. scratch that. more") == "more")
    }

    @Test func scratchThatEatsPreviousSentenceAcrossPeriod() {
        // A punctuating STT (e.g. Whisper) ends the clause with a period, leaving an empty segment;
        // scratch still removes only the sentence just spoken.
        #expect(run("blah blah. I don't know what I am saying here. scratch that. blah blah blah")
            == "blah blah. blah blah blah")
    }

    @Test func scratchAfterNewlineCancelsTheNewline() {
        #expect(run("keep this insert new line scratch that. final")
            == "keep this final")
    }

    @Test func scratchThatEmptySegmentStopsAtComma() {
        #expect(run("eggs, milk, bread. scratch that. done")
            == "eggs, milk, done")
    }

    @Test func scratchThatEmptySegmentStopsAtSemicolon() {
        #expect(run("first part; second part. scratch that. rest")
            == "first part; rest")
    }

    @Test func scratchThatFollowedByWordIsLiteral() {
        #expect(run("I told her to scratch that lottery ticket and see if we won")
            == "I told her to scratch that lottery ticket and see if we won")
    }

    @Test func scratchThatRunOnWithoutBoundaryIsLiteral() {
        // No terminator and not end-of-utterance: the command does not fire (safe failure) rather
        // than guess where the clause ends.
        #expect(run("I like dogs scratch that I like fish")
            == "I like dogs scratch that I like fish")
    }

    @Test(arguments: [
        ("I went to the store to buy milk, scratch that, to the mall", "I went to the mall"),
        ("Keep this. Meet me at the gym at noon, scratch that, at the park.", "Keep this. Meet me at the park."),
    ])
    func aCorrectionAfterScratchThatReplacesOnlyThePartItLinesUpWith(_ text: String, _ expected: String) {
        #expect(run(text) == expected)
    }

    @Test(arguments: [
        ("I have twenty five things, scratch that, six things", "six things"),
        ("Tell Alice to call Bob, scratch that. Bob will email me.", "Bob will email me."),
        ("send it to Bob, scratch that, to Alice", "to Alice"),
        ("I have 3 things, scratch that, 2 things", "2 things"),
        ("Please ask Alice to call Bob, scratch that. Call Bob yourself.", "Call Bob yourself."),
    ])
    func aCorrectionWithoutTwoWordsInARowReplacesTheWholeSentence(_ text: String, _ expected: String) {
        #expect(run(text) == expected)
    }

    @Test func aCorrectionSharingNoWordWithTheScratchedTextReplacesTheWholeSentence() {
        #expect(run("meet at noon, scratch that, let's do lunch") == "let's do lunch")
    }

    @Test func aRestartSharingOneScatteredWordReplacesTheWholeSentence() {
        #expect(run("Send the report to Bob, scratch that. Send it to Alice.") == "Send it to Alice.")
    }

    @Test func aCorrectionEndsAtASpokenCommand() {
        #expect(run("Draw a new line, scratch that, insert new line done") == "\ndone")
    }

    @Test func aCorrectionNeverLinesUpWithWordsBeforeTheSentence() {
        #expect(run("I have two cats. I have, scratch that, dogs") == "I have two cats. dogs")
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
        #expect(run("column one insert tab character column two scratch that")
            == "column one\t")
    }

    @Test func scratchImmediatelyAfterTabCancelsTheTab() {
        #expect(run("column one insert tab character scratch that")
            == "column one")
    }

    @Test func scratchImmediatelyAfterClipboardTokenCancelsIt() {
        #expect(run("blah blah ⟦SN:CLIP:1⟧, scratch that, foo foo")
            == "blah blah foo foo")
    }

    @Test func scratchDoesNotReachPastAClipboardToken() {
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
