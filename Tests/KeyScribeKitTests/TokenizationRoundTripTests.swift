import Foundation
import Testing
@testable import KeyScribeKit

private struct ScriptError: Error {}

private actor ScriptedClient: LLMClient {
    private let outputs: [String]
    private(set) var calls = 0
    init(_ outputs: [String]) { self.outputs = outputs }
    func complete(system: String, user: String, connection: Connection) async throws -> String {
        let i = min(calls, outputs.count - 1)
        calls += 1
        // The model only ever sees `user`; assert no raw secret leaked into the prompt.
        return outputs[i]
    }
}

private let conn = Connection(id: "x", name: "X", provider: .gemini, model: "m", keyRef: "k")

private func inputs(_ content: String, tokens: [String]) -> PromptInputs {
    PromptInputs(
        modePrompt: "Polish this.", dictatedInstructions: "", content: content,
        tokens: tokens, validTerms: [], language: "English", modeSystemInstructions: "",
        appName: nil, bundleId: nil, fieldRole: nil, selectedText: nil)
}

private func rewrittenText(_ o: RewriteOutcome) -> String? {
    if case .rewritten(let s) = o { return s }
    return nil
}
private func fallbackText(_ o: RewriteOutcome) -> String? {
    if case .localFallback(let s, _) = o { return s }
    return nil
}

struct TokenizationRoundTripTests {
    // The wedge: verbatim + redaction tokenize, the model never sees the protected spans, the
    // system prompt carries the preserve directive, and restore returns the originals.
    @Test func sensitiveSpansNeverReachModelAndRestoreAfterRewrite() async throws {
        let raw = "email john@example.com and begin verbatim KEEP_EXACT end verbatim"
        let t = Tokenizer()
        var text = VerbatimTokenizer.apply(raw, into: t)   // verbatim first (design.md §4.2.1)
        text = RedactionTokenizer.apply(text, into: t)     // then redaction
        let tokens = t.issuedTokens                        // [⟦SN:VERB:1⟧, ⟦SN:REDACT:1⟧]

        #expect(!text.contains("john@example.com"))
        #expect(!text.contains("KEEP_EXACT"))

        // The assembled prompt instructs the model to preserve tokens, and carries no secret.
        let prompt = PromptAssembler.assemble(inputs(text, tokens: tokens))
        #expect(prompt.system.contains("opaque marker"))
        #expect(!prompt.user.contains("john@example.com"))
        #expect(!prompt.user.contains("KEEP_EXACT"))

        // Model paraphrases but keeps both tokens.
        let preserved = "Review \(tokens[1]) and \(tokens[0]) carefully."
        let svc = RewriteService(client: ScriptedClient([preserved]))
        let outcome = await svc.rewrite(payload: TokenizedPayload(text: text, issuedTokens: tokens),
                                        inputs: inputs(text, tokens: tokens), connection: conn)

        let out = try #require(rewrittenText(outcome))
        let final = t.restore(out)
        #expect(final == "Review john@example.com and KEEP_EXACT carefully.")
        #expect(!final.contains("⟦SN:"))   // no raw token ever inserted
    }

    // A model that drops a token fails the gate, retries, then falls back to the LOCAL tokenized
    // text — which is restored too, so the user still gets correct output, never a raw token.
    @Test func droppedTokenFallsBackAndRestoresLocally() async throws {
        let raw = "email john@example.com now"
        let t = Tokenizer()
        let text = RedactionTokenizer.apply(raw, into: t)
        let tokens = t.issuedTokens

        let svc = RewriteService(client: ScriptedClient(["email someone now", "still no token"]))
        let outcome = await svc.rewrite(payload: TokenizedPayload(text: text, issuedTokens: tokens),
                                        inputs: inputs(text, tokens: tokens), connection: conn)

        let local = try #require(fallbackText(outcome))
        let final = t.restore(local)
        #expect(final == "email john@example.com now")
        #expect(!final.contains("⟦SN:"))
    }
}
