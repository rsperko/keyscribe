import Foundation
import KeyScribeKit

// The single implementation of the AI-service connect sequence shared by onboarding and Settings (UX2
// phase 5b): validate → save the API key under keyscribe.llm.<id> → test the endpoint → on failure/cancel
// delete the just-saved key and surface the error → on success upsert the connection. Neither surface may
// fork this; a half-configured, never-tested service must be impossible to persist.
@MainActor
struct AIServiceConnector {
    let repository: ConfigRepository
    var saveAPIKey: (String, String) -> Bool = { KeychainStore.set($1, for: $0) && KeychainStore.has($0) }
    var deleteAPIKey: (String) -> Void = { KeychainStore.delete($0) }
    var readAPIKey: (String) -> String? = { KeychainStore.get($0) }
    var testConnection: (Connection) async -> ConnectionTestState = { await ConnectionTester().test($0) }

    enum Outcome: Equatable {
        case connected(Connection)
        case failed(String)
        case cancelled
    }

    // The id used for this attempt is reported back (even on failure) so a retry can reuse it — a re-Connect
    // after a failed test must not strand a key under a fresh id. Pass `reusingId` from the prior attempt.
    struct Result {
        let outcome: Outcome
        let allocatedId: String
    }

    private var supportDir: URL { repository.supportDir }

    func connect(draft: AIConnectionDraft, reusingId: String?) async -> Result {
        let existing = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = reusingId ?? ConnectionStore.newID(for: name, existing: existing.map(\.id))
        let keyRef = "keyscribe.llm.\(id)"
        let connection = draft.connection(id: id, keyRef: keyRef)
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        func result(_ outcome: Outcome) -> Result { Result(outcome: outcome, allocatedId: id) }
        if connection.authMethod == .apiKey, key.isEmpty {
            return result(.failed("API key is required."))
        }
        // Reusing an existing connection's id (a retest) reuses its keyRef, so saving overwrites a key that
        // may already be working. Capture the prior value first and restore it on rollback rather than
        // deleting — a failed retest must not strand an already-persisted connection without a credential.
        let priorKey = connection.authMethod == .apiKey ? readAPIKey(keyRef) : nil
        func rollbackKey() {
            guard connection.authMethod == .apiKey else { return }
            if let priorKey { _ = saveAPIKey(keyRef, priorKey) } else { deleteAPIKey(keyRef) }
        }
        if connection.authMethod == .apiKey, !saveAPIKey(keyRef, key) {
            return result(.failed("Could not save the API key."))
        }
        let testResult = await testConnection(connection)
        // The caller may have been torn down while the test was in flight (a closed wizard, a discarded
        // Settings draft). Roll the key back to what it was before the test so a discarded draft neither
        // strands a fresh key nor destroys a pre-existing one.
        if Task.isCancelled {
            rollbackKey()
            return result(.cancelled)
        }
        if case .failed(let message) = testResult {
            rollbackKey()
            return result(.failed("Connection test failed: \(message)"))
        }
        do {
            try repository.upsertConnection(connection)
        } catch {
            rollbackKey()
            return result(.failed("Could not save the AI service: \(error.localizedDescription)"))
        }
        return result(.connected(connection))
    }
}
