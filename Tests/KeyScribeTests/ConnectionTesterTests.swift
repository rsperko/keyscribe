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

@MainActor
struct ConnectionTesterTests {
    private let connection = Connection(
        id: "c", name: "C", provider: .openai, model: "m", keyRef: "k")

    @Test func passesWhenClientReplies() async {
        let tester = ConnectionTester(client: FakeClient(result: .success("OK")))
        #expect(await tester.test(connection) == .passed)
    }

    @Test func failureCarriesTheProviderMessage() async {
        let tester = ConnectionTester(client: FakeClient(result: .failure(LLMClientError.http(401, "nope"))))
        #expect(await tester.test(connection) == .failed("The model service returned an error (401)."))
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
        let client = HTTPLLMClient(session: URLSession(configuration: config), keyProvider: { _ in nil })
        let tester = ConnectionTester(client: client)
        let connection = Connection(
            id: "local", name: "Local", provider: .openaiCompatible,
            model: "qwen", keyRef: "k", baseUrl: "http://127.0.0.1:11234/v1")

        #expect(await tester.test(connection) == .passed)
    }

    @Test func hostedProviderWithoutAKeyThrowsMissingKeyAndNeverHitsTheNetwork() async {
        StubURLProtocol.handler = { _ in
            Issue.record("hosted provider must not reach the network without a key")
            throw URLError(.badServerResponse)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = HTTPLLMClient(session: URLSession(configuration: config), keyProvider: { _ in nil })
        let connection = Connection(
            id: "openai", name: "OpenAI", provider: .openai, model: "gpt-4o-mini", keyRef: "k")

        await #expect(throws: LLMClientError.self) {
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

    @Test func recordsPassThenClearsItOnEdit() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AIServiceSettingsModel(
            supportDir: dir, tester: ConnectionTester(client: FakeClient(result: .success("OK"))))
        model.create()
        let connection = model.selected!

        model.test(connection)
        await model.testTask?.value
        #expect(model.testState(for: connection.id) == .passed)

        model.update(connection, apiKey: nil)
        #expect(model.testState(for: connection.id) == nil)
    }

    @Test func fetchingModelsStoresSuggestionsAndUpdatesBlankModel() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AIServiceSettingsModel(
            supportDir: dir,
            tester: ConnectionTester(client: FakeClient(result: .success("OK"))),
            listModels: { connection, apiKey in
                #expect(connection.provider == .openaiCompatible)
                #expect(connection.baseUrl == "http://127.0.0.1:11234/v1")
                #expect(apiKey == "secret")
                return ["qwen3", "llama"]
            })
        model.create()
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
            supportDir: dir,
            tester: ConnectionTester(client: FakeClient(result: .success("OK"))),
            listModels: { _, _ in ["qwen3"] })
        model.create()
        var connection = model.selected!
        connection.provider = .openaiCompatible
        connection.model = ""
        connection.baseUrl = "http://old:11234/v1"
        model.update(connection, apiKey: nil)

        // Snapshot the connection, then simulate a focus-loss commit landing before the fetch saves.
        let stale = model.selected!
        var edited = stale
        edited.baseUrl = "http://new:11234/v1"
        model.update(edited, apiKey: nil)

        await model.fetchModels(for: stale, apiKey: "secret")
        let saved = model.selected!

        #expect(saved.baseUrl == "http://new:11234/v1")
        #expect(saved.model == "qwen3")
    }
}
