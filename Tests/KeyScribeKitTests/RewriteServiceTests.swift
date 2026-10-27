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
        tokens: [], validTerms: [], modeSystemInstructions: "",
        appName: nil, bundleId: nil, fieldRole: nil, selectedText: nil)
}

// Each call sleeps for its own delay, so a test can make one attempt fast and the next one slow.
private actor PacedClient: LLMClient {
    private let delays: [Duration]
    private let output: String
    private(set) var calls = 0
    private(set) var cancelled = false
    init(delays: [Duration], output: String) { self.delays = delays; self.output = output }
    func complete(system: String, user: String, connection: Connection) async throws -> String {
        let delay = delays[min(calls, delays.count - 1)]
        calls += 1
        do { try await Task.sleep(for: delay) } catch { cancelled = true; throw error }
        return output
    }
}

private let protectedPayload = TokenizedPayload(text: "hi ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:1⟧"])

struct RewriteServiceTests {
    @Test func returnsRewrittenOnCleanOutput() async {
        let svc = RewriteService(client: FakeClient([.success("Hello.")]), permits: { _ in true })
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        #expect(out == .rewritten("Hello.", received: "Hello."))
    }

    @Test func oneDeadlineCoversTheWholeRewriteIncludingTheStricterRetry() async {
        let client = PacedClient(delays: [.zero, .seconds(30)], output: "dropped the token")
        let svc = RewriteService(client: client, permits: { _ in true }, deadlineSeconds: 0.3)
        let start = ContinuousClock.now
        let out = await svc.rewrite(payload: protectedPayload, inputs: inputs(), connection: conn)
        #expect(ContinuousClock.now - start < .seconds(5))
        guard case .localFallback(let text, let reason, let received) = out else { Issue.record("expected fallback"); return }
        #expect(text == protectedPayload.text)
        #expect(reason == RewriteService.deadlineReason(seconds: 0.3))
        #expect(received == "dropped the token")
        #expect(await client.calls == 2)
    }

    @Test func theDeadlineReasonNamesTheLimitInMinutes() {
        #expect(RewriteService.deadlineReason(seconds: 300).contains("5-minute limit"))
    }

    @Test func aFailureBeforeTheDeadlineKeepsItsOwnReason() async {
        let client = PacedClient(delays: [.zero], output: "dropped the token")
        let svc = RewriteService(client: client, permits: { _ in true }, deadlineSeconds: 30)
        let out = await svc.rewrite(payload: protectedPayload, inputs: inputs(), connection: conn)
        guard case .localFallback(_, let reason, _) = out else { Issue.record("expected fallback"); return }
        #expect(reason != RewriteService.deadlineReason(seconds: 30))
        #expect(reason?.contains("protected text") == true)
    }

    @Test func cancellingTheCallerCancelsTheRequestInFlight() async {
        let client = PacedClient(delays: [.seconds(30)], output: "late")
        let svc = RewriteService(client: client, permits: { _ in true })
        let task = Task { await svc.rewrite(payload: protectedPayload, inputs: inputs(), connection: conn) }
        while await client.calls == 0 { await Task.yield() }
        task.cancel()
        guard case .localFallback = await task.value else { Issue.record("expected fallback"); return }
        for _ in 0..<200 where !(await client.cancelled) { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await client.cancelled)
    }

    @Test func fallsBackToLocalWhenClientThrows() async {
        let svc = RewriteService(client: FakeClient([.failure(FakeError())]), permits: { _ in true })
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        guard case .localFallback(let text, let reason, let received) = out else { Issue.record("expected fallback"); return }
        #expect(text == "hello")
        #expect(reason != nil)
        #expect(received == nil)
    }

    @Test func keepsLocalTextWithoutCallingAServiceTheCatalogRefuses() async {
        let client = FakeClient([.success("Hello.")])
        let svc = RewriteService(client: client, permits: { _ in false })
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        guard case .localFallback(let text, let reason, let received) = out else { Issue.record("expected fallback"); return }
        #expect(text == "hello")
        #expect(reason != nil)
        #expect(received == nil)
        #expect(await client.calls == 0)
    }

    // Whatever the lineup, the client-only initializer applies the build's catalog, so a call written before
    // the policy became an argument is never looser than the build.
    @available(*, deprecated)
    @Test func theClientOnlyInitializerFollowsTheBuildCatalog() async {
        let client = FakeClient([.success("Hello.")])
        let svc = RewriteService(client: client)
        _ = await svc.rewrite(
            payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        #expect(await client.calls == (AIServiceCatalog.permits(conn) ? 1 : 0))
    }

    @Test func retriesOnceThenSucceeds() async {
        // content carries the token (as the tokenized transcript does in production), so the gate
        // requires it back and retries once when the first reply drops it.
        let client = FakeClient([.success("dropped it"), .success("kept ⟦SN:REDACT:1⟧")])
        let svc = RewriteService(client: client, permits: { _ in true })
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "kept ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:1⟧"]),
            inputs: inputs(content: "kept ⟦SN:REDACT:1⟧"), connection: conn)
        #expect(out == .rewritten("kept ⟦SN:REDACT:1⟧", received: "kept ⟦SN:REDACT:1⟧"))
        #expect(await client.calls == 2)
    }

    @Test func fallsBackAfterRetryStillFails() async {
        let client = FakeClient([.success("no token"), .success("still no token")])
        let svc = RewriteService(client: client, permits: { _ in true })
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "orig ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:1⟧"]),
            inputs: inputs(content: "orig ⟦SN:REDACT:1⟧"), connection: conn)
        guard case .localFallback(let text, let reason, let received) = out else { Issue.record("expected fallback"); return }
        #expect(text == "orig ⟦SN:REDACT:1⟧")
        #expect(reason != nil)   // gate-failure fallback is also labeled
        #expect(received == "still no token")   // last reply received, kept for the history record
        #expect(await client.calls == 2)   // initial call + exactly one stricter retry
    }

    @Test func passesWhenIssuedTokenAbsentFromSentContent() async {
        let client = FakeClient([.success("The ⟦SN:REDACT:1⟧ please.")])
        let svc = RewriteService(client: client, permits: { _ in true })
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "the ⟦SN:REDACT:1⟧ please", issuedTokens: ["⟦SN:VERB:1⟧", "⟦SN:REDACT:1⟧"]),
            inputs: inputs(content: "the ⟦SN:REDACT:1⟧ please"), connection: conn)
        #expect(out == .rewritten("The ⟦SN:REDACT:1⟧ please.", received: "The ⟦SN:REDACT:1⟧ please."))
        #expect(await client.calls == 1)
    }

    @Test func contextOnlySentinelDoesNotBecomeRequired() async {
        let contextToken = "⟦SN:VERB:1⟧"
        let client = FakeClient([.success("Clean content.")])
        let svc = RewriteService(client: client, permits: { _ in true })
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "clean content", issuedTokens: [contextToken]),
            inputs: PromptInputs(
                modePrompt: "Rewrite.", dictatedInstructions: "", content: "clean content",
                tokens: [], validTerms: [], modeSystemInstructions: "",
                appName: nil, bundleId: nil, fieldRole: nil,
                selectedText: "context mentions \(contextToken) only"),
            connection: conn)
        #expect(out == .rewritten("Clean content.", received: "Clean content."))
        #expect(await client.calls == 1)
    }

    @Test func allowedTokenFromInstructionMayAppearInOutput() async {
        let client = FakeClient([.success("send to ⟦SN:REDACT:2⟧")])
        let svc = RewriteService(client: client, permits: { _ in true })
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "send to", issuedTokens: []),
            inputs: inputs(content: "send to"), connection: conn,
            allowedTokens: ["⟦SN:REDACT:2⟧"])
        #expect(out == .rewritten("send to ⟦SN:REDACT:2⟧", received: "send to ⟦SN:REDACT:2⟧"))
        #expect(await client.calls == 1)
    }

    @Test func emptyOutputFallsBack() async {
        let svc = RewriteService(client: FakeClient([.success("   "), .success("   ")]), permits: { _ in true })
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        guard case .localFallback(let text, _, let received) = out else { Issue.record("expected fallback"); return }
        #expect(text == "hello")
        #expect(received == "   ")
    }

    @Test func restoresSourceBoundaryLayoutStrippedByTheLLM() async {
        let svc = RewriteService(client: FakeClient([.success("Hello.")]), permits: { _ in true })
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "\n\tHello\n", issuedTokens: []),
            inputs: inputs(content: "\n\tHello\n"), connection: conn)
        #expect(out == .rewritten("\n\tHello.\n", received: "Hello."))
    }

    @Test func unwrapsContentEchoFromModelOutput() async {
        let svc = RewriteService(client: FakeClient([.success("<content>Hello.</content>")]), permits: { _ in true })
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        #expect(out == .rewritten("Hello.", received: "<content>Hello.</content>"))
    }

    @Test func keepsEchoShapedOutputWhenSentContentCarriedTheTags() async {
        let svc = RewriteService(client: FakeClient([.success("<content>Hello.</content>")]), permits: { _ in true })
        let out = await svc.rewrite(
            payload: TokenizedPayload(text: "<content>hello</content>", issuedTokens: []),
            inputs: inputs(content: "<content>hello</content>"), connection: conn)
        #expect(out == .rewritten("<content>Hello.</content>", received: "<content>Hello.</content>"))
    }

    @Test func emptyContentEchoFailsGateThenRetries() async {
        let client = FakeClient([.success("<content>\n</content>"), .success("Hello.")])
        let svc = RewriteService(client: client, permits: { _ in true })
        let out = await svc.rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn)
        #expect(out == .rewritten("Hello.", received: "Hello."))
        #expect(await client.calls == 2)
    }
}
