import Foundation
import KeyScribeKit

// The single implementation of the AI-service connect sequence, shared by onboarding and Settings: test the
// endpoint with the key the user typed → on success store the key → upsert the connection. Nothing reaches the
// Keychain until the test passes, so a failed or cancelled test has nothing to undo. Neither surface may fork
// this — a half-configured, never-tested service must be impossible to persist.
@MainActor
struct AIServiceConnector {
    let repository: ConfigRepository
    let permits: (Connection) -> Bool
    var saveAPIKey: (String, String) -> Bool = { KeychainStore.set($1, for: $0) && KeychainStore.has($0) }
    var deleteAPIKey: (String) -> Bool = { KeychainStore.delete($0) }
    var testConnection: (Connection, String?) async -> ConnectionTestState = {
        await ConnectionTester.shared.test($0, apiKey: $1)
    }

    enum Outcome: Equatable {
        case connected(Connection)
        case failed(String)
        case cancelled
    }

    // Reported back even on failure so a retry can reuse the same id via `reusingId`.
    struct Result {
        let outcome: Outcome
        let allocatedId: String
    }

    private var supportDir: URL { repository.supportDir }

    // Strips any UUID a prior rotation already appended, so repeated rotations can't grow the ref
    // unboundedly (base.uuid1.uuid2…) — it stays base + exactly one UUID.
    static func freshKeyRef(replacing keyRef: String) -> String {
        let parts = keyRef.split(separator: ".", omittingEmptySubsequences: false)
        let base = parts.last.flatMap { UUID(uuidString: String($0)) } != nil
            ? parts.dropLast().joined(separator: ".") : keyRef
        return "\(base).\(UUID().uuidString)"
    }

    func connect(draft: AIConnectionDraft, reusingId: String?) async -> Result {
        let existing = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = reusingId ?? ConnectionStore.newID(for: name, existing: existing.map(\.id))
        let replaced = existing.first { $0.id == id }
        let keyRef = replaced.map { Self.freshKeyRef(replacing: $0.keyRef) } ?? "keyscribe.llm.\(id)"
        let connection = draft.connection(id: id, keyRef: keyRef)
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesKey = connection.authMethod == .apiKey
        func result(_ outcome: Outcome) -> Result { Result(outcome: outcome, allocatedId: id) }
        // A service the build does not offer is refused before the endpoint is reached — no field the user
        // could fix would change the answer.
        guard permits(connection) else {
            return result(.failed("This AI service isn't available in this app."))
        }
        if usesKey, key.isEmpty {
            return result(.failed("API key is required."))
        }
        let testResult = await testConnection(connection, usesKey ? key : nil)
        if Task.isCancelled { return result(.cancelled) }
        if case .failed(let message) = testResult {
            return result(.failed("Connection test failed: \(message)"))
        }
        if usesKey, !saveAPIKey(keyRef, key) {
            return result(.failed("Could not save the API key."))
        }
        do {
            try repository.upsertConnection(connection)
        } catch {
            let failure = "Could not save the AI service: \(error.localizedDescription)"
            guard usesKey else { return result(.failed(failure)) }
            return result(.failed(deleteAPIKey(keyRef) ? failure
                : "\(failure) The new API key is still in the Keychain, unused; you can delete it in Keychain Access."))
        }
        if let replaced, replaced.authMethod == .apiKey, replaced.keyRef != keyRef, !deleteAPIKey(replaced.keyRef) {
            Log.config.error("could not remove a replaced API key from the Keychain")
        }
        return result(.connected(connection))
    }
}
