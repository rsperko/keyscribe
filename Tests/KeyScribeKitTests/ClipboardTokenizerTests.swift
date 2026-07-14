import Testing
@testable import KeyScribeKit

private func tokenize(_ text: String, clipboard: String?) -> (out: String, tok: Tokenizer) {
    let t = Tokenizer()
    return (ClipboardTokenizer.apply(text, clipboard: { clipboard }, into: t), t)
}

struct ClipboardTokenizerTests {
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

    // Tokens are per-site, not deduped — two paste sites get distinct tokens so the post-LLM
    // exactly-once validation gate doesn't reject a faithful rewrite of both.
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

    // Not bracketed on both sides, so not folded — the paste may start a new sentence.
    @Test func precedingPeriodIsPreserved() {
        let (out, _) = tokenize("done. insert clipboard contents", clipboard: "X")
        #expect(out == "done. ⟦SN:CLIP:1⟧")
    }

    // Whisper's spurious period before the paste ("directory. <paste>. decide") is dropped and
    // relocated to the true clause end.
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

    // Parakeet TDT v3 sometimes punctuates mid-phrase ("insert clipboard, contents"); the command
    // must still fire (verified against real audio via the commands-check corpus).
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

    // Unlike pause commas, attached brackets are not STT artifacts to strip — no space is inserted.
    @Test func attachedBracketsStayAttached() {
        let (out, t) = tokenize("(insert clipboard contents)", clipboard: "X")
        #expect(out == "(⟦SN:CLIP:1⟧)")
        #expect(t.restore(out) == "(X)")
    }

    // A colon after the command is intended punctuation, not a pause comma to strip.
    @Test func followingColonIsPreserved() {
        let (out, _) = tokenize("insert clipboard contents: rest", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧: rest")
    }

    @Test func multipleCommandsWithPauseCommas() {
        let (out, t) = tokenize("a, insert clipboard contents, b, insert clipboard contents, c", clipboard: "X")
        #expect(out == "a ⟦SN:CLIP:1⟧ b ⟦SN:CLIP:2⟧ c")
        #expect(t.restore(out) == "a X b X c")
    }

    // An empty clipboard means no match runs at all, so pause commas are left untouched too.
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

    // A clipboard that literally contains the fence sentinel must not hang restore (Tokenizer.restore
    // caps its passes) — pathological input, but must degrade safely rather than loop.
    @Test func clipboardContainingTheSentinelIsInsertedAsIsWithoutHanging() {
        let (out, t) = tokenize("insert clipboard contents", clipboard: "⟦SN:CLIP:1⟧")
        #expect(t.restore(out) == "⟦SN:CLIP:1⟧")
    }

    // `mentions` gates the host's clipboard read so an ordinary dictation never touches it.
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

    // The clipboard provider is only invoked lazily, when the command phrase is actually present.
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
