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
        issuedTokens: [String], allowDeletion: Bool = false
    ) async -> RewriteOutcome {
        let base = PromptAssembler.assemble(inputs)
        var attempt = 0
        while true {
            let system = attempt == 0 ? base.system : base.system + "\n" + Self.strictReminder
            let output: String
            do {
                output = try await client.complete(system: system, user: base.user, connection: connection)
            } catch {
                return .localFallback(localText: localText)
            }
            switch ValidationGate.check(output: output, issuedTokens: issuedTokens, allowDeletion: allowDeletion) {
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
