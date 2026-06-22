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

    @Test func redactsStripeAndSlackTokens() {
        let (stripe, t1) = redact("charge with sk_live_abcdef0123456789ABCD now")
        #expect(!stripe.contains("sk_live"))
        #expect(t1.restore(stripe) == "charge with sk_live_abcdef0123456789ABCD now")
        let (slack, _) = redact("hook xoxb-123456789012-abcdefABCDEF here")
        #expect(!slack.contains("xoxb-"))
        #expect(slack.contains("⟦SN:REDACT:1⟧"))
    }

    @Test func redactsGitLabToken() {
        let (out, t) = redact("ci uses glpat-ABCdef0123456789ghijk now")
        #expect(!out.contains("glpat-"))
        #expect(t.restore(out) == "ci uses glpat-ABCdef0123456789ghijk now")
    }

    @Test func redactsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N"
        let (out, t) = redact("token \(jwt) end")
        #expect(!out.contains("eyJ"))
        #expect(t.restore(out) == "token \(jwt) end")
    }

    @Test func redactsKeyAssignment() {
        let (out, _) = redact("set API_KEY=swordfish123456 in env")
        #expect(!out.contains("swordfish123456"))
        #expect(out.contains("⟦SN:REDACT:1⟧"))
    }

    @Test func luhnRejectsNonCardDigitRuns() {
        #expect(RedactionTokenizer.luhnValid("4111111111111111"))
        #expect(!RedactionTokenizer.luhnValid("4111111111111112"))
        #expect(RedactionTokenizer.luhnValid("4111 1111 1111 1111"))
    }

    @Test func ibanValidatesMod97() {
        #expect(RedactionTokenizer.ibanValid("GB82WEST12345698765432"))
        #expect(RedactionTokenizer.ibanValid("GB82 WEST 1234 5698 7654 32"))
        #expect(!RedactionTokenizer.ibanValid("GB82WEST12345698765433"))
    }

    @Test func redactsValidIBAN() {
        let (out, t) = redact("wire to GB82 WEST 1234 5698 7654 32 today")
        #expect(!out.contains("WEST"))
        #expect(t.restore(out) == "wire to GB82 WEST 1234 5698 7654 32 today")
    }

    @Test func highEntropyBlobRedacted() {
        #expect(RedactionTokenizer.isHighEntropySecret("Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MEFC"))
        let (out, _) = redact("creds Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MEFC done")
        #expect(out.contains("⟦SN:REDACT:1⟧"))
        #expect(!out.contains("Zm9vYmFy"))
    }

    @Test func ordinaryProseNotHighEntropy() {
        #expect(!RedactionTokenizer.isHighEntropySecret("antidisestablishmentarianism"))
        #expect(!RedactionTokenizer.isHighEntropySecret("0000000000000000000000000000"))
        let (out, _) = redact("this is an ordinary sentence about establishment matters")
        #expect(out == "this is an ordinary sentence about establishment matters")
    }
}
