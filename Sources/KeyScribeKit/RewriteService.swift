import Foundation

// The seam to a BYOK provider. The concrete network client (provider over HTTP, key fetched from Keychain by
// the connection's key_ref) is an app-side adapter; the orchestration below is provider-agnostic and testable.
public protocol LLMClient: Sendable {
    func complete(system: String, user: String, connection: Connection) async throws -> String
    // Optional: warm the endpoint's connection during recording so the rewrite doesn't pay setup. No content.
    func preconnect(connection: Connection) async
}

public extension LLMClient {
    func preconnect(connection: Connection) async {}
}

public enum RewriteOutcome: Equatable, Sendable {
    // `received` is the provider's raw reply, verbatim and pre-enforcement (before the <content>-echo
    // unwrap and boundary-layout repair) — stored in history so "Show exactly what was received" mirrors
    // "Show exactly what was sent" and model misbehavior stays observable instead of silently corrected.
    // Like the sent prompt, it carries ⟦SN:…⟧ tokens, never their originals.
    case rewritten(String, received: String)
    // `reason` records WHY the rewrite was abandoned (an HTTP error, a missing key, a validation failure)
    // so the fallback is diagnosable instead of silent. It is persisted to history and logged publicly, so
    // it must never carry raw provider bodies or command stderr — a user-supplied token command can print a
    // credential and a compatible endpoint can echo request content back (KS-07). Client errors are
    // sanitized through `RewriteFailureReporting`; anything that does not opt in is reported generically
    // rather than trusted. `received` is the last reply the provider returned before the fallback (the
    // evidence for `reason`); nil when the call itself failed.
    case localFallback(localText: String, reason: String?, received: String?)
}

// An error that can name itself in persisted history and public logs. Conformance is an assertion that
// `rewriteFailureReason` is a stable, sanitized string built only from the error's own structure (a status
// code, an exit code) — never from a response body, stderr, or anything else an untrusted process or
// endpoint controls. Default-deny: RewriteService reports a non-conforming error generically instead of
// reaching for `localizedDescription`, so a new error type cannot leak by omission.
public protocol RewriteFailureReporting: Error {
    var rewriteFailureReason: String { get }
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

    static let genericFailureReason = "The AI service could not be reached."

    static func sanitizedReason(for error: Error) -> String {
        (error as? RewriteFailureReporting)?.rewriteFailureReason ?? genericFailureReason
    }

    public func rewrite(
        payload: TokenizedPayload, inputs: PromptInputs, connection: Connection,
        allowDeletion: Bool = false, allowedTokens: [String] = [], prompt: RewritePrompt? = nil
    ) async -> RewriteOutcome {
        // Tokens and fallback text both come from the sealed payload. On failure, fall back to tokenized
        // text; the caller's restore pass unwinds it. `allowedTokens` are minted outside payload.text
        // (selection-mode instruction redaction) — never required.
        let localText = payload.text
        let base = prompt ?? PromptAssembler.assemble(inputs)
        let required = payload.issuedTokens.filter { payload.text.contains($0) }
        var attempt = 0
        var lastReceived: String?
        while true {
            let system = attempt == 0 ? base.system : base.system + "\n" + Self.strictReminder
            let output: String
            do {
                output = try await client.complete(system: system, user: base.user, connection: connection)
            } catch {
                return .localFallback(
                    localText: localText, reason: Self.sanitizedReason(for: error), received: lastReceived)
            }
            lastReceived = output
            // Unwrap a whole-output <content> echo BEFORE the gate, so an echo whose inside is empty
            // fails the gate (→ stricter retry) instead of inserting nothing.
            let candidate = PromptAssembler.unwrappingContentEcho(output, sentContent: inputs.content)
            switch ValidationGate.check(
                output: candidate, issuedTokens: required, allowedTokens: allowedTokens, allowDeletion: allowDeletion
            ) {
            case .pass:
                return .rewritten(OutputCleanup.preserveBoundaryLayout(from: localText, in: candidate), received: output)
            case .fail:
                guard ValidationGate.recovery(attempt: attempt) == .retryStricter else {
                    return .localFallback(
                        localText: localText,
                        reason: "The AI reply left out or changed protected text, so your local version was kept.",
                        received: lastReceived)
                }
                attempt += 1
            }
        }
    }
}
