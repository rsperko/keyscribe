import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private final class LLMStubProtocol: URLProtocol, @unchecked Sendable {
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

private func stubbedClient(keyProvider: @escaping @Sendable (String) -> String? = { _ in "secret" }) -> HTTPLLMClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LLMStubProtocol.self]
    return HTTPLLMClient(session: URLSession(configuration: config), keyProvider: keyProvider)
}

private func okBody(_ content: String, finishReason: String? = nil) -> Data {
    var choice: [String: Any] = ["message": ["content": content]]
    if let finishReason { choice["finish_reason"] = finishReason }
    return try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
}

// Shared global handler → serialized suite.
@Suite(.serialized)
struct HTTPLLMClientTests {
    @Test func trailingSlashBaseURLDoesNotDoubleSlashThePath() async throws {
        nonisolated(unsafe) var seenURL: String?
        LLMStubProtocol.handler = { request in
            seenURL = request.url?.absoluteString
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, okBody("OK"))
        }
        let connection = Connection(
            id: "local", name: "Local", provider: .openaiCompatible,
            model: "qwen", keyRef: "k", baseUrl: "http://127.0.0.1:11234/v1/")
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(seenURL == "http://127.0.0.1:11234/v1/chat/completions")
    }

    @Test func hostedOpenAISendsMaxCompletionTokens() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, okBody("OK"))
        }
        let connection = Connection(id: "o", name: "O", provider: .openai, model: "gpt-5.4-mini", keyRef: "k")
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(body?["max_completion_tokens"] != nil)
        #expect(body?["max_tokens"] == nil)
    }

    @Test func openAICompatibleKeepsMaxTokens() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, okBody("OK"))
        }
        let connection = Connection(
            id: "local", name: "Local", provider: .openaiCompatible,
            model: "qwen", keyRef: "k", baseUrl: "http://127.0.0.1:11234/v1")
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(body?["max_tokens"] != nil)
        #expect(body?["max_completion_tokens"] == nil)
    }

    @Test func openAICompatiblePointedAtOpenAIUsesMaxCompletionTokens() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, okBody("OK"))
        }
        let connection = Connection(
            id: "hosted", name: "Hosted", provider: .openaiCompatible,
            model: "gpt-5.4-mini", keyRef: "k", baseUrl: "https://api.openai.com/v1")
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(body?["max_completion_tokens"] != nil)
        #expect(body?["max_tokens"] == nil)
    }

    @Test func lengthTruncatedResponseThrows() async {
        LLMStubProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             okBody("half a sentence", finishReason: "length"))
        }
        let connection = Connection(
            id: "local", name: "Local", provider: .openaiCompatible,
            model: "qwen", keyRef: "k", baseUrl: "http://127.0.0.1:11234/v1")
        await #expect(throws: LLMClientError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        }
    }

    @Test func geminiKeyTravelsInHeaderNotQueryString() async throws {
        nonisolated(unsafe) var seenURL: String?
        nonisolated(unsafe) var header: String?
        LLMStubProtocol.handler = { request in
            seenURL = request.url?.absoluteString
            header = request.value(forHTTPHeaderField: "x-goog-api-key")
            let body = try! JSONSerialization.data(withJSONObject: [
                "candidates": [["content": ["parts": [["text": "OK"]]]]]
            ])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let connection = Connection(id: "g", name: "G", provider: .gemini, model: "gemini-2.5-flash", keyRef: "k")
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(header == "secret")
        #expect(seenURL?.contains("key=") == false)
    }
}

private extension URLRequest {
    func decodedBody() -> [String: Any]? {
        guard let data = httpBodyStreamData() ?? httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // URLProtocol receives the body as a stream, so httpBody is often nil under the stub.
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
