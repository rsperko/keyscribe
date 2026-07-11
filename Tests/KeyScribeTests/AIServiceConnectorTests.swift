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

    // MARK: showsForm predicate

    @Test func showsFormRulesAreDirectlyTestable() {
        #expect(AIServiceDetailForm.showsForm(configIssue: nil, testState: .passed, isEditing: false) == false)
        #expect(AIServiceDetailForm.showsForm(configIssue: nil, testState: nil, isEditing: false) == false)
        #expect(AIServiceDetailForm.showsForm(configIssue: nil, testState: .passed, isEditing: true) == true)
        #expect(AIServiceDetailForm.showsForm(configIssue: .missingModel, testState: .passed, isEditing: false) == true)
        #expect(AIServiceDetailForm.showsForm(configIssue: nil, testState: .failed("x"), isEditing: false) == true)
    }

    // MARK: Settings draft flow (delegates to the connector)

    private func settingsModel(
        testConnection: @escaping @Sendable (Connection) async -> ConnectionTestState,
        support: URL
    ) -> AIServiceSettingsModel {
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        return AIServiceSettingsModel(
            repository: repository,
            tester: ConnectionTester(client: StubLLMClient(testConnection: testConnection)),
            saveAPIKey: { _, _ in true }, deleteAPIKey: { _ in })
    }

    @Test func abandoningTheDraftPersistsNothing() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(testConnection: { _ in .passed }, support: support)

        model.beginCreate()
        model.createDraft.name = "Half"
        model.cancelCreate()

        #expect(model.isCreatingDraft == false)
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.isEmpty)
    }

    @Test func aPassingDraftConnectSelectsTheServiceAndLeavesTheForm() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(testConnection: { _ in .passed }, support: support)

        model.beginCreate()
        model.createDraft.name = "Gemini"
        model.createDraft.provider = .gemini
        model.createDraft.model = "gemini-2.5-flash"
        model.createDraft.apiKey = "secret"
        model.connectDraft()
        await model.createTask?.value

        #expect(model.isCreatingDraft == false)
        #expect(model.selectedID == "gemini")
        #expect(model.testState(for: "gemini") == .passed)
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.map(\.id) == ["gemini"])
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
