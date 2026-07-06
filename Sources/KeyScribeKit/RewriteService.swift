import Foundation

// The seam to a BYOK provider. The concrete network client (provider over HTTP, key fetched from Keychain by
// the connection's key_ref) is an app-side adapter; the orchestration below is provider-agnostic and testable.
public protocol LLMClient: Sendable {
    func complete(system: String, user: String, connection: Connection) async throws -> String
}

public enum RewriteOutcome: Equatable, Sendable {
    case rewritten(String)
    case localFallback(localText: String)
}

// Orchestrates one optional rewrite (design.md §4.2, prompt_design.md): assemble the prompt, call the
// provider, run the hard validation gate; on a gate failure retry once with a stricter prompt; on a second
// failure — or any client error (offline / no key) — fall back to local un-rewritten text. Never inserts
// partially-restored text.
public actor RewriteService {
    private let client: LLMClient
    private static let strictReminder =
        "IMPORTANT: Return ONLY the transformed text and reproduce every ⟦SN:…⟧ token verbatim, exactly once."

    public init(client: LLMClient) { self.client = client }

    public func rewrite(
        payload: TokenizedPayload, inputs: PromptInputs, connection: Connection,
        allowDeletion: Bool = false, allowedTokens: [String] = [], prompt: RewritePrompt? = nil,
        preserveBoundaryLayout: Bool = false
    ) async -> RewriteOutcome {
        // Tokens and fallback text both come from the sealed payload. On failure, fall back to tokenized
        // text; the caller's restore pass unwinds it. `allowedTokens` are minted outside payload.text
        // (selection-mode instruction redaction) — never required.
        let localText = payload.text
        let base = prompt ?? PromptAssembler.assemble(inputs)
        let required = payload.issuedTokens.filter { payload.text.contains($0) }
        var attempt = 0
        while true {
            let system = attempt == 0 ? base.system : base.system + "\n" + Self.strictReminder
            let output: String
            do {
                output = try await client.complete(system: system, user: base.user, connection: connection)
            } catch {
                return .localFallback(localText: localText)
            }
            switch ValidationGate.check(
                output: output, issuedTokens: required, allowedTokens: allowedTokens, allowDeletion: allowDeletion
            ) {
            case .pass:
                let repaired = preserveBoundaryLayout
                    ? OutputCleanup.preserveBoundaryLayout(from: localText, in: output)
                    : output
                return .rewritten(repaired)
            case .fail:
                guard ValidationGate.recovery(attempt: attempt) == .retryStricter else {
                    return .localFallback(localText: localText)
                }
                attempt += 1
            }
        }
    }
}
