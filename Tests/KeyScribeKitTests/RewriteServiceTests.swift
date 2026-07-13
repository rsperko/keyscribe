import Foundation
import Testing
@testable import KeyScribeKit

private struct FakeError: Error {}

private actor FakeClient: LLMClient {
    private let outputs: [Result<String, FakeError>]
    private(set) var calls = 0
    init(_ outputs: [Result<String, FakeError>]) { self.outputs = outputs }
    func complete(system: String, user: String, connection: Connection) async throws -> String {
        let i = min(calls, outputs.count - 1)
        calls += 1
        switch outputs[i] {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

private let conn = Connection(id: "x", name: "X", provider: .gemini, model: "m", keyRef: "k")

private func inputs(content: String = "hello") -> PromptInputs {
    PromptInputs(
        modePrompt: "Rewrite.", dictatedInstructions: "", content: content,
        tokens: [], validTerms: [], language: "English", modeSystemInstructions: "",
        appName: nil, bundleId: nil, fieldRole: nil, selectedText: nil)
}

struct RewriteServiceTests {
    @Test func returnsRewrittenOnCleanOutput() async {
        let svc = RewriteService(client: FakeClient([.success("Hello.")]))
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        #expect(out == .rewritten("Hello."))
    }

    @Test func fallsBackToLocalWhenClientThrows() async {
        let svc = RewriteService(client: FakeClient([.failure(FakeError())]))
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        // The fallback now carries the reason so it is diagnosable rather than silent.
        guard case .localFallback(let text, let reason) = out else { Issue.record("expected fallback"); return }
        #expect(text == "hello")
        #expect(reason != nil)
    }

    @Test func retriesOnceThenSucceeds() async {
        // first output drops the token (gate fail) → retry → second output is clean. Content carries the
        // token (as the tokenized transcript does in production) so the gate requires it.
        let client = FakeClient([.success("dropped it"), .success("kept ⟦SN:REDACT:1⟧")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "kept ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:1⟧"]),
            inputs: inputs(content: "kept ⟦SN:REDACT:1⟧"), connection: conn)
        #expect(out == .rewritten("kept ⟦SN:REDACT:1⟧"))
        #expect(await client.calls == 2)
    }

    @Test func fallsBackAfterRetryStillFails() async {
        let client = FakeClient([.success("no token"), .success("still no token")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "orig ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:1⟧"]),
            inputs: inputs(content: "orig ⟦SN:REDACT:1⟧"), connection: conn)
        guard case .localFallback(let text, let reason) = out else { Issue.record("expected fallback"); return }
        #expect(text == "orig ⟦SN:REDACT:1⟧")
        #expect(reason != nil)   // gate-failure fallback is also labeled
        #expect(await client.calls == 2)   // initial + one stricter retry, no more
    }

    // An issued token that was swallowed upstream (a verbatim token captured inside a redaction
    // span) is absent from the sent content, so the model never sees it. The gate must NOT require it —
    // a clean output that reproduces only the tokens actually present passes on the first call, no doomed
    // retry, no spurious fallback for the privacy+verbatim users this targets.
    @Test func passesWhenIssuedTokenAbsentFromSentContent() async {
        let client = FakeClient([.success("The ⟦SN:REDACT:1⟧ please.")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "the ⟦SN:REDACT:1⟧ please", issuedTokens: ["⟦SN:VERB:1⟧", "⟦SN:REDACT:1⟧"]),
            inputs: inputs(content: "the ⟦SN:REDACT:1⟧ please"), connection: conn)
        #expect(out == .rewritten("The ⟦SN:REDACT:1⟧ please."))
        #expect(await client.calls == 1)
    }

    @Test func contextOnlySentinelDoesNotBecomeRequired() async {
        let contextToken = "⟦SN:VERB:1⟧"
        let client = FakeClient([.success("Clean content.")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "clean content", issuedTokens: [contextToken]),
            inputs: PromptInputs(
                modePrompt: "Rewrite.", dictatedInstructions: "", content: "clean content",
                tokens: [], validTerms: [], language: "English", modeSystemInstructions: "",
                appName: nil, bundleId: nil, fieldRole: nil,
                selectedText: "context mentions \(contextToken) only"),
            connection: conn)
        #expect(out == .rewritten("Clean content."))
        #expect(await client.calls == 1)
    }

    // A token minted for the instruction (not in payload.text, so never `required`) must still be
    // usable in the output via `allowedTokens`.
    @Test func allowedTokenFromInstructionMayAppearInOutput() async {
        let client = FakeClient([.success("send to ⟦SN:REDACT:2⟧")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "send to", issuedTokens: []),
            inputs: inputs(content: "send to"), connection: conn,
            allowedTokens: ["⟦SN:REDACT:2⟧"])
        #expect(out == .rewritten("send to ⟦SN:REDACT:2⟧"))
        #expect(await client.calls == 1)
    }

    @Test func emptyOutputFallsBack() async {
        let svc = RewriteService(client: FakeClient([.success("   "), .success("   ")]))
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        guard case .localFallback(let text, _) = out else { Issue.record("expected fallback"); return }
        #expect(text == "hello")
    }

    @Test func restoresSourceBoundaryLayoutStrippedByTheLLM() async {
        let svc = RewriteService(client: FakeClient([.success("Hello.")]))
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "\n\tHello\n", issuedTokens: []),
            inputs: inputs(content: "\n\tHello\n"), connection: conn)
        #expect(out == .rewritten("\n\tHello.\n"))
    }
}
