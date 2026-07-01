import Testing
@testable import KeyScribeKit

private func tokenize(_ text: String, clipboard: String?) -> (out: String, tok: Tokenizer) {
    let t = Tokenizer()
    return (ClipboardTokenizer.apply(text, clipboard: clipboard, into: t), t)
}

struct ClipboardTokenizerTests {
    @Test func phraseBecomesClipboardToken() {
        let (out, t) = tokenize("the url is insert clipboard contents thanks", clipboard: "https://ex.com/a?b=c")
        #expect(out == "the url is ⟦SN:CLIP:1⟧ thanks")
        #expect(t.restore(out) == "the url is https://ex.com/a?b=c thanks")
    }

    @Test func articleVariantAlsoFires() {
        let (out, t) = tokenize("insert the clipboard contents", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧")
        #expect(t.restore(out) == "X")
    }

    @Test func singularVariantFires() {
        let (out, t) = tokenize("insert clipboard content", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧")
        #expect(t.restore(out) == "X")
    }

    @Test func singularArticleVariantFires() {
        let (out, t) = tokenize("insert the clipboard content", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧")
        #expect(t.restore(out) == "X")
    }

    @Test func caseInsensitive() {
        let (out, t) = tokenize("Insert Clipboard Contents", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧")
        #expect(t.restore(out) == "X")
    }

    @Test func trailingPunctuationLeftAsText() {
        let (out, _) = tokenize("paste this insert clipboard contents.", clipboard: "X")
        #expect(out == "paste this ⟦SN:CLIP:1⟧.")
    }

    // Distinct tokens per site (not deduped): each paste appears once, so a faithful LLM rewrite of two
    // paste sites is not rejected by the exactly-once gate.
    @Test func multipleOccurrencesGetDistinctTokens() {
        let (out, t) = tokenize("insert clipboard contents and insert clipboard contents", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧ and ⟦SN:CLIP:2⟧")
        #expect(t.restore(out) == "X and X")
    }

    // Pause commas the STT hangs around the command are absorbed on both sides.
    @Test func pauseCommasAroundCommandAreAbsorbed() {
        let (out, t) = tokenize("the value, insert clipboard contents, done", clipboard: "X")
        #expect(out == "the value ⟦SN:CLIP:1⟧ done")
        #expect(t.restore(out) == "the value X done")
    }

    // A preceding period with NO trailing terminator is kept (the paste is not bracketed — it may
    // start a new sentence, so we must not fold it into the previous clause).
    @Test func precedingPeriodIsPreserved() {
        let (out, _) = tokenize("done. insert clipboard contents", clipboard: "X")
        #expect(out == "done. ⟦SN:CLIP:1⟧")
    }

    // Bracketed-terminator fold: Whisper's spurious period before the paste ("directory. <paste>.
    // Decide") is dropped and relocated to the true clause end.
    @Test func bracketedTerminatorFolds() {
        let (out, t) = tokenize("read the directory. insert clipboard contents. decide", clipboard: "agent_notes/foo/")
        #expect(out == "read the directory ⟦SN:CLIP:1⟧. decide")
        #expect(t.restore(out) == "read the directory agent_notes/foo/. decide")
    }

    // The relocated terminator keeps its TYPE — a detected question stays a question.
    @Test func foldPreservesTerminatorType() {
        let (out, t) = tokenize("is this the right directory? insert clipboard contents. yes", clipboard: "P")
        #expect(out == "is this the right directory ⟦SN:CLIP:1⟧? yes")
        #expect(t.restore(out) == "is this the right directory P? yes")
    }

    // Risk 1 — content on its own at the end (no trailing terminator): NOT bracketed → no fold.
    @Test func pasteAtEndAfterSentenceIsNotFolded() {
        let (out, _) = tokenize("here's the path. insert clipboard contents", clipboard: "P")
        #expect(out == "here's the path. ⟦SN:CLIP:1⟧")
    }

    // Risk 2 — content starts the next sentence (no trailing terminator): NOT bracketed → no fold.
    @Test func pasteStartingNextSentenceIsNotFolded() {
        let (out, t) = tokenize("it's broken. insert clipboard contents fixes it", clipboard: "P")
        #expect(out == "it's broken. ⟦SN:CLIP:1⟧ fixes it")
        #expect(t.restore(out) == "it's broken. P fixes it")
    }

    // The singular aliases fire too.
    @Test func singularAliasFires() {
        let (out, t) = tokenize("insert clipboard content", clipboard: "P")
        #expect(out == "⟦SN:CLIP:1⟧")
        #expect(t.restore(out) == "P")
    }

    // Parakeet TDT v3 sometimes punctuates mid-phrase ("insert clipboard, contents"); the command
    // still fires (verified by the wav-based clipboard-check across engines).
    @Test func internalCommaFromSTTStillFires() {
        let (out, t) = tokenize("read the directory insert clipboard, contents now", clipboard: "P")
        #expect(out == "read the directory ⟦SN:CLIP:1⟧ now")
        #expect(t.restore(out) == "read the directory P now")
    }

    @Test func commandAtStartAbsorbsFollowingComma() {
        let (out, _) = tokenize("insert clipboard contents, done", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧ done")
    }

    @Test func trailingCommaAtEndIsAbsorbed() {
        let (out, _) = tokenize("paste it insert clipboard contents,", clipboard: "X")
        #expect(out == "paste it ⟦SN:CLIP:1⟧")
    }

    // Attached brackets are not pause artifacts — they stay attached, no spurious space inserted.
    @Test func attachedBracketsStayAttached() {
        let (out, t) = tokenize("(insert clipboard contents)", clipboard: "X")
        #expect(out == "(⟦SN:CLIP:1⟧)")
        #expect(t.restore(out) == "(X)")
    }

    // A colon after the command is intended punctuation, not a pause comma — keep it attached.
    @Test func followingColonIsPreserved() {
        let (out, _) = tokenize("insert clipboard contents: rest", clipboard: "X")
        #expect(out == "⟦SN:CLIP:1⟧: rest")
    }

    // Absorption and distinct-per-site tokens compose: pause commas cleaned, two paste sites distinct.
    @Test func multipleCommandsWithPauseCommas() {
        let (out, t) = tokenize("a, insert clipboard contents, b, insert clipboard contents, c", clipboard: "X")
        #expect(out == "a ⟦SN:CLIP:1⟧ b ⟦SN:CLIP:2⟧ c")
        #expect(t.restore(out) == "a X b X c")
    }

    // Empty clipboard: no match runs at all, so the whole utterance (commas and phrase) is untouched.
    @Test func emptyClipboardLeavesEverythingLiteral() {
        let (out, _) = tokenize("value, insert clipboard contents, done", clipboard: "")
        #expect(out == "value, insert clipboard contents, done")
    }

    @Test func emptyClipboardLeavesPhraseLiteral() {
        let (out, t) = tokenize("insert clipboard contents", clipboard: "")
        #expect(out == "insert clipboard contents")
        #expect(t.issuedTokens.isEmpty)
    }

    @Test func nilClipboardLeavesPhraseLiteral() {
        let (out, t) = tokenize("insert clipboard contents", clipboard: nil)
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

    // A clipboard that literally contains the fence sentinel must not hang restore and is inserted
    // as-is (see Tokenizer.restore pass cap). Pathological, essentially never real content.
    @Test func clipboardContainingTheSentinelIsInsertedAsIsWithoutHanging() {
        let (out, t) = tokenize("insert clipboard contents", clipboard: "⟦SN:CLIP:1⟧")
        #expect(t.restore(out) == "⟦SN:CLIP:1⟧")
    }

    // `mentions` gates the host's clipboard read so an ordinary dictation never touches the clipboard.
    @Test func mentionsDetectsTheCommand() {
        #expect(ClipboardTokenizer.mentions("please insert clipboard contents now"))
        #expect(ClipboardTokenizer.mentions("insert the clipboard contents"))
        #expect(ClipboardTokenizer.mentions("INSERT CLIPBOARD CONTENTS"))
        #expect(ClipboardTokenizer.mentions("please insert clipboard content now"))
        #expect(ClipboardTokenizer.mentions("insert the clipboard content"))
    }

    @Test func mentionsIsFalseWithoutTheCommand() {
        #expect(!ClipboardTokenizer.mentions("just some ordinary dictated words"))
        #expect(!ClipboardTokenizer.mentions("insert the clipboard now"))
        #expect(!ClipboardTokenizer.mentions(""))
    }
}
