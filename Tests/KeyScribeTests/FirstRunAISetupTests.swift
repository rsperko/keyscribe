import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct FirstRunAISetupTests {
    private func makeModel(
        supportDir: URL,
        modesDir: URL,
        saveAPIKey: @escaping (String, String) -> Bool = { _, _ in true },
        testConnection: @escaping (Connection) async -> ConnectionTestState = { _ in .passed },
        listModels: @escaping (Connection, String?) async throws -> [String] = { _, _ in [] },
        onComplete: @escaping () -> Void = {}
    ) -> FirstRunModel {
        FirstRunModel(
            initialEngineId: SpeechModelCatalog.defaultEnglishId,
            download: { _, _ in },
            selectEngine: { _ in },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            saveAPIKey: saveAPIKey,
            testConnection: testConnection,
            listModels: listModels,
            onComplete: onComplete)
    }

    @Test func creatingAIServiceConnectsAndEnablesLaunchRewriteModes() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: modesDir)
        var custom = Mode(id: "custom", name: "Custom")
        custom.aiRewrite = .init(connection: "", prompt: "Custom prompt")
        try ModeStore.write(custom, to: modesDir)
        var completed = 0
        var savedKeyRef: String?
        var savedKey: String?
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            saveAPIKey: { ref, key in
                savedKeyRef = ref
                savedKey = key
                return true
            },
            onComplete: { completed += 1 })

        model.aiServiceName = "Gemini Flash"
        model.aiProvider = .gemini
        model.aiModel = "gemini-2.5-flash"
        model.aiAPIKey = "secret"
        await model.createAIService()

        let connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        let connection = try #require(connections.first)
        #expect(connection.id == "gemini-flash")
        #expect(connection.provider == .gemini)
        #expect(connection.model == "gemini-2.5-flash")
        #expect(savedKeyRef == connection.keyRef)
        #expect(savedKey == "secret")
        #expect(completed == 0)
        #expect(model.step == .playground)

        let modes = ModeStore.loadAll(in: modesDir)
        let connected = modes.filter { ["polish", "edit-selection"].contains($0.id) }
        #expect(connected.count == 2)
        #expect(connected.allSatisfy { $0.enabled })
        #expect(connected.allSatisfy { $0.aiRewrite?.connection == connection.id })
        let examples = modes.filter { ["message", "email", "ai-prompt", "code", "markdown", "shell"].contains($0.id) }
        #expect(examples.count == 6)
        #expect(examples.allSatisfy { !$0.enabled })
        #expect(examples.allSatisfy { $0.aiRewrite?.connection == "" })
        #expect(try #require(modes.first { $0.id == "custom" }).aiRewrite?.connection == "")
    }

    @Test func skippingModelDownloadSelectsAppleSpeechAndContinuesSetup() {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var selected: String?
        var completed = 0
        let model = FirstRunModel(
            initialEngineId: SpeechModelCatalog.defaultEnglishId,
            download: { _, _ in },
            selectEngine: { selected = $0 },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: { completed += 1 })

        model.skipModelDownload()

        #expect(selected == "apple")
        #expect(model.step == .permissions)
        #expect(completed == 0)
    }

    @Test func failedKeySaveDoesNotConnectModesOrFinish() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: modesDir)
        var completed = 0
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            saveAPIKey: { _, _ in false },
            onComplete: { completed += 1 })

        model.aiAPIKey = "secret"
        await model.createAIService()

        #expect(completed == 0)
        #expect(model.aiSetupError == "Could not save the API key to the Keychain.")
        #expect(ConnectionStore.loadOrDefault(supportDir: supportDir).connections.isEmpty)
        let modes = ModeStore.loadAll(in: modesDir)
        #expect(modes.filter { $0.seedId != nil && $0.aiRewrite != nil }.allSatisfy { $0.aiRewrite?.connection == "" })
    }

    @Test func emptyAPIKeyDoesNotSaveOrTestConnection() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: modesDir)
        var saveCalled = false
        var testCalled = false
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            saveAPIKey: { _, _ in saveCalled = true; return true },
            testConnection: { _ in testCalled = true; return .passed })

        model.aiProvider = .openai
        model.aiAuthMethod = .apiKey
        model.aiModel = "gpt-5.4-mini"
        model.aiAPIKey = "   "
        await model.createAIService()

        #expect(model.aiSetupError == "API key is required.")
        #expect(saveCalled == false)
        #expect(testCalled == false)
        #expect(ConnectionStore.loadOrDefault(supportDir: supportDir).connections.isEmpty)
    }

    @Test func failedConnectionTestDoesNotPersistOrFinish() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: modesDir)
        var completed = 0
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            testConnection: { _ in .failed("401 Unauthorized") },
            onComplete: { completed += 1 })

        model.aiProvider = .gemini
        model.aiModel = "gemini-2.5-flash"
        model.aiAPIKey = "bad-key"
        await model.createAIService()

        #expect(completed == 0)
        #expect(model.aiSetupError == "Connection test failed: 401 Unauthorized")
        #expect(ConnectionStore.loadOrDefault(supportDir: supportDir).connections.isEmpty)
        let modes = ModeStore.loadAll(in: modesDir)
        #expect(modes.filter { $0.seedId != nil && $0.aiRewrite != nil }.allSatisfy { $0.aiRewrite?.connection == "" })
    }

    @Test func fetchingModelsSelectsFirstDiscoveredModelWhenCurrentModelIsBlank() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            listModels: { connection, apiKey in
                #expect(connection.provider == .openaiCompatible)
                #expect(connection.baseUrl == "http://127.0.0.1:11234/v1")
                #expect(apiKey == "secret")
                return ["qwen3", "llama"]
            })

        model.aiProvider = .openaiCompatible
        model.aiModel = ""
        model.aiBaseURL = "http://127.0.0.1:11234/v1"
        model.aiAPIKey = "secret"
        await model.fetchAIModels()

        #expect(model.aiAvailableModels == ["qwen3", "llama"])
        #expect(model.aiModel == "qwen3")
        #expect(model.aiModelDiscoveryError == nil)
    }

    @Test func fetchingModelsCanUseOpenAICompatibleNoAuth() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            listModels: { connection, apiKey in
                #expect(connection.provider == .openaiCompatible)
                #expect(connection.authMethod == .none)
                #expect(connection.baseUrl == "http://127.0.0.1:11234/v1")
                #expect(apiKey == nil)
                return ["qwen3"]
            })

        model.aiProvider = .openaiCompatible
        model.aiAuthMethod = .none
        model.aiModel = ""
        model.aiBaseURL = "http://127.0.0.1:11234/v1"
        await model.fetchAIModels()

        #expect(model.aiAvailableModels == ["qwen3"])
        #expect(model.aiModel == "qwen3")
        #expect(model.aiModelDiscoveryError == nil)
    }

    @Test func creatingOpenAICompatibleNoAuthDoesNotSaveKey() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: modesDir)
        var saveCalled = false
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            saveAPIKey: { _, _ in saveCalled = true; return false },
            testConnection: { connection in
                #expect(connection.authMethod == .none)
                #expect(connection.baseUrl == "http://127.0.0.1:11234/v1")
                return .passed
            })

        model.aiServiceName = "Local oMLX"
        model.aiProvider = .openaiCompatible
        model.aiAuthMethod = .none
        model.aiModel = "qwen3"
        model.aiBaseURL = "http://127.0.0.1:11234/v1"
        model.aiAPIKey = "ignored"
        await model.createAIService()

        let connection = try #require(ConnectionStore.loadOrDefault(supportDir: supportDir).connections.first)
        #expect(connection.authMethod == .none)
        #expect(connection.tokenCommand == nil)
        #expect(saveCalled == false)
        #expect(model.step == .playground)
    }

    @Test func creatingOpenAICompatibleTokenCommandPersistsCommandWithoutSavingKey() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: modesDir)
        var saveCalled = false
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            saveAPIKey: { _, _ in saveCalled = true; return false },
            testConnection: { connection in
                #expect(connection.authMethod == .tokenCommand)
                #expect(connection.tokenCommand == "print-token")
                return .passed
            })

        model.aiServiceName = "Token Proxy"
        model.aiProvider = .openaiCompatible
        model.aiAuthMethod = .tokenCommand
        model.aiTokenCommand = "print-token"
        model.aiModel = "qwen3"
        model.aiBaseURL = "http://127.0.0.1:11234/v1"
        await model.createAIService()

        let connection = try #require(ConnectionStore.loadOrDefault(supportDir: supportDir).connections.first)
        #expect(connection.authMethod == .tokenCommand)
        #expect(connection.tokenCommand == "print-token")
        #expect(saveCalled == false)
        #expect(model.step == .playground)
    }

    @Test func creatingHostedProviderTokenCommandPersistsCommandWithoutSavingKey() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: modesDir)
        var saveCalled = false
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            saveAPIKey: { _, _ in saveCalled = true; return false },
            testConnection: { connection in
                #expect(connection.provider == .openai)
                #expect(connection.authMethod == .tokenCommand)
                #expect(connection.tokenCommand == "print-token")
                return .passed
            })

        model.aiServiceName = "OpenAI Proxy"
        model.aiProvider = .openai
        model.aiAuthMethod = .tokenCommand
        model.aiTokenCommand = "print-token"
        model.aiModel = "gpt-5.4-mini"
        model.aiAPIKey = "ignored"
        await model.createAIService()

        let connection = try #require(ConnectionStore.loadOrDefault(supportDir: supportDir).connections.first)
        #expect(connection.authMethod == .tokenCommand)
        #expect(connection.tokenCommand == "print-token")
        #expect(saveCalled == false)
        #expect(model.step == .playground)
    }
}
