import Testing
@testable import KeyScribeKit

struct TokenizerTests {
    @Test func allocatesTypeAndIndexTokens() {
        let t = Tokenizer()
        #expect(t.tokenize("sk-abc", type: .redact) == "⟦SN:REDACT:1⟧")
        #expect(t.tokenize("hello world", type: .verbatim) == "⟦SN:VERB:1⟧")
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
}
