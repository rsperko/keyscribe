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

    @Test func scratchThatDoesNotEatThePreviousSentence() {
        // the segment after a sentence boundary is empty, so "scratch that" removes nothing
        #expect(run("done. scratch that. more") == "done. more")
    }

    @Test func scratchThatFollowedByWordIsLiteral() {
        // a continuing word means it is not a clause boundary — leave it as text
        #expect(run("I told her to scratch that lottery ticket and see if we won")
            == "I told her to scratch that lottery ticket and see if we won")
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
