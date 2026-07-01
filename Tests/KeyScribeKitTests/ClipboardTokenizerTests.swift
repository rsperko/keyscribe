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

    // A preceding sentence period is kept — only whitespace/commas are absorbed.
    @Test func precedingPeriodIsPreserved() {
        let (out, _) = tokenize("done. insert clipboard contents", clipboard: "X")
        #expect(out == "done. ⟦SN:CLIP:1⟧")
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
    }

    @Test func mentionsIsFalseWithoutTheCommand() {
        #expect(!ClipboardTokenizer.mentions("just some ordinary dictated words"))
        #expect(!ClipboardTokenizer.mentions("insert the clipboard now"))
        #expect(!ClipboardTokenizer.mentions(""))
    }
}
