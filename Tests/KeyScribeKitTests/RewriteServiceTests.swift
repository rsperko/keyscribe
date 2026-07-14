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
        #expect(out == .rewritten("Hello.", received: "Hello."))
    }

    @Test func fallsBackToLocalWhenClientThrows() async {
        let svc = RewriteService(client: FakeClient([.failure(FakeError())]))
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        // fallback carries a reason so a failure is diagnosable, not silent.
        guard case .localFallback(let text, let reason, let received) = out else { Issue.record("expected fallback"); return }
        #expect(text == "hello")
        #expect(reason != nil)
        #expect(received == nil)
    }

    @Test func retriesOnceThenSucceeds() async {
        // content carries the token (as the tokenized transcript does in production), so the gate
        // requires it back and retries once when the first reply drops it.
        let client = FakeClient([.success("dropped it"), .success("kept ⟦SN:REDACT:1⟧")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "kept ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:1⟧"]),
            inputs: inputs(content: "kept ⟦SN:REDACT:1⟧"), connection: conn)
        #expect(out == .rewritten("kept ⟦SN:REDACT:1⟧", received: "kept ⟦SN:REDACT:1⟧"))
        #expect(await client.calls == 2)
    }

    @Test func fallsBackAfterRetryStillFails() async {
        let client = FakeClient([.success("no token"), .success("still no token")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "orig ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:1⟧"]),
            inputs: inputs(content: "orig ⟦SN:REDACT:1⟧"), connection: conn)
        guard case .localFallback(let text, let reason, let received) = out else { Issue.record("expected fallback"); return }
        #expect(text == "orig ⟦SN:REDACT:1⟧")
        #expect(reason != nil)   // gate-failure fallback is also labeled
        #expect(received == "still no token")   // last reply received, kept for the history record
        #expect(await client.calls == 2)   // initial call + exactly one stricter retry
    }

    // A token issued but swallowed upstream (a verbatim token captured inside a redaction span) never
    // reaches the sent content, so the gate must not require it back — otherwise every privacy+verbatim
    // dictation would retry and fall back needlessly.
    @Test func passesWhenIssuedTokenAbsentFromSentContent() async {
        let client = FakeClient([.success("The ⟦SN:REDACT:1⟧ please.")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "the ⟦SN:REDACT:1⟧ please", issuedTokens: ["⟦SN:VERB:1⟧", "⟦SN:REDACT:1⟧"]),
            inputs: inputs(content: "the ⟦SN:REDACT:1⟧ please"), connection: conn)
        #expect(out == .rewritten("The ⟦SN:REDACT:1⟧ please.", received: "The ⟦SN:REDACT:1⟧ please."))
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
        #expect(out == .rewritten("Clean content.", received: "Clean content."))
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
        #expect(out == .rewritten("send to ⟦SN:REDACT:2⟧", received: "send to ⟦SN:REDACT:2⟧"))
        #expect(await client.calls == 1)
    }

    @Test func emptyOutputFallsBack() async {
        let svc = RewriteService(client: FakeClient([.success("   "), .success("   ")]))
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        guard case .localFallback(let text, _, let received) = out else { Issue.record("expected fallback"); return }
        #expect(text == "hello")
        #expect(received == "   ")
    }

    @Test func restoresSourceBoundaryLayoutStrippedByTheLLM() async {
        let svc = RewriteService(client: FakeClient([.success("Hello.")]))
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "\n\tHello\n", issuedTokens: []),
            inputs: inputs(content: "\n\tHello\n"), connection: conn)
        #expect(out == .rewritten("\n\tHello.\n", received: "Hello."))
    }

    @Test func unwrapsContentEchoFromModelOutput() async {
        let svc = RewriteService(client: FakeClient([.success("<content>Hello.</content>")]))
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        #expect(out == .rewritten("Hello.", received: "<content>Hello.</content>"))
    }

    @Test func keepsEchoShapedOutputWhenSentContentCarriedTheTags() async {
        let svc = RewriteService(client: FakeClient([.success("<content>Hello.</content>")]))
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "<content>hello</content>", issuedTokens: []),
            inputs: inputs(content: "<content>hello</content>"), connection: conn)
        #expect(out == .rewritten("<content>Hello.</content>", received: "<content>Hello.</content>"))
    }

    @Test func emptyContentEchoFailsGateThenRetries() async {
        let client = FakeClient([.success("<content>\n</content>"), .success("Hello.")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        #expect(out == .rewritten("Hello.", received: "Hello."))
        #expect(await client.calls == 2)
    }
}
