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
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in .found("local-key") })
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
            keyProvider: { _ in .found("stale-token") },
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

    @Test func openAICompatibleNoAuthSendsNoAuthorizationHeader() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://gateway.example.com/open/v1/models")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = #"{"object":"list","data":[{"id":"standard-model"}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in .found("stored-key") })
        let connection = Connection(
            id: "open", name: "Open Gateway", provider: .openaiCompatible,
            model: "", keyRef: "k", baseUrl: "https://gateway.example.com/open/v1",
            authMethod: Connection.AuthMethod.none)

        let models = try await lister.listModels(for: connection, apiKey: nil)

        #expect(models == ["standard-model"])
    }

    @Test func geminiListsOnlyGenerateContentModelsByBaseModelId() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")
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
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in .found("gemini-key") })
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
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in .found("gemini-key") })
        let connection = Connection(
            id: "gemini", name: "Gemini", provider: .gemini, model: "", keyRef: "k")

        let models = try await lister.listModels(for: connection, apiKey: nil)

        #expect(models == ["gemini-2.5-flash", "gemini-2.5-pro"])
    }

    @Test func anthropicRequestsTheFullModelListInOnePage() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            let body = """
            {"data": [{"id": "claude-opus-4-6"}, {"id": "claude-sonnet-4-6"}]}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in .found("anthropic-key") })
        let connection = Connection(
            id: "anthropic", name: "Anthropic", provider: .anthropic, model: "", keyRef: "k")

        let models = try await lister.listModels(for: connection, apiKey: nil)

        #expect(models == ["claude-opus-4-6", "claude-sonnet-4-6"])
    }

    @Test func anthropicWalksPagesUntilHasMoreIsFalse() async throws {
        nonisolated(unsafe) var requestedURLs: [String] = []
        StubURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            requestedURLs.append(url)
            let body: String
            if url.contains("after_id") {
                #expect(url == "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-2")
                body = #"{"data": [{"id": "claude-3"}], "has_more": false}"#
            } else {
                body = #"{"data": [{"id": "claude-1"}, {"id": "claude-2"}], "has_more": true, "last_id": "claude-2"}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in .found("anthropic-key") })
        let connection = Connection(
            id: "anthropic", name: "Anthropic", provider: .anthropic, model: "", keyRef: "k")

        let models = try await lister.listModels(for: connection, apiKey: nil)

        #expect(models == ["claude-1", "claude-2", "claude-3"])
        #expect(requestedURLs.count == 2)
    }

    @Test func geminiWalksPagesUntilNextPageTokenIsAbsent() async throws {
        nonisolated(unsafe) var requestedURLs: [String] = []
        StubURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            requestedURLs.append(url)
            let body: String
            if url.contains("pageToken") {
                #expect(url == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&pageToken=abc/%3D%3D")
                body = """
                {"models": [{"name": "models/gemini-2.5-pro", "baseModelId": "gemini-2.5-pro", "supportedGenerationMethods": ["generateContent"]}]}
                """
            } else {
                body = """
                {"models": [{"name": "models/gemini-2.5-flash", "baseModelId": "gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]}], "nextPageToken": "abc/=="}
                """
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }
        let lister = HTTPModelLister(session: session(), keyProvider: { _ in .found("gemini-key") })
        let connection = Connection(
            id: "gemini", name: "Gemini", provider: .gemini, model: "", keyRef: "k")

        let models = try await lister.listModels(for: connection, apiKey: nil)

        #expect(models == ["gemini-2.5-flash", "gemini-2.5-pro"])
        #expect(requestedURLs.count == 2)
    }
}
