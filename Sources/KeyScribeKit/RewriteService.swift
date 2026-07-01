import Foundation

// The seam to a BYOK provider. The concrete network client (OpenAI/Anthropic/Gemini over HTTP,
// key fetched from Keychain by the connection's key_ref) is an app-side adapter built in an
// interactive session; the orchestration below is provider-agnostic and fully testable.
public protocol LLMClient: Sendable {
    func complete(system: String, user: String, connection: Connection) async throws -> String
}

public enum RewriteOutcome: Equatable, Sendable {
    case rewritten(String)
    case localFallback(localText: String)
}

// Orchestrates one optional rewrite (design.md §4.2, prompt_design.md): assemble the prompt, call
// the provider, run the hard validation gate; on a gate failure retry once with a stricter prompt;
// on a second failure — or any client error (offline / no key) — fall back to the local
// un-rewritten text. Never inserts partially-restored text.
public actor RewriteService {
    private let client: LLMClient
    private static let strictReminder =
        "IMPORTANT: Return ONLY the transformed text and reproduce every ⟦SN:…⟧ token verbatim, exactly once."

    public init(client: LLMClient) { self.client = client }

    public func rewrite(
        localText: String, inputs: PromptInputs, connection: Connection,
        issuedTokens: [String], allowDeletion: Bool = false, prompt: RewritePrompt? = nil
    ) async -> RewriteOutcome {
        // Reuse a prompt the caller already assembled (RewriteRequestBuilder builds it for the history
        // record) rather than assembling the same inputs twice. Callers without one (tests) pass nil.
        let base = prompt ?? PromptAssembler.assemble(inputs)
        // Require only the tokens the model actually SAW. An issued token can be legitimately absent
        // from the sent content — a verbatim token swallowed INSIDE a redaction span, a token whose
        // segment was deleted by "scratch that", or content truncated to fit the budget — and the model
        // can never reproduce a token it never received. Gating on all issued tokens would fail-and-fall-
        // back (after a doomed stricter retry) for exactly the privacy+verbatim combos this targets;
        // restore still unwinds every real token via the LIFO reverse pass. Stray/duplicate checks are
        // unaffected (they scan the output, not this set).
        let required = issuedTokens.filter { base.user.contains($0) }
        var attempt = 0
        while true {
            let system = attempt == 0 ? base.system : base.system + "\n" + Self.strictReminder
            let output: String
            do {
                output = try await client.complete(system: system, user: base.user, connection: connection)
            } catch {
                return .localFallback(localText: localText)
            }
            switch ValidationGate.check(output: output, issuedTokens: required, allowDeletion: allowDeletion) {
            case .pass:
                return .rewritten(output)
            case .fail:
                guard ValidationGate.recovery(attempt: attempt) == .retryStricter else {
                    return .localFallback(localText: localText)
                }
                attempt += 1
            }
        }
    }
}
