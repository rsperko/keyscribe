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
        appName: nil, bundleId: nil, fieldRole: nil, visibleWindowText: nil, selectedText: nil)
}

struct RewriteServiceTests {
    @Test func returnsRewrittenOnCleanOutput() async {
        let svc = RewriteService(client: FakeClient([.success("Hello.")]))
        let out = await svc.rewrite(localText: "hello", inputs: inputs(), connection: conn, issuedTokens: [])
        #expect(out == .rewritten("Hello."))
    }

    @Test func fallsBackToLocalWhenClientThrows() async {
        let svc = RewriteService(client: FakeClient([.failure(FakeError())]))
        let out = await svc.rewrite(localText: "hello", inputs: inputs(), connection: conn, issuedTokens: [])
        #expect(out == .localFallback(localText: "hello"))
    }

    @Test func retriesOnceThenSucceeds() async {
        // first output drops the token (gate fail) → retry → second output is clean
        let client = FakeClient([.success("dropped it"), .success("kept ⟦SN:REDACT:1⟧")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            localText: "kept ⟦SN:REDACT:1⟧", inputs: inputs(), connection: conn,
            issuedTokens: ["⟦SN:REDACT:1⟧"])
        #expect(out == .rewritten("kept ⟦SN:REDACT:1⟧"))
        #expect(await client.calls == 2)
    }

    @Test func fallsBackAfterRetryStillFails() async {
        let client = FakeClient([.success("no token"), .success("still no token")])
        let svc = RewriteService(client: client)
        let out = await svc.rewrite(
            localText: "orig ⟦SN:REDACT:1⟧", inputs: inputs(), connection: conn,
            issuedTokens: ["⟦SN:REDACT:1⟧"])
        #expect(out == .localFallback(localText: "orig ⟦SN:REDACT:1⟧"))
        #expect(await client.calls == 2)   // initial + one stricter retry, no more
    }

    @Test func emptyOutputFallsBack() async {
        let svc = RewriteService(client: FakeClient([.success("   "), .success("   ")]))
        let out = await svc.rewrite(localText: "hello", inputs: inputs(), connection: conn, issuedTokens: [])
        #expect(out == .localFallback(localText: "hello"))
    }
}
