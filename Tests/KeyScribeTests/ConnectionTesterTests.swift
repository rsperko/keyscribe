import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private struct FakeClient: LLMClient {
    let result: Result<String, Error>
    func complete(system: String, user: String, connection: Connection) async throws -> String {
        try result.get()
    }
}

// One-shot gate so a test can interleave state changes while a connection test is mid-flight.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }
    }
    func open() {
        lock.lock(); opened = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
}

private struct BlockingClient: LLMClient {
    let result: Result<String, Error>
    let gate: Gate
    func complete(system: String, user: String, connection: Connection) async throws -> String {
        await gate.wait()
        return try result.get()
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// Serialized: these tests share the global StubURLProtocol.handler, so they can't run concurrently.
@MainActor
@Suite(.serialized)
struct ConnectionTesterTests {
    private let connection = Connection(
        id: "c", name: "C", provider: .openai, model: "m", keyRef: "k")

    @Test func passesWhenClientReplies() async {
        let tester = ConnectionTester(client: FakeClient(result: .success("OK")))
        #expect(await tester.test(connection) == .passed)
    }

    @Test func failureCarriesTheProviderMessage() async {
        let tester = ConnectionTester(client: FakeClient(result: .failure(ProviderTransportError.http(401, body: nil))))
        #expect(await tester.test(connection) == .failed("The model service returned an error (401)."))
    }

    @Test func chatCompletions404ExplainsTheEndpointRequirement() async {
        let compat = Connection(
            id: "c", name: "C", provider: .openaiCompatible, model: "m", keyRef: "k",
            baseUrl: "http://127.0.0.1:11234/v1")
        let tester = ConnectionTester(client: FakeClient(result: .failure(ProviderTransportError.http(404, body: nil))))
        guard case .failed(let message) = await tester.test(compat) else {
            Issue.record("expected a 404 to be a failure")
            return
        }
        #expect(message.contains("Chat Completions API"))
        #expect(message.contains("/chat/completions"))
    }

    @Test func modelNotFound404PointsAtTheModelID() async {
        let compat = Connection(
            id: "c", name: "C", provider: .openaiCompatible, model: "bogus-model", keyRef: "k",
            baseUrl: "http://127.0.0.1:11234/v1")
        let body = #"{"error":{"message":"The model `bogus-model` does not exist","type":"invalid_request_error","param":null,"code":"model_not_found"}}"#
        let tester = ConnectionTester(client: FakeClient(result: .failure(ProviderTransportError.http(404, body: body))))
        guard case .failed(let message) = await tester.test(compat) else {
            Issue.record("expected a 404 to be a failure")
            return
        }
        #expect(message.contains("Model ID"))
        #expect(message.contains("bogus-model"))
        #expect(!message.contains("Base URL"))
    }

    @Test func nonChatCompletionsStatusKeepsTheGenericMessage() async {
        let compat = Connection(
            id: "c", name: "C", provider: .openaiCompatible, model: "m", keyRef: "k",
            baseUrl: "http://127.0.0.1:11234/v1")
        let tester = ConnectionTester(client: FakeClient(result: .failure(ProviderTransportError.http(500, body: nil))))
        #expect(await tester.test(compat) == .failed("The model service returned an error (500)."))
    }

    @Test func emptyReplyIsFailure() async {
        let tester = ConnectionTester(client: FakeClient(result: .success("   \n")))
        guard case .failed = await tester.test(connection) else {
            Issue.record("expected an empty reply to be a failure")
            return
        }
    }

    @Test func openAICompatibleConnectionCanTestWithoutAnAPIKey() async {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:11234/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = #"{"choices":[{"message":{"content":"OK"}}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = HTTPLLMClient(session: URLSession(configuration: config), keyProvider: { _ in .absent })
        let tester = ConnectionTester(client: client)
        let connection = Connection(
            id: "local", name: "Local", provider: .openaiCompatible,
            model: "qwen", keyRef: "k", baseUrl: "http://127.0.0.1:11234/v1")

        #expect(await tester.test(connection) == .passed)
    }

    @Test func openAICompatibleNoAuthDoesNotSendStoredKey() async {
        StubURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = #"{"choices":[{"message":{"content":"OK"}}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = HTTPLLMClient(session: URLSession(configuration: config), keyProvider: { _ in .found("stored-key") })
        let tester = ConnectionTester(client: client)
        let connection = Connection(
            id: "local", name: "Local", provider: .openaiCompatible,
            model: "qwen", keyRef: "k", baseUrl: "http://127.0.0.1:11234/v1",
            authMethod: Connection.AuthMethod.none)

        #expect(await tester.test(connection) == .passed)
    }

    @Test func openAICompatibleUsesTokenCommandAsBearerToken() async {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:11234/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
            let body = #"{"choices":[{"message":{"content":"OK"}}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = HTTPLLMClient(
            session: URLSession(configuration: config),
            keyProvider: { _ in .found("stale-token") },
            tokenCommandRunner: { command in
                #expect(command == "print-token")
                return "fresh-token\n"
            },
            tokenCache: TokenCommandCache())
        let tester = ConnectionTester(client: client)
        let connection = Connection(
            id: "local", name: "Local", provider: .openaiCompatible,
            model: "qwen", keyRef: "k", baseUrl: "http://127.0.0.1:11234/v1",
            tokenCommand: "print-token")

        #expect(await tester.test(connection) == .passed)
    }

    @Test func hostedProviderWithoutAKeyThrowsMissingKeyAndNeverHitsTheNetwork() async {
        StubURLProtocol.handler = { _ in
            Issue.record("hosted provider must not reach the network without a key")
            throw URLError(.badServerResponse)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = HTTPLLMClient(session: URLSession(configuration: config), keyProvider: { _ in .absent })
        let connection = Connection(
            id: "openai", name: "OpenAI", provider: .openai, model: "gpt-4o-mini", keyRef: "k")

        await #expect(throws: ProviderTransportError.self) {
            _ = try await client.complete(system: "s", user: "u", connection: connection)
        }
    }
}

@MainActor
struct AIServiceTestStateTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-ai-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Seeds and selects one connection (creation is now a draft flow, so these test-state tests seed a
    // connection directly instead of the old bare-insert create()).
    @discardableResult
    private func seedConnection(_ model: AIServiceSettingsModel, in dir: URL, id: String = "new-ai-service") -> Connection {
        let conn = Connection(
            id: id, name: "New AI Service", provider: .openai,
            model: "gpt-5.6-luna", keyRef: "keyscribe.llm.\(id)")
        let repo = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        try! repo.upsertConnection(conn)
        model.reload()
        model.selectedID = id
        return conn
    }

    @Test func recordsPassThenClearsItOnEdit() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AIServiceSettingsModel(
            repository: ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir)),
            tester: ConnectionTester(client: FakeClient(result: .success("OK"))))
        seedConnection(model, in: dir)
        let connection = model.selected!

        model.test(connection)
        await model.testTask?.value
        #expect(model.testState(for: connection.id) == .passed)

        model.update(connection, apiKey: nil)
        #expect(model.testState(for: connection.id) == nil)
    }

    @Test func aStaleVerdictLandingAfterAPostTestEditIsDiscarded() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        let model = AIServiceSettingsModel(
            repository: ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir)),
            tester: ConnectionTester(client: BlockingClient(
                result: .failure(ProviderTransportError.http(500, body: nil)), gate: gate)))
        seedConnection(model, in: dir)
        let connection = model.selected!

        model.test(connection)
        #expect(model.testState(for: connection.id) == .testing)
        model.update(connection, apiKey: nil)
        #expect(model.testState(for: connection.id) == nil)

        gate.open()
        await model.testTask?.value

        #expect(model.testState(for: connection.id) == nil)
        #expect(model.failedTestIds.isEmpty)
    }

    @Test func aStaleVerdictDoesNotAttachToANewConnectionReusingADeletedId() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        let model = AIServiceSettingsModel(
            repository: ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir)),
            tester: ConnectionTester(client: BlockingClient(
                result: .failure(ProviderTransportError.http(500, body: nil)), gate: gate)))
        seedConnection(model, in: dir)
        let deleted = model.selected!

        model.test(deleted)
        model.delete(deleted)
        // A fresh connection re-mints the freed id.
        seedConnection(model, in: dir)
        let recreated = model.selected!
        #expect(recreated.id == deleted.id)

        gate.open()
        await model.testTask?.value

        #expect(model.testState(for: recreated.id) == nil)
        #expect(model.failedTestIds.isEmpty)
    }

    @Test func dependentModeNamesListsOnlyModesWiredToTheConnection() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let model = AIServiceSettingsModel(
            repository: repository,
            tester: ConnectionTester(client: FakeClient(result: .success("OK"))))
        seedConnection(model, in: dir)
        let connection = model.selected!

        var email = Mode(id: "email", name: "Email")
        email.aiRewrite = .init(connection: connection.id, prompt: "rewrite")
        var polish = Mode(id: "polish", name: "Polish")
        polish.aiRewrite = .init(connection: connection.id, prompt: "rewrite")
        var plain = Mode(id: "plain", name: "Plain")
        plain.aiRewrite = .init(connection: "other", prompt: "rewrite")
        for mode in [email, polish, plain] { try? repository.writeMode(mode) }
        model.reload()

        let names = Set(model.dependentModeNames(of: connection))
        #expect(names == ["Email", "Polish"])
    }

    @Test func fetchingModelsStoresSuggestionsAndUpdatesBlankModel() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AIServiceSettingsModel(
            repository: ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir)),
            tester: ConnectionTester(client: FakeClient(result: .success("OK"))),
            listModels: { connection, apiKey in
                #expect(connection.provider == .openaiCompatible)
                #expect(connection.baseUrl == "http://127.0.0.1:11234/v1")
                #expect(apiKey == "secret")
                return ["qwen3", "llama"]
            })
        seedConnection(model, in: dir)
        var connection = model.selected!
        connection.provider = .openaiCompatible
        connection.model = ""
        connection.baseUrl = "http://127.0.0.1:11234/v1"
        model.update(connection, apiKey: nil)

        await model.fetchModels(for: connection, apiKey: "secret")
        let updated = model.selected!

        #expect(model.modelSuggestions(for: connection.id) == ["qwen3", "llama"])
        #expect(updated.model == "qwen3")
        #expect(model.modelDiscoveryState(for: connection.id) == .loaded)
    }

    @Test func fetchingModelsDoesNotClobberAnEditCommittedAfterTheSnapshot() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AIServiceSettingsModel(
            repository: ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir)),
            tester: ConnectionTester(client: FakeClient(result: .success("OK"))),
            listModels: { _, _ in ["qwen3"] })
        seedConnection(model, in: dir)
        var connection = model.selected!
        connection.provider = .openaiCompatible
        connection.model = ""
        connection.baseUrl = "http://old:11234/v1"
        model.update(connection, apiKey: nil)

        // Snapshot the connection, then simulate a focus-loss commit repointing the base URL before the
        // fetch saves. The fetched list belongs to the OLD endpoint, so the auto-select must not apply it
        // to the new one — the base-URL edit survives and the model is left for a re-fetch, not clobbered.
        let stale = model.selected!
        var edited = stale
        edited.baseUrl = "http://new:11234/v1"
        model.update(edited, apiKey: nil)

        await model.fetchModels(for: stale, apiKey: "secret")
        let saved = model.selected!

        #expect(saved.baseUrl == "http://new:11234/v1")
        #expect(saved.model == "")
    }
}
