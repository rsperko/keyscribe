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
