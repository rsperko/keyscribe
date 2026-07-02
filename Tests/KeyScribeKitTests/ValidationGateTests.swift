import Testing
@testable import KeyScribeKit

struct ValidationGateTests {
    @Test func passesWhenEachTokenReturnsExactlyOnce() {
        let v = ValidationGate.check(
            output: "Email ⟦SN:REDACT:1⟧ and ⟦SN:VERB:1⟧ here",
            issuedTokens: ["⟦SN:REDACT:1⟧", "⟦SN:VERB:1⟧"])
        #expect(v == .pass)
    }

    @Test func passesWithNoTokensAndCleanOutput() {
        #expect(ValidationGate.check(output: "just text", issuedTokens: []) == .pass)
    }

    @Test func emptyOutputFails() {
        #expect(ValidationGate.check(output: "   ", issuedTokens: []) == .fail(.empty))
    }

    @Test func missingTokenFails() {
        #expect(ValidationGate.check(output: "no token here", issuedTokens: ["⟦SN:REDACT:1⟧"])
            == .fail(.missingToken("⟦SN:REDACT:1⟧")))
    }

    @Test func duplicatedTokenFails() {
        #expect(ValidationGate.check(
            output: "⟦SN:REDACT:1⟧ and again ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:1⟧"])
            == .fail(.duplicatedToken("⟦SN:REDACT:1⟧")))
    }

    @Test func straySentinelFails() {
        // model invented a token we never issued
        let v = ValidationGate.check(output: "text ⟦SN:REDACT:9⟧", issuedTokens: [])
        #expect(v == .fail(.strayToken("⟦SN:REDACT:9⟧")))
    }

    @Test func allowDeletionLetsTokenBeAbsent() {
        #expect(ValidationGate.check(
            output: "clean output", issuedTokens: ["⟦SN:VERB:1⟧"], allowDeletion: true) == .pass)
    }

    @Test func allowDeletionStillRejectsDuplicates() {
        #expect(ValidationGate.check(
            output: "⟦SN:VERB:1⟧ ⟦SN:VERB:1⟧", issuedTokens: ["⟦SN:VERB:1⟧"], allowDeletion: true)
            == .fail(.duplicatedToken("⟦SN:VERB:1⟧")))
    }

    // A selection-instruction token isn't required to reappear, but one occurrence must not be
    // rejected as stray (hotkeys-llm-network H1 follow-up).
    @Test func allowedTokenMayAppearOnceWithoutFailing() {
        let v = ValidationGate.check(
            output: "the value is ⟦SN:REDACT:2⟧", issuedTokens: [], allowedTokens: ["⟦SN:REDACT:2⟧"])
        #expect(v == .pass)
    }

    @Test func allowedTokenMayBeAbsentEntirely() {
        let v = ValidationGate.check(
            output: "no mention here", issuedTokens: [], allowedTokens: ["⟦SN:REDACT:2⟧"])
        #expect(v == .pass)
    }

    @Test func allowedTokenAppearingTwiceStillFails() {
        let v = ValidationGate.check(
            output: "⟦SN:REDACT:2⟧ and ⟦SN:REDACT:2⟧", issuedTokens: [], allowedTokens: ["⟦SN:REDACT:2⟧"])
        #expect(v == .fail(.duplicatedToken("⟦SN:REDACT:2⟧")))
    }

    @Test func tokenNeitherIssuedNorAllowedIsStillStray() {
        let v = ValidationGate.check(
            output: "text ⟦SN:REDACT:9⟧", issuedTokens: [], allowedTokens: ["⟦SN:REDACT:2⟧"])
        #expect(v == .fail(.strayToken("⟦SN:REDACT:9⟧")))
    }

    @Test func retryAndFallbackDecision() {
        // first failure → retry stricter; second failure → local fallback
        #expect(ValidationGate.recovery(attempt: 0) == .retryStricter)
        #expect(ValidationGate.recovery(attempt: 1) == .localFallback)
    }
}
