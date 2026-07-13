import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// One-shot coordination across the connect Task and the test body.
private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if fired { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }
    }
    func fire() {
        lock.lock(); fired = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
}

@MainActor
struct FirstRunAISetupTests {
    private func makeModel(
        supportDir: URL,
        modesDir: URL,
        saveAPIKey: @escaping (String, String) -> Bool = { _, _ in true },
        deleteAPIKey: @escaping (String) -> Void = { _ in },
        readAPIKey: @escaping (String) -> String? = { _ in nil },
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
            deleteAPIKey: deleteAPIKey,
            readAPIKey: readAPIKey,
            testConnection: testConnection,
            listModels: listModels,
            onComplete: onComplete)
    }

    // P2-21: the permission relaunch used to drop the user into the permissions-only flow, whose Done
    // ended onboarding early. Resuming lands on the trial, whose modifier tap the relaunch revives.
    @Test func resumeOnboardingStartsAtTheTrialStep() {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = FirstRunModel(
            initialEngineId: SpeechModelCatalog.defaultEnglishId,
            download: { _, _ in }, selectEngine: { _ in }, resumeOnboarding: true,
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: {})
        #expect(model.step == .tryIt)
    }

    @Test func permissionsOnlyStillStartsAtThePermissionsStep() {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-permsonly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = FirstRunModel(
            initialEngineId: SpeechModelCatalog.defaultEnglishId,
            download: { _, _ in }, selectEngine: { _ in }, permissionsOnly: true,
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: {})
        #expect(model.step == .permissions)
        model.stopPolling()
    }

    @Test func creatingAIServiceConnectsAndEnablesLaunchRewriteModes() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: modesDir)
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

    // A headline starter already wired to a live connection and deliberately turned OFF must be left exactly
    // as the user has it — connecting a new service must not re-enable it or repoint it. An unlinked headline
    // is still wired up as usual.
    @Test func connectingLeavesADeliberatelyDisabledLinkedHeadlineAlone() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: modesDir)

        let repository = ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir))
        try repository.upsertConnection(
            Connection(id: "existing", name: "Existing", provider: .gemini, model: "m", keyRef: "keyscribe.llm.existing"))
        var polish = try #require(ModeStore.loadAll(in: modesDir).first { $0.id == "polish" })
        polish.aiRewrite?.connection = "existing"
        polish.enabled = false
        try ModeStore.write(polish, to: modesDir)

        let model = makeModel(supportDir: supportDir, modesDir: modesDir)
        model.aiServiceName = "Gemini Flash"
        model.aiProvider = .gemini
        model.aiModel = "gemini-2.5-flash"
        model.aiAPIKey = "secret"
        await model.createAIService()

        let newConnection = try #require(
            ConnectionStore.loadOrDefault(supportDir: supportDir).connections.first { $0.id != "existing" })
        let modes = ModeStore.loadAll(in: modesDir)
        let polishAfter = try #require(modes.first { $0.id == "polish" })
        #expect(!polishAfter.enabled)                                   // deliberate disable respected
        #expect(polishAfter.aiRewrite?.connection == "existing")        // not repointed to the new service
        let editSelection = try #require(modes.first { $0.id == "edit-selection" })
        #expect(editSelection.enabled)                                  // the unlinked headline is still wired
        #expect(editSelection.aiRewrite?.connection == newConnection.id)
    }

    // Fresh install (templates-only: no starter files, just _direct.toml): connecting the first service
    // materializes the two headline modes as enabled seeds wired to the new connection, and touches no other
    // starter. Their seed identity survives so the playground and future seed updates keep finding them.
    @Test func connectingOnAFreshProfileMaterializesHeadlineModesAsSeeds() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.ensureSystemModes(in: modesDir)
        let model = makeModel(supportDir: supportDir, modesDir: modesDir)

        model.aiServiceName = "Local"
        model.aiProvider = .gemini
        model.aiModel = "gemini-2.5-flash"
        model.aiAPIKey = "secret"
        await model.createAIService()

        let connection = try #require(ConnectionStore.loadOrDefault(supportDir: supportDir).connections.first)
        let modes = ModeStore.loadAll(in: modesDir)
        let headline = modes.filter { ["polish", "edit-selection"].contains($0.id) }
        #expect(headline.count == 2)
        #expect(headline.allSatisfy { $0.enabled })
        #expect(headline.allSatisfy { $0.seedId == $0.id })
        #expect(headline.allSatisfy { $0.aiRewrite?.connection == connection.id })
        #expect(modes.filter { ["message", "email", "code", "markdown", "shell", "ai-prompt"].contains($0.id) }.isEmpty)
        #expect(model.step == .playground)
        let ledger = ModeStore.loadLedger(in: supportDir.appendingPathComponent("lkg", isDirectory: true))
        #expect(ledger?.entry("polish")?.fingerprint != nil)
        #expect(ledger?.entry("edit-selection")?.fingerprint != nil)
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
        ModeStore.seedStarterFilesForTesting(in: modesDir)
        var completed = 0
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            saveAPIKey: { _, _ in false },
            onComplete: { completed += 1 })

        model.aiAPIKey = "secret"
        await model.createAIService()

        #expect(completed == 0)
        #expect(model.aiSetupError == "Could not save the API key.")
        #expect(ConnectionStore.loadOrDefault(supportDir: supportDir).connections.isEmpty)
        let modes = ModeStore.loadAll(in: modesDir)
        #expect(modes.filter { $0.seedId != nil && $0.aiRewrite != nil }.allSatisfy { $0.aiRewrite?.connection == "" })
    }

    @Test func emptyAPIKeyDoesNotSaveOrTestConnection() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: modesDir)
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

    @Test func choosingOpenAICompatibleKeepsAPIKeyAsDefaultCredential() {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = makeModel(
            supportDir: supportDir,
            modesDir: supportDir.appendingPathComponent("modes", isDirectory: true))

        model.aiProvider = .openai
        model.aiAuthMethod = .apiKey
        model.aiAPIKey = ""
        model.aiDraft.applyPreset(.custom, updateDefaultName: true)

        #expect(model.aiProvider == .openaiCompatible)
        #expect(model.aiAuthMethod == .apiKey)
    }

    @Test func closingTheWizardMidTestDoesNotConnectOrEnableModes() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: modesDir)

        let started = Signal(), release = Signal()
        var completed = 0
        var deletedKeyRef: String?
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            deleteAPIKey: { deletedKeyRef = $0 },
            testConnection: { _ in started.fire(); await release.wait(); return .passed },
            onComplete: { completed += 1 })

        model.aiServiceName = "Gemini"
        model.aiProvider = .gemini
        model.aiModel = "gemini-2.5-flash"
        model.aiAPIKey = "secret"

        model.connect()
        await started.wait()      // the connection test is in flight; the key is already saved
        let task = model.setupTask  // capture before stopPolling nils it
        model.stopPolling()       // user closes the wizard → connect task cancelled
        release.fire()            // the test returns .passed after the cancel
        await task?.value

        #expect(completed == 0)
        #expect(model.step != .playground)
        #expect(deletedKeyRef == "keyscribe.llm.gemini")
        #expect(ConnectionStore.loadOrDefault(supportDir: supportDir).connections.isEmpty)
        let modes = ModeStore.loadAll(in: modesDir)
        #expect(modes.filter { $0.seedId != nil && $0.aiRewrite != nil }.allSatisfy { $0.aiRewrite?.connection == "" })
    }

    @Test func failedConnectionTestDoesNotPersistOrFinish() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: modesDir)
        var completed = 0
        var deletedKeyRef: String?
        let model = makeModel(
            supportDir: supportDir,
            modesDir: modesDir,
            deleteAPIKey: { deletedKeyRef = $0 },
            testConnection: { _ in .failed("401 Unauthorized") },
            onComplete: { completed += 1 })

        model.aiServiceName = "Gemini"
        model.aiProvider = .gemini
        model.aiModel = "gemini-2.5-flash"
        model.aiAPIKey = "bad-key"
        await model.createAIService()

        #expect(completed == 0)
        #expect(model.aiSetupError == "Connection test failed: 401 Unauthorized")
        #expect(deletedKeyRef == "keyscribe.llm.gemini")
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

        #expect(model.aiDraft.availableModels == ["qwen3", "llama"])
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

        #expect(model.aiDraft.availableModels == ["qwen3"])
        #expect(model.aiModel == "qwen3")
        #expect(model.aiModelDiscoveryError == nil)
    }

    @Test func creatingOpenAICompatibleNoAuthDoesNotSaveKey() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: modesDir)
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
        ModeStore.seedStarterFilesForTesting(in: modesDir)
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
        ModeStore.seedStarterFilesForTesting(in: modesDir)
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

    @Test func closingTheWizardMidDownloadDoesNotSwitchEngineOrAdvance() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-ai-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let started = Signal()
        let release = Signal()
        var selected: String?
        let model = FirstRunModel(
            initialEngineId: SpeechModelCatalog.defaultEnglishId,
            download: { _, _ in started.fire(); await release.wait() },
            selectEngine: { selected = $0 },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: {})

        model.beginDownload()
        let task = model.downloadTask
        await started.wait()
        model.stopPolling()
        release.fire()
        await task?.value

        #expect(selected == nil)
        #expect(model.step != .permissions)
        #expect(model.downloading == false)
    }
}
