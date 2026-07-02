import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

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

@Suite(.serialized)
@MainActor
struct ModelDiscoveryTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func openAICompatibleListsModelIdsFromBaseURL() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:11234/v1/models")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-key")
            let body = #"{"object":"list","data":[{"id":"qwen"},{"id":"llama"}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in "local-key" })
        let connection = Connection(
            id: "local", name: "Local", provider: .openaiCompatible,
            model: "", keyRef: "k", baseUrl: "http://127.0.0.1:11234/v1")

        let models = try await lister.listModels(for: connection, apiKey: nil)

        #expect(models == ["qwen", "llama"])
    }

    @Test func openAICompatibleModelListUsesTokenCommand() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:11234/v1/models")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
            let body = #"{"object":"list","data":[{"id":"qwen"}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let lister = HTTPModelLister(
            session: session(),
            keyProvider: { _ in "stale-token" },
            tokenCommandRunner: { command in
                #expect(command == "print-token")
                return #"{"access_token":"fresh-token"}"#
            },
            tokenCache: TokenCommandCache())
        let connection = Connection(
            id: "local", name: "Local", provider: .openaiCompatible,
            model: "", keyRef: "k", baseUrl: "http://127.0.0.1:11234/v1",
            tokenCommand: "print-token")

        let models = try await lister.listModels(for: connection, apiKey: nil)

        #expect(models == ["qwen"])
    }

    @Test func geminiListsOnlyGenerateContentModelsByBaseModelId() async throws {
        StubURLProtocol.handler = { request in
            // The Gemini key now travels in the x-goog-api-key header, not the URL query string.
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-key")
            let body = """
            {
              "models": [
                {"name": "models/gemini-2.5-flash-001", "baseModelId": "gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]},
                {"name": "models/embedding-001", "baseModelId": "embedding-001", "supportedGenerationMethods": ["embedContent"]}
              ]
            }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in "gemini-key" })
        let connection = Connection(
            id: "gemini", name: "Gemini", provider: .gemini,
            model: "", keyRef: "k")

        let models = try await lister.listModels(for: connection, apiKey: nil)

        #expect(models == ["gemini-2.5-flash"])
    }

    @Test func geminiDedupesVersionedModelsSharingABaseModelId() async throws {
        StubURLProtocol.handler = { request in
            let body = """
            {
              "models": [
                {"name": "models/gemini-2.5-flash-001", "baseModelId": "gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]},
                {"name": "models/gemini-2.5-flash-002", "baseModelId": "gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]},
                {"name": "models/gemini-2.5-pro", "baseModelId": "gemini-2.5-pro", "supportedGenerationMethods": ["generateContent"]}
              ]
            }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in "gemini-key" })
        let connection = Connection(
            id: "gemini", name: "Gemini", provider: .gemini, model: "", keyRef: "k")

        let models = try await lister.listModels(for: connection, apiKey: nil)

        #expect(models == ["gemini-2.5-flash", "gemini-2.5-pro"])
    }
}
