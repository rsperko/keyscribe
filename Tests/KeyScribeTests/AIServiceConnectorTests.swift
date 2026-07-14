import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Drives ConnectionTester to a fixed verdict: a passing test returns "OK", a failure throws so the tester
// reports .failed. The verdict is decided by the caller-supplied closure keyed off the connection.
private struct StubLLMClient: LLMClient {
    let testConnection: @Sendable (Connection) async -> ConnectionTestState
    func complete(system: String, user: String, connection: Connection) async throws -> String {
        if case .failed = await testConnection(connection) {
            throw ProviderTransportError.http(401, body: "unauthorized")
        }
        return "OK"
    }
}

@MainActor
struct AIServiceConnectorTests {
    private let starterPreset = ConnectionPreset(
        id: "starter", name: "Starter AI", provider: .gemini, defaultModel: "starter-model")

    private func tempSupport() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-connector-\(UUID().uuidString)", isDirectory: true)
    }

    private func draft() -> AIConnectionDraft {
        var d = AIConnectionDraft()
        d.name = "Gemini"
        d.provider = .gemini
        d.model = "gemini-2.5-flash"
        d.apiKey = "secret"
        return d
    }

    @Test func passingTestSavesTheConnection() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var savedRef: String?
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            saveAPIKey: { ref, _ in savedRef = ref; return true },
            deleteAPIKey: { _ in },
            readAPIKey: { _ in nil },
            testConnection: { _ in .passed })

        let result = await connector.connect(draft: draft(), reusingId: nil)

        guard case .connected(let connection) = result.outcome else { Issue.record("expected connected"); return }
        #expect(connection.id == "gemini")
        #expect(savedRef == "keyscribe.llm.gemini")
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.map(\.id) == ["gemini"])
    }

    private func noAuthDraft() -> AIConnectionDraft {
        var d = AIConnectionDraft()
        d.name = "Open Gateway"
        d.provider = .openaiCompatible
        d.baseURL = "https://gateway.example.com/open/v1"
        d.model = "standard-model"
        d.authMethod = .none
        return d
    }

    @Test func noAuthConnectionConnectsWithoutTouchingTheKeychain() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var keychainTouched = false
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            saveAPIKey: { _, _ in keychainTouched = true; return true },
            deleteAPIKey: { _ in keychainTouched = true },
            readAPIKey: { _ in keychainTouched = true; return nil },
            testConnection: { _ in .passed })

        let result = await connector.connect(draft: noAuthDraft(), reusingId: nil)

        guard case .connected(let connection) = result.outcome else { Issue.record("expected connected"); return }
        #expect(connection.authMethod == .none)
        #expect(!keychainTouched)
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.map(\.id) == ["open-gateway"])
    }

    @Test func failedNoAuthTestPersistsNothingAndLeavesTheKeychainAlone() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var keychainTouched = false
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            saveAPIKey: { _, _ in keychainTouched = true; return true },
            deleteAPIKey: { _ in keychainTouched = true },
            readAPIKey: { _ in keychainTouched = true; return nil },
            testConnection: { _ in .failed("503 Service Unavailable") })

        let result = await connector.connect(draft: noAuthDraft(), reusingId: nil)

        #expect(result.outcome == .failed("Connection test failed: 503 Service Unavailable"))
        #expect(!keychainTouched)
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.isEmpty)
    }

    @Test func failedTestRollsBackTheKeyAndPersistsNothing() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var deletedRef: String?
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            saveAPIKey: { _, _ in true },
            deleteAPIKey: { deletedRef = $0 },
            readAPIKey: { _ in nil },
            testConnection: { _ in .failed("401 Unauthorized") })

        let result = await connector.connect(draft: draft(), reusingId: nil)

        #expect(result.outcome == .failed("Connection test failed: 401 Unauthorized"))
        #expect(deletedRef == "keyscribe.llm.gemini")
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.isEmpty)
    }

    // A retest of an already-persisted connection reuses its keyRef, so saving overwrites a possibly-good key.
    // A failed retest must RESTORE the prior key, never delete it — otherwise a working service is left
    // with no credential.
    @Test func failedRetestRestoresAPreExistingKeyInsteadOfDeletingIt() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var saves: [(ref: String, value: String)] = []
        var deletedRef: String?
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            saveAPIKey: { ref, value in saves.append((ref, value)); return true },
            deleteAPIKey: { deletedRef = $0 },
            readAPIKey: { _ in "existing-good-key" },
            testConnection: { _ in .failed("401 Unauthorized") })

        let result = await connector.connect(draft: draft(), reusingId: "gemini")

        #expect(result.outcome == .failed("Connection test failed: 401 Unauthorized"))
        #expect(deletedRef == nil)
        #expect(saves.last?.ref == "keyscribe.llm.gemini")
        #expect(saves.last?.value == "existing-good-key")
    }

    @Test func emptyAPIKeyFailsBeforeSavingOrTesting() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var saved = false, tested = false
        var d = draft(); d.apiKey = "   "
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            saveAPIKey: { _, _ in saved = true; return true },
            deleteAPIKey: { _ in },
            readAPIKey: { _ in nil },
            testConnection: { _ in tested = true; return .passed })

        let result = await connector.connect(draft: d, reusingId: nil)

        #expect(result.outcome == .failed("API key is required."))
        #expect(!saved)
        #expect(!tested)
    }

    @Test func reusingIdKeepsTheSameAllocationAcrossRetries() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            saveAPIKey: { _, _ in true }, deleteAPIKey: { _ in },
            readAPIKey: { _ in nil },
            testConnection: { _ in .failed("nope") })

        let first = await connector.connect(draft: draft(), reusingId: nil)
        let second = await connector.connect(draft: draft(), reusingId: first.allocatedId)

        #expect(first.allocatedId == "gemini")
        #expect(second.allocatedId == "gemini")   // did not become gemini-2 despite the first failure
    }

    // MARK: Settings add-a-service flow (persist-immediately)

    private func settingsModel(support: URL) -> AIServiceSettingsModel {
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        return AIServiceSettingsModel(
            repository: repository,
            tester: ConnectionTester(client: StubLLMClient(testConnection: { _ in .passed })),
            saveAPIKey: { _, _ in true }, deleteAPIKey: { _ in })
    }

    // Persists a seeded connection immediately and selects it — no test, no key — landing in an honest
    // "no key" config state, not usable until the user finishes it in the editor and tests it.
    @Test func addServicePersistsASeededConnectionAndSelectsIt() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)

        model.addService(preset: starterPreset)

        let saved = ConnectionStore.loadOrDefault(supportDir: support).connections
        #expect(saved.count == 1)
        let connection = try! #require(saved.first)
        #expect(connection.provider == .gemini)
        #expect(connection.model == starterPreset.defaultModel)
        #expect(model.selectedID == connection.id)
        #expect(model.testState(for: connection.id) == nil)   // never claimed as working on add
    }

    @Test func firstServiceOfferSurvivesSavingItsKeyUntilTheTestPasses() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let modes = support.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modes, withIntermediateDirectories: true)
        var pendingMode = Mode(id: "rewrite", name: "Rewrite")
        pendingMode.aiRewrite = .init(connection: "", prompt: "Rewrite")
        try? ModeStore.write(pendingMode, to: modes)
        let model = settingsModel(support: support)
        model.addService(preset: starterPreset)
        let connection = try! #require(model.selected)

        model.update(connection, apiKey: "key")
        model.test(connection)
        await model.testTask?.value

        #expect(model.pendingConnectOffer?.connectionId == connection.id)
    }

    // Must persist through the injected saveAPIKey seam, never KeychainStore directly — otherwise every
    // test run writes a real entry into the developer's login Keychain.
    @Test func updateSavesTheKeyThroughTheInjectedSeam() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        var saved: (ref: String, value: String)?
        let model = AIServiceSettingsModel(
            repository: repository,
            tester: ConnectionTester(client: StubLLMClient(testConnection: { _ in .passed })),
            saveAPIKey: { ref, value in saved = (ref, value); return true },
            deleteAPIKey: { _ in })
        model.addService(preset: starterPreset)
        let connection = try! #require(model.selected)

        model.update(connection, apiKey: "topsecret")

        #expect(saved?.ref == connection.keyRef)
        #expect(saved?.value == "topsecret")
        #expect(model.hasKey(connection))
    }

    @Test func deleteRemovesTheKeyThroughTheInjectedSeam() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        var deletedRef: String?
        let model = AIServiceSettingsModel(
            repository: repository,
            tester: ConnectionTester(client: StubLLMClient(testConnection: { _ in .passed })),
            saveAPIKey: { _, _ in true },
            deleteAPIKey: { deletedRef = $0 })
        model.addService(preset: starterPreset)
        let connection = try! #require(model.selected)

        model.delete(connection)

        #expect(deletedRef == connection.keyRef)
    }

    @Test func credentialBoundaryMintsAKeyReference() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)
        model.addService(preset: starterPreset)
        let connection = try! #require(model.selected)
        var updated = connection
        updated.provider = .openai

        model.updateAcrossCredentialBoundary(updated)

        #expect(model.selected?.keyRef != connection.keyRef)
    }

    // Repeated boundary crossings must not stack UUIDs onto the keyRef (base.uuid1.uuid2…) — each rotation
    // strips the prior UUID and appends one fresh, so the ref stays base + exactly one UUID.
    @Test func repeatedCredentialBoundaryRotationsStayBounded() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)
        model.addService(preset: starterPreset)
        let base = try #require(model.selected).keyRef

        var first = try #require(model.selected); first.provider = .openai
        model.updateAcrossCredentialBoundary(first)
        let afterFirst = try #require(model.selected).keyRef

        var second = try #require(model.selected); second.provider = .openaiCompatible
        model.updateAcrossCredentialBoundary(second)
        let afterSecond = try #require(model.selected).keyRef

        #expect(afterSecond.hasPrefix("\(base)."))
        #expect(afterFirst != afterSecond)
        let segments = afterSecond.split(separator: ".")
        #expect(UUID(uuidString: String(segments.last!)) != nil)                // ends in a fresh UUID
        #expect(UUID(uuidString: String(segments[segments.count - 2])) == nil)  // not two stacked UUIDs
    }

    @Test func addServiceSeedsThePresetDefaultTokenCommand() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)
        let commandPreset = ConnectionPreset(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            baseURL: "https://gateway.example.com/keyed/v1", defaultModel: "standard-model",
            allowedAuthMethods: [.apiKey, .tokenCommand], defaultAuthMethod: .tokenCommand,
            defaultTokenCommand: "gateway-cli token mint")

        model.addService(preset: commandPreset)

        let connection = try #require(ConnectionStore.loadOrDefault(supportDir: support).connections.first)
        #expect(connection.authMethod == .tokenCommand)
        #expect(connection.tokenCommand == "gateway-cli token mint")
        #expect(connection.baseUrl == "https://gateway.example.com/keyed/v1")
        #expect(connection.configIssue == nil)
    }

    // A provider starter is reusable: a second connection for the same provider disambiguates the name
    // rather than overwriting the first.
    @Test func addingASecondServiceForAProviderKeepsBothWithDistinctNames() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)

        model.addService(preset: starterPreset)
        model.addService(preset: starterPreset)

        let saved = ConnectionStore.loadOrDefault(supportDir: support).connections
        #expect(saved.count == 2)
        #expect(Set(saved.map(\.name)).count == 2)   // uniqued, not two identical "Gemini" rows
    }

    // MARK: shared status vocabulary

    @Test func listRowAndSummaryDeriveIdenticalStatus() {
        let connection = Connection(
            id: "c", name: "C", provider: .gemini, model: "m", keyRef: "keyscribe.llm.c")
        let status = AIServiceStatus.derive(connection: connection, testState: .passed, hasKey: true)
        #expect(status.text == "Connection works")
    }
}
