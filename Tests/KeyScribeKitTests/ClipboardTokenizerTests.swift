import Testing
@testable import KeyScribeKit

private func tokenize(_ text: String, clipboard: String?) -> (out: String, tok: Tokenizer) {
    let t = Tokenizer()
    return (ClipboardTokenizer.apply(text, clipboard: { clipboard }, into: t), t)
}

struct ClipboardTokenizerTests {
    @Test func aQuoteOrBackslashInAQuotedPathIsEscaped() {
        #expect(ClipboardTokenizer.Clip.files(["/tmp/say \"hi\" \\ there.png"]).text == "\"/tmp/say \\\"hi\\\" \\\\ there.png\"")
        #expect(ClipboardTokenizer.Clip.files(["/tmp/no\"space.png"]).text == "/tmp/no\"space.png")
    }

    @Test func copiedFilesAreNamedByTheirPathsInlineEvenAsCode() {
        let files = ClipboardTokenizer.Clip.files(["/tmp/shot.png", "/Users/me/My Notes.pdf"])
        #expect(files.text == "/tmp/shot.png \"/Users/me/My Notes.pdf\"")
        for phrase in ["insert clipboard contents", "insert clipboard as code"] {
            let t = Tokenizer()
            let out = ClipboardTokenizer.apply("look at \(phrase) please", clip: { files }, into: t)
            #expect(t.restore(out) == "look at /tmp/shot.png \"/Users/me/My Notes.pdf\" please")
        }
    }

    @Test func asCodeMidSentenceFencesTheClipboardOnItsOwnLines() {
        let (out, t) = tokenize("this fails with this error: insert clipboard as code. Please fix it.", clipboard: "boom\n  at main\n")
        #expect(out == "this fails with this error: ⟦SN:CLIP:1⟧. Please fix it.")
        #expect(t.restore(out) == "this fails with this error:\n```\nboom\n  at main\n```\nPlease fix it.")
    }

    @Test(arguments: [
        "insert clipboard as code", "insert the clipboard as code", "insert clipboard as a code block",
        "insert clipboard contents as code", "Insert the clipboard contents as code.",
        "insert clipboard content as code", "insert the clipboard contents as a code block",
    ])
    func asCodeAloneIsJustTheBlock(_ phrase: String) {
        let (out, t) = tokenize(phrase, clipboard: "x = 1")
        #expect(t.restore(out) == "```\nx = 1\n```")
    }

    @Test func aClipboardHoldingAFenceGetsALongerOne() {
        let (out, t) = tokenize("insert clipboard as code", clipboard: "````md\n```\ninner\n```\n````")
        #expect(t.restore(out) == "`````\n````md\n```\ninner\n```\n````\n`````")
    }

    @Test func aRewriteThatMovedSpacesOrLinesAroundABlockStillLeavesItOnLinesOfItsOwn() {
        let (out, t) = tokenize("error: insert clipboard as code please", clipboard: "x")
        let token = out.split(separator: " ")[1]
        #expect(t.restore("Error:   \(token)  Please.") == "Error:\n```\nx\n```\nPlease.")
        #expect(t.restore("Error:\n\(token)\nPlease.") == "Error:\n```\nx\n```\nPlease.")
        #expect(t.restore("Error: \(token). Please.") == "Error:\n```\nx\n```\nPlease.")
    }

    @Test func repeatedBlocksEachGetTheirOwnLines() {
        let (out, t) = tokenize("insert clipboard as code and insert clipboard as code", clipboard: "x")
        #expect(t.restore(out) == "```\nx\n```\nand\n```\nx\n```")
    }

    @Test func aPlainPasteBeforeABlockKeepsItsOwnTrailingSpaces() {
        let (out, t) = tokenize("insert clipboard contents insert clipboard as code", clipboard: "x \t")
        #expect(t.restore(out) == "x \t\n```\nx \t\n```")
    }

    @Test func neverMindRightAfterABlockStillDiscardsTheTake() {
        let pipeline = TakeStages.dictation(text: [LiveEditsStage()], clipboard: { "x" }, redaction: false)
        let take = TakeText("insert clipboard as code. Never mind.", pipeline: pipeline, trimsTrailingPunctuation: false)
        #expect(take.discarded)
    }

    @Test func aSentenceAfterABlockStartsOnItsOwnLineWithoutTheStrayPeriod() {
        let pipeline = TakeStages.dictation(text: [LiveEditsStage()], clipboard: { "x" }, redaction: false)
        let take = TakeText("Look: insert clipboard as code. Thanks.", pipeline: pipeline, trimsTrailingPunctuation: false)
        #expect(take.localText == "Look:\n```\nx\n```\nThanks.")
    }

    @Test func spokenEditsBesideABlockStillFire() {
        let pipeline = TakeStages.dictation(text: [LiveEditsStage()], clipboard: { "x" }, redaction: false)
        let scratched = TakeText("look insert clipboard as code scratch that", pipeline: pipeline, trimsTrailingPunctuation: false)
        #expect(scratched.localText == "look")
        let broken = TakeText("insert clipboard as code insert new line done", pipeline: pipeline, trimsTrailingPunctuation: false)
        #expect(broken.localText == "```\nx\n```\ndone")
    }

    @Test func aWindowsLineEndingDoesNotLeaveABlankLineBeforeTheClosingFence() {
        let (out, t) = tokenize("insert clipboard as code", clipboard: "x = 1\r\n")
        #expect(t.restore(out) == "```\nx = 1\n```")
    }

    @Test func asCodeWithAnEmptyClipboardStaysText() {
        let (out, _) = tokenize("insert clipboard as code", clipboard: "")
        #expect(out == "insert clipboard as code")
    }

    @Test func asCodeAndPlainInOneTakeKeepTheirOwnShapes() {
        let (out, t) = tokenize("see insert clipboard contents and insert clipboard as code", clipboard: "X")
        #expect(t.restore(out) == "see X and\n```\nX\n```")
    }

    @Test(arguments: [
        ("the url is insert clipboard contents thanks", "https://ex.com/a?b=c", "the url is ⟦SN:CLIP:1⟧ thanks", "the url is https://ex.com/a?b=c thanks"),
        ("insert the clipboard contents", "X", "⟦SN:CLIP:1⟧", "X"),
        ("insert clipboard content", "X", "⟦SN:CLIP:1⟧", "X"),
        ("insert the clipboard content", "X", "⟦SN:CLIP:1⟧", "X"),
        ("Insert Clipboard Contents", "X", "⟦SN:CLIP:1⟧", "X"),
    ])
    func phraseVariantsBecomeClipboardTokens(
        _ input: String,
        _ clipboard: String,
        _ expectedOut: String,
        _ expectedRestore: String
    ) {
        let (out, t) = tokenize(input, clipboard: clipboard)
        #expect(out == expectedOut)
        #expect(t.restore(out) == expectedRestore)
    }

    @Test func trailingPunctuationLeftAsText() {
        let (out, _) = tokenize("paste this insert clipboard contents.", clipboard: "X")
        #expect(out == "paste this ⟦SN:CLIP:1⟧.")
    }

    @Test func multipleOccurrencesGetDistinctTokens() {
        let (out, t) = tokenize("insert clipboard contents and insert clipboard contents", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧ and ⟦SN:CLIP:2⟧")
        #expect(t.restore(out) == "X and X")
    }

    @Test func pauseCommasAroundCommandAreAbsorbed() {
        let (out, t) = tokenize("the value, insert clipboard contents, done", clipboard: "X")
        #expect(out == "the value ⟦SN:CLIP:1⟧ done")
        #expect(t.restore(out) == "the value X done")
    }

    @Test func precedingPeriodIsPreserved() {
        let (out, _) = tokenize("done. insert clipboard contents", clipboard: "X")
        #expect(out == "done. ⟦SN:CLIP:1⟧")
    }

    @Test func bracketedTerminatorFolds() {
        let (out, t) = tokenize("read the directory. insert clipboard contents. decide", clipboard: "agent_notes/foo/")
        #expect(out == "read the directory ⟦SN:CLIP:1⟧. decide")
        #expect(t.restore(out) == "read the directory agent_notes/foo/. decide")
    }

    @Test func foldPreservesTerminatorType() {
        let (out, t) = tokenize("is this the right directory? insert clipboard contents. yes", clipboard: "P")
        #expect(out == "is this the right directory ⟦SN:CLIP:1⟧? yes")
        #expect(t.restore(out) == "is this the right directory P? yes")
    }

    @Test func pasteAtEndAfterSentenceIsNotFolded() {
        let (out, _) = tokenize("here's the path. insert clipboard contents", clipboard: "P")
        #expect(out == "here's the path. ⟦SN:CLIP:1⟧")
    }

    @Test func pasteStartingNextSentenceIsNotFolded() {
        let (out, t) = tokenize("it's broken. insert clipboard contents fixes it", clipboard: "P")
        #expect(out == "it's broken. ⟦SN:CLIP:1⟧ fixes it")
        #expect(t.restore(out) == "it's broken. P fixes it")
    }

    @Test func internalCommaFromSTTStillFires() {
        let (out, t) = tokenize("read the directory insert clipboard, contents now", clipboard: "P")
        #expect(out == "read the directory ⟦SN:CLIP:1⟧ now")
        #expect(t.restore(out) == "read the directory P now")
    }

    @Test(arguments: [
        ("insert clipboard contents, done", "⟦SN:CLIP:1⟧ done"),
        ("paste it insert clipboard contents,", "paste it ⟦SN:CLIP:1⟧"),
    ])
    func pauseCommasAtCommandBoundariesAreAbsorbed(_ input: String, _ expected: String) {
        let (out, _) = tokenize(input, clipboard: "X")
        #expect(out == expected)
    }

    @Test func attachedBracketsStayAttached() {
        let (out, t) = tokenize("(insert clipboard contents)", clipboard: "X")
        #expect(out == "(⟦SN:CLIP:1⟧)")
        #expect(t.restore(out) == "(X)")
    }

    @Test func followingColonIsPreserved() {
        let (out, _) = tokenize("insert clipboard contents: rest", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧: rest")
    }

    @Test func multipleCommandsWithPauseCommas() {
        let (out, t) = tokenize("a, insert clipboard contents, b, insert clipboard contents, c", clipboard: "X")
        #expect(out == "a ⟦SN:CLIP:1⟧ b ⟦SN:CLIP:2⟧ c")
        #expect(t.restore(out) == "a X b X c")
    }

    @Test func emptyClipboardLeavesEverythingLiteral() {
        let (out, _) = tokenize("value, insert clipboard contents, done", clipboard: "")
        #expect(out == "value, insert clipboard contents, done")
    }

    @Test(arguments: ["", nil])
    func absentClipboardLeavesPhraseLiteral(_ clipboard: String?) {
        let (out, t) = tokenize("insert clipboard contents", clipboard: clipboard)
        #expect(out == "insert clipboard contents")
        #expect(t.issuedTokens.isEmpty)
    }

    @Test func noPhraseIsUnchanged() {
        let (out, t) = tokenize("just some normal words", clipboard: "X")
        #expect(out == "just some normal words")
        #expect(t.issuedTokens.isEmpty)
    }

    @Test func partialPhraseDoesNotFire() {
        let (out, _) = tokenize("insert the clipboard now", clipboard: "X")
        #expect(out == "insert the clipboard now")
    }

    @Test func multiLineClipboardIsInsertedWhole() {
        let clip = "line one\nline two"
        let (out, t) = tokenize("insert clipboard contents", clipboard: clip)
        #expect(out == "⟦SN:CLIP:1⟧")
        #expect(t.restore(out) == clip)
    }

    @Test func clipboardContainingTheSentinelIsInsertedAsIsWithoutHanging() {
        let (out, t) = tokenize("insert clipboard contents", clipboard: "⟦SN:CLIP:1⟧")
        #expect(t.restore(out) == "⟦SN:CLIP:1⟧")
    }

    @Test(arguments: [
        "please insert clipboard contents now",
        "insert the clipboard contents",
        "INSERT CLIPBOARD CONTENTS",
        "please insert clipboard content now",
        "insert the clipboard content",
    ])
    func mentionsDetectsTheCommand(_ text: String) {
        #expect(ClipboardTokenizer.mentions(text))
    }

    @Test(arguments: [
        "just some ordinary dictated words",
        "insert the clipboard now",
        "",
    ])
    func mentionsIsFalseWithoutTheCommand(_ text: String) {
        #expect(!ClipboardTokenizer.mentions(text))
    }

    @Test func providerNotReadWhenCommandAbsent() {
        var reads = 0
        let t = Tokenizer()
        let out = ClipboardTokenizer.apply("just some ordinary words", clipboard: { reads += 1; return "X" }, into: t)
        #expect(reads == 0)
        #expect(out == "just some ordinary words")
    }

    @Test func providerReadOnceWhenCommandPresent() {
        var reads = 0
        let t = Tokenizer()
        let out = ClipboardTokenizer.apply("insert clipboard contents", clipboard: { reads += 1; return "X" }, into: t)
        #expect(reads == 1)
        #expect(t.restore(out) == "X")
    }
}
