import Foundation
import Testing
@testable import KeyScribeApp
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

private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
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
        AIConnectionDraft(
            name: "Gemini", provider: .gemini, model: "gemini-2.5-flash", baseURL: "",
            authMethod: .apiKey, apiKey: "secret", tokenCommand: "", wireAPI: .auto)
    }

    @Test func passingTestSavesTheConnection() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var savedRef: String?
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)), permits: { _ in true },
            saveAPIKey: { ref, _ in savedRef = ref; return true },
            deleteAPIKey: { _ in true },
            testConnection: { _, _ in .passed })

        let result = await connector.connect(draft: draft(), reusingId: nil)

        guard case .connected(let connection) = result.outcome else { Issue.record("expected connected"); return }
        #expect(connection.id == "gemini")
        #expect(savedRef == "keyscribe.llm.gemini")
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.map(\.id) == ["gemini"])
    }

    private func noAuthDraft() -> AIConnectionDraft {
        AIConnectionDraft(
            name: "Open Gateway", provider: .openaiCompatible, model: "standard-model",
            baseURL: "https://gateway.example.com/open/v1", authMethod: .none, apiKey: "", tokenCommand: "",
            wireAPI: .auto)
    }

    @Test func noAuthConnectionConnectsWithoutTouchingTheKeychain() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var keychainTouched = false
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)), permits: { _ in true },
            saveAPIKey: { _, _ in keychainTouched = true; return true },
            deleteAPIKey: { _ in keychainTouched = true; return true },
            testConnection: { _, _ in .passed })

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
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)), permits: { _ in true },
            saveAPIKey: { _, _ in keychainTouched = true; return true },
            deleteAPIKey: { _ in keychainTouched = true; return true },
            testConnection: { _, _ in .failed("503 Service Unavailable") })

        let result = await connector.connect(draft: noAuthDraft(), reusingId: nil)

        #expect(result.outcome == .failed("Connection test failed: 503 Service Unavailable"))
        #expect(!keychainTouched)
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.isEmpty)
    }

    @Test func aServiceTheCatalogRefusesIsNeverStoredTestedOrPersisted() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var keychainTouched = false
        var tested = false
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)), permits: { _ in false },
            saveAPIKey: { _, _ in keychainTouched = true; return true },
            deleteAPIKey: { _ in keychainTouched = true; return true },
            testConnection: { _, _ in tested = true; return .passed })

        let result = await connector.connect(draft: draft(), reusingId: nil)

        #expect(result.outcome == .failed("This AI service isn't available in this app."))
        #expect(!keychainTouched)
        #expect(!tested)
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.isEmpty)
    }

    private func connector(
        _ support: URL,
        save: @escaping (String, String) -> Bool = { _, _ in true },
        delete: @escaping (String) -> Bool = { _ in true },
        test: @escaping (Connection, String?) async -> ConnectionTestState = { _, _ in .passed }
    ) -> AIServiceConnector {
        AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)), permits: { _ in true },
            saveAPIKey: save, deleteAPIKey: delete, testConnection: test)
    }

    @Test func theTestUsesTheTypedKeyBeforeAnythingIsStored() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var events: [String] = []
        let connector = connector(
            support,
            save: { _, value in events.append("save \(value)"); return true },
            test: { _, key in events.append("test \(key ?? "nil")"); return .passed })

        _ = await connector.connect(draft: draft(), reusingId: nil)

        #expect(events == ["test secret", "save secret"])
    }

    @Test func aFailedTestNeverTouchesTheKeychain() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var keychainTouched = false
        let connector = connector(
            support,
            save: { _, _ in keychainTouched = true; return true },
            delete: { _ in keychainTouched = true; return true },
            test: { _, _ in .failed("401 Unauthorized") })

        let result = await connector.connect(draft: draft(), reusingId: "gemini")

        #expect(result.outcome == .failed("Connection test failed: 401 Unauthorized"))
        #expect(!keychainTouched)
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.isEmpty)
    }

    @Test func aKeyThatCannotBeSavedPersistsNothing() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let connector = connector(support, save: { _, _ in false })

        let result = await connector.connect(draft: draft(), reusingId: nil)

        #expect(result.outcome == .failed("Could not save the API key."))
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.isEmpty)
    }

    @Test func aNewServiceThatCannotBeSavedRemovesTheKeyItJustStored() async throws {
        let support = tempSupport()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
            try? FileManager.default.removeItem(at: support)
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path)
        var deleted: [String] = []
        let connector = connector(support, delete: { deleted.append($0); return true })

        let result = await connector.connect(draft: draft(), reusingId: nil)

        guard case .failed(let message) = result.outcome else { Issue.record("expected failed"); return }
        #expect(message.hasPrefix("Could not save the AI service"))
        #expect(deleted == ["keyscribe.llm.gemini"])
    }

    @Test func aStoredKeyThatCannotBeRemovedAfterAFailedSaveIsReported() async throws {
        let support = tempSupport()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
            try? FileManager.default.removeItem(at: support)
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path)
        let connector = connector(support, delete: { _ in false })

        let result = await connector.connect(draft: draft(), reusingId: nil)

        guard case .failed(let message) = result.outcome else { Issue.record("expected failed"); return }
        #expect(message.contains("Keychain"))
    }

    private func savedService(_ support: URL) throws -> Connection {
        let connection = draft().connection(id: "gemini", keyRef: "keyscribe.llm.gemini")
        try ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)).upsertConnection(connection)
        return connection
    }

    @Test func aPassingRetestOfASavedServiceStoresTheKeyUnderANewReferenceAndRetiresTheOld() async throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let saved = try savedService(support)
        var savedRefs: [String] = []
        var deletedRefs: [String] = []
        let connector = connector(
            support, save: { ref, _ in savedRefs.append(ref); return true },
            delete: { deletedRefs.append($0); return true })

        let result = await connector.connect(draft: draft(), reusingId: saved.id)

        guard case .connected(let connection) = result.outcome else { Issue.record("expected connected"); return }
        #expect(connection.keyRef != saved.keyRef)
        #expect(savedRefs == [connection.keyRef])
        #expect(deletedRefs == [saved.keyRef])
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.map(\.keyRef) == [connection.keyRef])
    }

    @Test func aPassingRetestWhoseServiceCannotBeSavedLeavesTheWorkingKeyAlone() async throws {
        let support = tempSupport()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
            try? FileManager.default.removeItem(at: support)
        }
        let saved = try savedService(support)
        var savedRefs: [String] = []
        var deletedRefs: [String] = []
        let connector = connector(
            support, save: { ref, _ in savedRefs.append(ref); return true },
            delete: { deletedRefs.append($0); return true })
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path)

        let result = await connector.connect(draft: draft(), reusingId: saved.id)

        guard case .failed = result.outcome else { Issue.record("expected failed"); return }
        #expect(savedRefs.count == 1)
        #expect(savedRefs.first != saved.keyRef)
        #expect(deletedRefs == savedRefs)
        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.map(\.keyRef) == [saved.keyRef])
    }

    @Test func emptyAPIKeyFailsBeforeSavingOrTesting() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var saved = false, tested = false
        var d = draft(); d.apiKey = "   "
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)), permits: { _ in true },
            saveAPIKey: { _, _ in saved = true; return true },
            deleteAPIKey: { _ in true },
            testConnection: { _, _ in tested = true; return .passed })

        let result = await connector.connect(draft: d, reusingId: nil)

        #expect(result.outcome == .failed("API key is required."))
        #expect(!saved)
        #expect(!tested)
    }

    @Test func reusingIdKeepsTheSameAllocationAcrossRetries() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let connector = AIServiceConnector(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)), permits: { _ in true },
            saveAPIKey: { _, _ in true }, deleteAPIKey: { _ in true },
            testConnection: { _, _ in .failed("nope") })

        let first = await connector.connect(draft: draft(), reusingId: nil)
        let second = await connector.connect(draft: draft(), reusingId: first.allocatedId)

        #expect(first.allocatedId == "gemini")
        #expect(second.allocatedId == "gemini")   // did not become gemini-2 despite the first failure
    }


    private func settingsModel(
        support: URL,
        permits: @escaping (Connection) -> Bool = { _ in true },
        testConnection: @escaping @Sendable (Connection) async -> ConnectionTestState = { _ in .passed },
        listModels: @escaping (Connection, String?) async throws -> [String] = { _, _ in [] }
    ) -> AIServiceSettingsModel {
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        return AIServiceSettingsModel(
            repository: repository, permits: permits,
            tester: ConnectionTester(client: StubLLMClient(testConnection: testConnection)),
            listModels: listModels,
            saveAPIKey: { _, _ in true }, deleteAPIKey: { _ in true })
    }

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

    @Test func addServicePreservesThePresetWireAPI() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = settingsModel(support: support)
        let preset = ConnectionPreset(
            id: "responses", name: "Responses", provider: .openaiCompatible,
            baseURL: "https://gateway.example/v1", defaultModel: "new-model", wireAPI: .responses)

        model.addService(preset: preset)

        let connection = try #require(ConnectionStore.loadOrDefault(supportDir: support).connections.first)
        #expect(connection.wireAPI == .responses)
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

    @Test func updateSavesTheKeyThroughTheInjectedSeam() {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        var saved: (ref: String, value: String)?
        let model = AIServiceSettingsModel(
            repository: repository, permits: { _ in true },
            tester: ConnectionTester(client: StubLLMClient(testConnection: { _ in .passed })),
            saveAPIKey: { ref, value in saved = (ref, value); return true },
            deleteAPIKey: { _ in true })
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
            repository: repository, permits: { _ in true },
            tester: ConnectionTester(client: StubLLMClient(testConnection: { _ in .passed })),
            saveAPIKey: { _, _ in true },
            deleteAPIKey: { deletedRef = $0; return true })
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

    private func readOnly(_ support: URL, _ body: () -> Void) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: support.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path) }
        body()
    }

    private func keyedModel(support: URL, deleted: @escaping (String) -> Bool) -> AIServiceSettingsModel {
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        return AIServiceSettingsModel(
            repository: repository, permits: { _ in true },
            tester: ConnectionTester(client: StubLLMClient(testConnection: { _ in .passed })),
            saveAPIKey: { _, _ in true }, deleteAPIKey: deleted)
    }

    @Test func anUpdateThatCannotBeSavedStoresNoKeyAndKeepsTheLastVerdict() async throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var savedKeys: [String] = []
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let model = AIServiceSettingsModel(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            permits: { _ in true },
            tester: ConnectionTester(client: StubLLMClient(testConnection: { _ in .passed })),
            saveAPIKey: { _, value in savedKeys.append(value); return true }, deleteAPIKey: { _ in true })
        model.addService(preset: starterPreset)
        let connection = try #require(model.selected)
        model.test(connection)
        await model.testTask?.value
        #expect(model.testState(for: connection.id) == .passed)
        var renamed = connection
        renamed.name = "Renamed"

        var updated = true
        readOnly(support) { updated = model.update(renamed, apiKey: "new-key") }

        #expect(!updated)
        #expect(savedKeys.isEmpty)
        #expect(model.testState(for: connection.id) == .passed)
        #expect(model.error != nil)
    }

    @Test func anUpdateWhoseKeyCannotBeSavedReportsFailure() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let model = AIServiceSettingsModel(
            repository: ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)),
            permits: { _ in true },
            tester: ConnectionTester(client: StubLLMClient(testConnection: { _ in .passed })),
            saveAPIKey: { _, _ in false }, deleteAPIKey: { _ in true })
        model.addService(preset: starterPreset)
        let connection = try #require(model.selected)

        #expect(!model.update(connection, apiKey: "new-key"))
        #expect(model.error != nil)
    }

    @Test func credentialBoundaryKeepsTheWorkingKeyWhenTheRotatedReferenceCannotBeSaved() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var deletedRefs: [String] = []
        let model = keyedModel(support: support) { deletedRefs.append($0); return true }
        model.addService(preset: starterPreset)
        let connection = try #require(model.selected)
        model.update(connection, apiKey: "working-key")
        var updated = connection
        updated.provider = .openai

        var crossed = true
        readOnly(support) { crossed = model.updateAcrossCredentialBoundary(updated) }

        #expect(!crossed)
        #expect(deletedRefs.isEmpty)
        #expect(model.hasKey(connection))
        #expect(model.error != nil)
        let stored = try #require(ConnectionStore.loadOrDefault(supportDir: support).connections.first)
        #expect(stored.keyRef == connection.keyRef)
    }

    @Test func credentialBoundaryRemovesTheOldKeyOnlyAfterTheRotatedReferenceIsSaved() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var storedRefAtDelete: String?
        let model = keyedModel(support: support) { _ in
            storedRefAtDelete = ConnectionStore.loadOrDefault(supportDir: support).connections.first?.keyRef
            return true
        }
        model.addService(preset: starterPreset)
        let connection = try #require(model.selected)
        var updated = connection
        updated.provider = .openai

        model.updateAcrossCredentialBoundary(updated)

        let rotated = try #require(model.selected?.keyRef)
        #expect(rotated != connection.keyRef)
        #expect(storedRefAtDelete == rotated)
        #expect(model.error == nil)
    }

    @Test func credentialBoundaryReportsAnOldKeyItCouldNotRemove() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = keyedModel(support: support) { _ in false }
        model.addService(preset: starterPreset)
        let connection = try #require(model.selected)
        var updated = connection
        updated.provider = .openai

        model.updateAcrossCredentialBoundary(updated)

        #expect(model.selected?.keyRef != connection.keyRef)
        #expect(model.error != nil)
    }

    @Test func deleteReportsAKeyItCouldNotRemove() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = keyedModel(support: support) { _ in false }
        model.addService(preset: starterPreset)
        let connection = try #require(model.selected)

        model.delete(connection)

        #expect(ConnectionStore.loadOrDefault(supportDir: support).connections.isEmpty)
        #expect(model.error != nil)
    }

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


    @Test func listRowAndSummaryDeriveIdenticalStatus() {
        let connection = Connection(
            id: "c", name: "C", provider: .gemini, model: "m", keyRef: "keyscribe.llm.c")
        let status = AIServiceStatus.derive(
            connection: connection, testState: .passed, hasKey: true, permits: { _ in true })
        #expect(status.text == "Connection works")
    }

    @Test func statusReadsNotAvailableForAServiceTheBuildRefusesEvenAfterAPassingTest() {
        let connection = Connection(
            id: "c", name: "C", provider: .gemini, model: "m", keyRef: "keyscribe.llm.c")
        let status = AIServiceStatus.derive(
            connection: connection, testState: .passed, hasKey: true, permits: { _ in false })
        #expect(status.text == "Not available in this app")
    }

    @Test func settingsNeverTestsAServiceTheBuildRefusesOrOffersItToModes() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let modes = support.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modes, withIntermediateDirectories: true)
        var pendingMode = Mode(id: "rewrite", name: "Rewrite")
        pendingMode.aiRewrite = .init(connection: "", prompt: "Rewrite")
        try? ModeStore.write(pendingMode, to: modes)
        let tested = CallFlag()
        let model = settingsModel(
            support: support, permits: { _ in false },
            testConnection: { _ in tested.raise(); return .passed })
        model.addService(preset: starterPreset)
        let connection = try! #require(model.selected)

        model.update(connection, apiKey: "key")
        model.test(connection)
        await model.testTask?.value

        #expect(!tested.isRaised)
        #expect(model.testState(for: connection.id) == nil)
        #expect(model.pendingConnectOffer == nil)
    }

    @Test func settingsNeverFetchesModelsForAServiceTheBuildRefuses() async {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var listed = false
        let model = settingsModel(
            support: support, permits: { _ in false },
            listModels: { _, _ in listed = true; return ["m"] })
        model.addService(preset: starterPreset)
        let connection = try! #require(model.selected)

        await model.fetchModels(for: connection, apiKey: "key")

        #expect(!listed)
        #expect(model.modelDiscoveryState(for: connection.id) == .failed("This AI service isn't available in this app."))
    }
}
