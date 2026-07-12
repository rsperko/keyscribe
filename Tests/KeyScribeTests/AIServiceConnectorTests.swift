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
            testConnection: { _ in .passed })

        let result = await connector.connect(draft: draft(), reusingId: nil)

        guard case .connected(let connection) = result.outcome else { Issue.record("expected connected"); return }
        #expect(connection.id == "gemini")
        #expect(savedRef == "keyscribe.llm.gemini")
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.map(\.id) == ["gemini"])
    }

    @Test func failedTestRollsBackTheKeyAndPersistsNothing() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var deletedRef: String?
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            saveAPIKey: { _, _ in true },
            deleteAPIKey: { deletedRef = $0 },
            testConnection: { _ in .failed("401 Unauthorized") })

        let result = await connector.connect(draft: draft(), reusingId: nil)

        #expect(result.outcome == .failed("Connection test failed: 401 Unauthorized"))
        #expect(deletedRef == "keyscribe.llm.gemini")
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.isEmpty)
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

    // Add Service persists a seeded connection immediately and selects it — no test, no key. It lands in an
    // honest "no key" config state (not usable until the user finishes it in the editor and Tests it).
    @Test func addServicePersistsASeededConnectionAndSelectsIt() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)

        model.addService(preset: .gemini)

        let saved = ConnectionStore.loadOrDefault(supportDir: support).connections
        #expect(saved.count == 1)
        let connection = try! #require(saved.first)
        #expect(connection.provider == .gemini)
        #expect(connection.model == ConnectionPreset.gemini.defaultModel)
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
        model.addService(preset: .gemini)
        let connection = try! #require(model.selected)

        model.update(connection, apiKey: "key")
        model.test(connection)
        await model.testTask?.value

        #expect(model.pendingConnectOffer?.connectionId == connection.id)
    }

    @Test func credentialBoundaryMintsAKeyReference() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)
        model.addService(preset: .gemini)
        let connection = try! #require(model.selected)
        var updated = connection
        updated.provider = .openai

        model.updateAcrossCredentialBoundary(updated)

        #expect(model.selected?.keyRef != connection.keyRef)
    }

    // A provider starter is reusable: adding a second connection for the same provider disambiguates the name
    // rather than overwriting the first.
    @Test func addingASecondServiceForAProviderKeepsBothWithDistinctNames() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)

        model.addService(preset: .gemini)
        model.addService(preset: .gemini)

        let saved = ConnectionStore.loadOrDefault(supportDir: support).connections
        #expect(saved.count == 2)
        #expect(Set(saved.map(\.name)).count == 2)   // uniqued, not two identical "Gemini" rows
    }

    // The Catalog row label switches from "Connect to X" to "Connect another X service" once a connection for
    // that provider exists — so a saved service named after its provider cannot be confused with the starter.
    @Test func presetRowLabelBecomesConnectAnotherOnceProviderExists() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)

        #expect(model.presetRows.first { $0.preset.id == "gemini" }?.label == "Connect to Gemini")

        model.addService(preset: .gemini)

        #expect(model.presetRows.first { $0.preset.id == "gemini" }?.label == "Connect another Gemini service")
    }

    // MARK: shared status vocabulary

    @Test func listRowAndSummaryDeriveIdenticalStatus() {
        let connection = Connection(
            id: "c", name: "C", provider: .gemini, model: "m", keyRef: "keyscribe.llm.c")
        let a = AIServiceStatus.derive(connection: connection, testState: .passed, hasKey: true)
        let b = AIServiceStatus.derive(connection: connection, testState: .passed, hasKey: true)
        #expect(a.text == b.text)
        #expect(a.text == "Connection works")
        #expect(a.icon == b.icon)
    }
}
