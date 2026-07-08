import Testing
@testable import KeyScribeKit

struct TokenizerTests {
    @Test func allocatesTypeAndIndexTokens() {
        let t = Tokenizer()
        #expect(t.tokenize("sk-abc", type: .redact) == "⟦SN:REDACT:1⟧")
        #expect(t.tokenize("hello world", type: .verbatim) == "⟦SN:VERB:1⟧")
    }

    // An external value (a clipboard paste) can map a token to an original that re-contains that same
    // token — a cycle the acyclic fixpoint assumption does not hold for. restore must terminate (the
    // pass cap) and leave the self-referential span as the literal pasted text, never hang.
    @Test func selfReferentialOriginalDoesNotHang() {
        let t = Tokenizer()
        let token = t.tokenize("⟦SN:VERB:1⟧", type: .verbatim)   // value equals the token it is assigned
        #expect(token == "⟦SN:VERB:2⟧")
        #expect(t.restore("x \(token) y") == "x ⟦SN:VERB:1⟧ y")
    }

    @Test func uniqueTokenSkipsNonceAlreadyPresentInOriginal() {
        let t = Tokenizer()
        #expect(t.tokenizeUnique("⟦SN:CLIP:1⟧", type: .clipboard) == "⟦SN:CLIP:2⟧")
        #expect(t.restore("⟦SN:CLIP:2⟧") == "⟦SN:CLIP:1⟧")
        #expect(t.issuedTokens == ["⟦SN:CLIP:2⟧"])
    }

    @Test func sameValueSameTokenWithinDictation() {
        let t = Tokenizer()
        let a = t.tokenize("secret", type: .redact)
        let b = t.tokenize("secret", type: .redact)
        #expect(a == b)
        #expect(t.issuedTokens == ["⟦SN:REDACT:1⟧"])   // counter advanced once
    }

    @Test func distinctValuesGetDistinctIndices() {
        let t = Tokenizer()
        #expect(t.tokenize("one", type: .redact) == "⟦SN:REDACT:1⟧")
        #expect(t.tokenize("two", type: .redact) == "⟦SN:REDACT:2⟧")
    }

    @Test func typesHaveIndependentCounters() {
        let t = Tokenizer()
        _ = t.tokenize("a", type: .redact)
        #expect(t.tokenize("b", type: .verbatim) == "⟦SN:VERB:1⟧")
    }

    @Test func restoreReplacesTokensWithOriginals() {
        let t = Tokenizer()
        let tok = t.tokenize("hunter2", type: .redact)
        #expect(t.restore("password is \(tok) ok") == "password is hunter2 ok")
    }

    @Test func restoreIsLIFOForNestedTokens() {
        let t = Tokenizer()
        let inner = t.tokenize("inner", type: .redact)                 // ⟦SN:REDACT:1⟧
        let outer = t.tokenize("before \(inner) after", type: .redact) // value literally contains inner
        // forward restore would strand the inner token; LIFO unwinds correctly
        #expect(t.restore(outer) == "before inner after")
    }

    @Test func issuedTokensAreInAllocationOrder() {
        let t = Tokenizer()
        _ = t.tokenize("x", type: .verbatim)
        _ = t.tokenize("y", type: .redact)
        #expect(t.issuedTokens == ["⟦SN:VERB:1⟧", "⟦SN:REDACT:1⟧"])
    }

    @Test func mapNeverExposedAsOriginalsInIssuedTokens() {
        // issuedTokens is the public surface; it must contain only tokens, never originals
        let t = Tokenizer()
        _ = t.tokenize("4111 1111 1111 1111", type: .redact)
        #expect(t.issuedTokens.allSatisfy { $0.hasPrefix("⟦SN:") })
    }

    // A verbatim token allocated first, then a redaction span captured around it: the single-pass
    // restore must still expand both, even though redaction's original literally embeds the verbatim
    // token (cross-type nesting, the real pipeline shape).
    @Test func restoreUnwindsCrossTypeNesting() {
        let t = Tokenizer()
        let verb = t.tokenize("keep this", type: .verbatim)      // ⟦SN:VERB:1⟧
        let red = t.tokenize("a \(verb) b", type: .redact)        // original embeds the verbatim token
        #expect(t.restore("x \(red) y") == "x a keep this b y")
    }

    // An unknown token (e.g. one the LLM hallucinated) is left untouched and must not loop forever.
    @Test func restoreLeavesUnknownTokensAndTerminates() {
        let t = Tokenizer()
        let known = t.tokenize("real", type: .redact)
        #expect(t.restore("\(known) and ⟦SN:REDACT:99⟧") == "real and ⟦SN:REDACT:99⟧")
    }

    @Test func restoreDoesNotStrandRealTokenAfterLookalikeOpen() {
        let t = Tokenizer()
        let tok = t.tokenize("secret", type: .redact)   // ⟦SN:REDACT:1⟧
        #expect(t.restore("⟦SN: x \(tok) y") == "⟦SN: x secret y")
    }

    @Test func restoreHandlesManyTokens() {
        let t = Tokenizer()
        let tokens = (0..<50).map { t.tokenize("v\($0)", type: .redact) }
        let restored = t.restore(tokens.joined(separator: " "))
        #expect(restored == (0..<50).map { "v\($0)" }.joined(separator: " "))
    }
}
