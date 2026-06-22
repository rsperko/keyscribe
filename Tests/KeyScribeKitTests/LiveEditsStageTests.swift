import Testing
@testable import KeyScribeKit

private func run(_ text: String) -> String {
    var ctx = PipelineContext(text: text)
    LiveEditsStage().run(&ctx)
    return ctx.text
}

struct LiveEditsStageTests {
    @Test func newLineCommand() {
        #expect(run("alpha new line beta") == "alpha\nbeta")
    }

    @Test func newParagraphCommand() {
        #expect(run("alpha new paragraph beta") == "alpha\n\nbeta")
    }

    @Test func commandsAreCaseInsensitive() {
        #expect(run("alpha New Line beta") == "alpha\nbeta")
    }

    @Test func scratchThatRemovesCurrentSentence() {
        #expect(run("I like cats. I like dogs scratch that I like fish")
            == "I like cats. I like fish")
    }

    @Test func scratchThatBackToNewline() {
        // a newline command also bounds a segment
        #expect(run("keep this new line drop this scratch that final")
            == "keep this\nfinal")
    }

    @Test func plainTextPassesThrough() {
        #expect(run("just a normal sentence") == "just a normal sentence")
    }

    @Test func multipleCommandsInSequence() {
        #expect(run("one new line two new paragraph three") == "one\ntwo\n\nthree")
    }

    @Test func scratchThatAtStartIsNoOp() {
        #expect(run("scratch that hello") == "hello")
    }

    @Test func scratchThatDoesNotEatThePreviousSentence() {
        // the segment after a sentence boundary is empty, so "scratch that" removes nothing
        #expect(run("done. scratch that more") == "done. more")
    }

    @Test func stageRunsBeforeReplacements() {
        let stage = LiveEditsStage()
        #expect(stage.position == .postSTTText)
        #expect(stage.order == StageOrder.liveEdits)
        #expect(stage.order < StageOrder.replacements)
    }

    @Test func tabCommandInsertsTab() {
        #expect(run("def foo tab key bar") == "def foo\tbar")
        #expect(run("insert tab value") == "\tvalue")
    }

    @Test func bareTabIsNotACommand() {
        #expect(run("press the tab to indent") == "press the tab to indent")
    }

    @Test func customCommandPhrases() {
        var ctx = PipelineContext(text: "alpha next line beta")
        LiveEditsStage(commands: .init(newLine: ["next line"])).run(&ctx)
        #expect(ctx.text == "alpha\nbeta")
    }
}
