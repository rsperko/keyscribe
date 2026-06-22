import Testing
@testable import KeyScribeKit

private func redact(_ text: String) -> (out: String, tok: Tokenizer) {
    let t = Tokenizer()
    return (RedactionTokenizer.apply(text, into: t), t)
}

struct RedactionTokenizerTests {
    @Test func redactsEmail() {
        let (out, t) = redact("write to john@example.com please")
        #expect(out == "write to ⟦SN:REDACT:1⟧ please")
        #expect(!out.contains("john@example.com"))
        #expect(t.restore(out) == "write to john@example.com please")
    }

    @Test func redactsCreditCard() {
        let (out, _) = redact("card 4111 1111 1111 1111 expires soon")
        #expect(!out.contains("4111"))
        #expect(out.contains("⟦SN:REDACT:1⟧"))
    }

    @Test func redactsSSN() {
        let (out, _) = redact("ssn 123-45-6789 on file")
        #expect(!out.contains("123-45-6789"))
        #expect(out.contains("⟦SN:REDACT:1⟧"))
    }

    @Test func redactsOpenAIKey() {
        let (out, t) = redact("key is sk-abc123def456ghi789jkl012 ok")
        #expect(!out.contains("sk-abc123def456ghi789jkl012"))
        #expect(t.restore(out) == "key is sk-abc123def456ghi789jkl012 ok")
    }

    @Test func multipleSecretsDistinctTokens() {
        let (out, _) = redact("a@b.com and c@d.com")
        #expect(out == "⟦SN:REDACT:1⟧ and ⟦SN:REDACT:2⟧")
    }

    @Test func repeatedSecretReusesToken() {
        let (out, _) = redact("a@b.com then a@b.com again")
        #expect(out == "⟦SN:REDACT:1⟧ then ⟦SN:REDACT:1⟧ again")
    }

    @Test func plainTextUntouched() {
        let (out, _) = redact("just a normal sentence with no secrets")
        #expect(out == "just a normal sentence with no secrets")
    }

    @Test func redactsAWSAndGitHubKeys() {
        let (aws, _) = redact("key AKIA0123456789ABCDEF here")
        #expect(!aws.contains("AKIA0123456789ABCDEF"))
        #expect(aws.contains("⟦SN:REDACT:1⟧"))
        let (gh, _) = redact("token ghp_0123456789abcdefghij0 here")
        #expect(!gh.contains("ghp_0123456789abcdefghij0"))
        #expect(gh.contains("⟦SN:REDACT:1⟧"))
    }

    // A 16-digit card can sub-match the phone pattern; overlap resolution must collapse to a single
    // span and restore must reproduce the original exactly.
    @Test func overlappingMatchesProduceOneSpanAndRestoreExactly() {
        let original = "pay 4111 1111 1111 1111 now"
        let (out, t) = redact(original)
        let tokenCount = out.components(separatedBy: "⟦SN:REDACT:").count - 1
        #expect(tokenCount == 1)
        #expect(t.restore(out) == original)
    }

    @Test func bestEffortIsAdvertisedNotGuaranteed() {
        // an obfuscated secret may slip through — redaction is best-effort by design
        let (out, _) = redact("my key is ess kay dash abc")
        #expect(out == "my key is ess kay dash abc")   // not caught; acceptable
    }
}
