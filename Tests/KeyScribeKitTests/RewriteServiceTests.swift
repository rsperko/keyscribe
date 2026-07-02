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
        #expect(out == .localFallback(localText: "hello"))
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
        #expect(out == .localFallback(localText: "orig ⟦SN:REDACT:1⟧"))
        #expect(await client.calls == 2)   // initial + one stricter retry, no more
    }

    // W4/H2: an issued token that was swallowed upstream (a verbatim token captured inside a redaction
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

    @Test func emptyOutputFallsBack() async {
        let svc = RewriteService(client: FakeClient([.success("   "), .success("   ")]))
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        #expect(out == .localFallback(localText: "hello"))
    }
}
