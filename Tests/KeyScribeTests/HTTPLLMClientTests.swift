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

private func stubbedClient(
    keyProvider: @escaping @Sendable (String) -> String? = { _ in "secret" },
    cache: RequestAdaptationCache = RequestAdaptationCache(),
    wireCache: WireAPIOverrideCache = WireAPIOverrideCache()
) -> HTTPLLMClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LLMStubProtocol.self]
    var client = HTTPLLMClient(
        session: URLSession(configuration: config),
        keyProvider: { keyProvider($0).map(SecretLookup.found) ?? .absent })
    client.adaptationCache = cache
    client.wireOverrideCache = wireCache
    return client
}

private func requiresResponsesBody() -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "error": [
            "message": "This model is only supported in v1/responses and not in v1/chat/completions.",
            "type": "invalid_request_error",
        ],
    ])
}

private func requiresChatCompletionsBody() -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "error": [
            "message": "This model is only supported in v1/chat/completions and not in v1/responses.",
            "type": "invalid_request_error",
        ],
    ])
}

private func responsesOK(_ url: URL) -> (HTTPURLResponse, Data) {
    let data = try! JSONSerialization.data(withJSONObject: [
        "status": "completed",
        "output": [["type": "message", "content": [["type": "output_text", "text": "Rewritten."]]]],
    ])
    return (resp(url, 200), data)
}

private func okBody(_ content: String, finishReason: String? = nil) -> Data {
    var choice: [String: Any] = ["message": ["content": content]]
    if let finishReason { choice["finish_reason"] = finishReason }
    return try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
}

private func errBody(_ code: String, _ param: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "error": ["code": code, "param": param, "message": "unsupported"]])
}

private func resp(_ url: URL, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private func compatConnection(model: String = "qwen", baseUrl: String = "http://127.0.0.1:11234/v1") -> Connection {
    Connection(id: "local", name: "Local", provider: .openaiCompatible, model: model, keyRef: "k", baseUrl: baseUrl)
}

// Shared global handler → serialized suite.
@Suite(.serialized)
struct HTTPLLMClientTests {
    @Test func trailingSlashBaseURLDoesNotDoubleSlashThePath() async throws {
        nonisolated(unsafe) var seenURL: String?
        LLMStubProtocol.handler = { request in
            seenURL = request.url?.absoluteString
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await stubbedClient().complete(
            system: "s", user: "u", connection: compatConnection(baseUrl: "http://127.0.0.1:11234/v1/"))
        #expect(seenURL == "http://127.0.0.1:11234/v1/chat/completions")
    }

    @Test func hostedOpenAISendsMaxCompletionTokens() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (resp(request.url!, 200), okBody("OK"))
        }
        let connection = Connection(id: "o", name: "O", provider: .openai, model: "gpt-5.4-mini", keyRef: "k")
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(body?["max_completion_tokens"] != nil)
        #expect(body?["max_tokens"] == nil)
    }

    @Test func hostedOpenAISendsItsDefaultReasoningEffort() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (resp(request.url!, 200), okBody("OK"))
        }
        let connection = Connection(
            id: "o", name: "O", provider: .openai,
            model: "gpt-5.6-luna", keyRef: "k")

        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)

        #expect(body?["reasoning_effort"] as? String == "none")
    }

    @Test func responsesWireAPIUsesResponsesEnvelopeAndReadsTypedOutput() async throws {
        nonisolated(unsafe) var seenURL: String?
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            seenURL = request.url?.absoluteString
            body = request.decodedBody()
            let response = try! JSONSerialization.data(withJSONObject: [
                "status": "completed",
                "output": [
                    ["type": "reasoning", "content": []],
                    ["type": "message", "status": "completed", "content": [
                        ["type": "output_text", "text": "Rewritten text."],
                    ]],
                ],
            ])
            return (resp(request.url!, 200), response)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "new-model", keyRef: "k", baseUrl: "https://gateway.example/v1",
            params: .init(reasoningEffort: "none"), wireAPI: .responses)

        let output = try await stubbedClient().complete(system: "System instruction", user: "User input", connection: connection)

        #expect(output == "Rewritten text.")
        #expect(seenURL == "https://gateway.example/v1/responses")
        #expect(body?["instructions"] as? String == "System instruction")
        #expect(body?["input"] as? String == "User input")
        #expect(body?["max_output_tokens"] as? Int == 2048)
        #expect(body?["store"] as? Bool == false)
        #expect((body?["reasoning"] as? [String: Any])?["effort"] as? String == "none")
        #expect(body?["messages"] == nil)
        // The configured temperature is honored on both wires — a connection's sampling must not change
        // just because the wire did.
        #expect(body?["temperature"] as? Double == 0.2)
    }

    @Test func responsesWireAPISendsTheConnectionsConfiguredTemperature() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return responsesOK(request.url!)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1",
            params: .init(temperature: 0.7), wireAPI: .responses)

        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)

        #expect(body?["temperature"] as? Double == 0.7)
    }

    // A Responses server that rejects temperature self-heals through the same remediation loop the chat
    // wire uses, and the accepted adaptation is cached so the next rewrite pays no rejected round trip.
    @Test func responsesTemperatureRejectionRetriesWithoutItAndCaches() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "reasoner", keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)

        nonisolated(unsafe) var firstRun: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody()
            firstRun.append(body)
            guard body?["temperature"] == nil else {
                return (resp(request.url!, 400), errBody("unsupported_value", "temperature"))
            }
            return responsesOK(request.url!)
        }
        #expect(try await client.complete(system: "s", user: "u", connection: connection) == "Rewritten.")
        #expect(firstRun.count == 2)
        #expect(firstRun[0]?["temperature"] != nil)
        #expect(firstRun[1]?["temperature"] == nil)

        nonisolated(unsafe) var secondRun: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            secondRun.append(request.decodedBody())
            return responsesOK(request.url!)
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(secondRun.count == 1)
        #expect(secondRun[0]?["temperature"] == nil)
    }

    // A minimal gateway can implement /responses without a `status` field; a well-formed output must still
    // be read rather than dropped to local.
    @Test func responsesWithoutAStatusFieldIsAcceptedWhenOutputIsWellFormed() async throws {
        LLMStubProtocol.handler = { request in
            let data = try! JSONSerialization.data(withJSONObject: [
                "output": [["type": "message", "content": [["type": "output_text", "text": "Rewritten."]]]],
            ])
            return (resp(request.url!, 200), data)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)

        #expect(try await stubbedClient().complete(system: "s", user: "u", connection: connection) == "Rewritten.")
    }

    // But a status that IS present and is not `completed` stays strict — an unfinished reply is never
    // inserted just because it parsed.
    @Test func responsesWithAnUnfinishedStatusIsRejected() async {
        LLMStubProtocol.handler = { request in
            let data = try! JSONSerialization.data(withJSONObject: [
                "status": "in_progress",
                "output": [["type": "message", "content": [["type": "output_text", "text": "Partial"]]]],
            ])
            return (resp(request.url!, 200), data)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)

        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        }
    }

    @Test func responsesWireAPIAppliesReasoningSafeTokenFloor() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            let response = try! JSONSerialization.data(withJSONObject: [
                "status": "completed",
                "output": [["type": "message", "content": [["type": "output_text", "text": "ok"]]]],
            ])
            return (resp(request.url!, 200), response)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "reasoner", keyRef: "k", baseUrl: "https://gateway.example/v1",
            params: .init(maxTokens: 2048, reasoningEffort: "high"), wireAPI: .responses)

        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)

        #expect(body?["max_output_tokens"] as? Int == 8192)
        #expect((body?["reasoning"] as? [String: Any])?["effort"] as? String == "high")
    }

    @Test func responsesWireAPIDoesNotRetryWithoutStoreFalse() async {
        nonisolated(unsafe) var bodies: [[String: Any]] = []
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody() ?? [:]
            bodies.append(body)
            return (resp(request.url!, 400), errBody("unsupported_parameter", "store"))
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "local", keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)

        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
            Issue.record("expected rejected store parameter")
        } catch ProviderTransportError.http(let status, _) {
            #expect(status == 400)
        } catch {
            Issue.record("expected HTTP error, got \(error)")
        }
        #expect(bodies.count == 1)
        #expect(bodies.first?["store"] as? Bool == false)
    }

    @Test func adaptationCacheDoesNotCrossWireAPIs() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        nonisolated(unsafe) var responseBody: [String: Any]?
        nonisolated(unsafe) var chatAttempt = 0
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody() ?? [:]
            if request.url?.path.hasSuffix("/chat/completions") == true {
                chatAttempt += 1
                if chatAttempt == 1 {
                    return (resp(request.url!, 400), errBody("unsupported_parameter", "reasoning_effort"))
                }
                return (resp(request.url!, 200), okBody("ok"))
            }
            responseBody = body
            let response = try! JSONSerialization.data(withJSONObject: [
                "status": "completed",
                "output": [["type": "message", "content": [["type": "output_text", "text": "ok"]]]],
            ])
            return (resp(request.url!, 200), response)
        }
        let chat = Connection(id: "service", name: "Service", provider: .openai, model: "model", keyRef: "k")
        var responses = chat
        responses.wireAPI = .responses

        _ = try await client.complete(system: "s", user: "u", connection: chat)
        _ = try await client.complete(system: "s", user: "u", connection: responses)

        #expect((responseBody?["reasoning"] as? [String: Any])?["effort"] as? String == "none")
    }

    @Test func incompleteResponsesOutputIsTruncated() async {
        LLMStubProtocol.handler = { request in
            let response = try! JSONSerialization.data(withJSONObject: [
                "status": "incomplete",
                "output": [["type": "message", "content": [["type": "output_text", "text": "Partial"]]]],
            ])
            return (resp(request.url!, 200), response)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "new-model", keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)

        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
            Issue.record("expected truncated Responses output")
        } catch ProviderTransportError.truncated {
        } catch {
            Issue.record("expected truncated Responses output, got \(error)")
        }
    }

    @Test func autoWireAPIUpgradesToResponsesWhenEndpointRequiresIt() async throws {
        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/chat/completions") {
                return (resp(request.url!, 404), requiresResponsesBody())
            }
            return responsesOK(request.url!)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "responses-only", keyRef: "k", baseUrl: "https://gateway.example/v1")   // wireAPI defaults to .auto

        let output = try await stubbedClient().complete(system: "s", user: "u", connection: connection)

        #expect(output == "Rewritten.")
        #expect(paths.count == 2)
        #expect(paths.first?.hasSuffix("/chat/completions") == true)
        #expect(paths.last?.hasSuffix("/responses") == true)
    }

    @Test func autoWireAPIUpgradesToResponsesOnMethodNotAllowed() async throws {
        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/chat/completions") {
                return (resp(request.url!, 405), requiresResponsesBody())
            }
            return responsesOK(request.url!)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "responses-only", keyRef: "k", baseUrl: "https://gateway.example/v1")

        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)

        #expect(paths.map { $0.hasSuffix("/responses") } == [false, true])
    }

    @Test func autoWireAPIUpgradesWhenAProxyUsesTopLevelDetail() async throws {
        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/chat/completions") {
                let body = try! JSONSerialization.data(withJSONObject: [
                    "detail": "This model requires the /responses endpoint.",
                ])
                return (resp(request.url!, 422), body)
            }
            return responsesOK(request.url!)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "responses-only", keyRef: "k", baseUrl: "https://gateway.example/v1")

        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)

        #expect(paths.map { $0.hasSuffix("/responses") } == [false, true])
    }

    // Full proxy-envelope reproduction: a string-valued `error` with the actionable remediation in a
    // top-level `reason`, returned as a live 400. `auto` must parse it, upgrade chat → responses, return
    // the output, cache the wire override, and send later rewrites straight to /responses.
    @Test func autoWireAPIUpgradesForAProxyReasonEnvelopeAndCachesIt() async throws {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        nonisolated(unsafe) var paths: [String] = []
        let proxyReject = try! JSONSerialization.data(withJSONObject: [
            "error": "BadRequestError",
            "location": "proxy",
            "description": "The proxy threw an 'BadRequestError' error",
            "reason": "Model responses-only is not supported on /v1/chat/completions because it bypasses prompt caching on the first turn. Please use /v1/responses (OpenAI Responses API) instead.",
        ])
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/chat/completions") {
                return (resp(request.url!, 400), proxyReject)
            }
            return responsesOK(request.url!)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "responses-only", keyRef: "k", baseUrl: "https://gateway.example/v1")   // wireAPI defaults to .auto

        let output = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(output == "Rewritten.")
        #expect(paths.map { $0.hasSuffix("/chat/completions") } == [true, false])
        #expect(paths.map { $0.hasSuffix("/responses") } == [false, true])
        #expect(await wireCache.lookup(WireAPIOverrideCache.key(for: connection)) == .responses)

        // A later rewrite on the same host skips /chat/completions entirely.
        paths.removeAll()
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(paths.count == 1)
        #expect(paths.first?.hasSuffix("/responses") == true)
    }

    @Test func autoWireAPIDoesNotUpgradeForAnUnrelatedResponsesReference() async {
        nonisolated(unsafe) var paths: [String] = []
        let unrelated = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "See /responses documentation for details."]
        ])
        LLMStubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            return (resp(request.url!, 400), unrelated)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "model", keyRef: "k", baseUrl: "https://gateway.example/v1")

        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        }

        #expect(paths.count == 1)
        #expect(paths[0].hasSuffix("/chat/completions"))
    }

    @Test func autoWireAPICachesTheUpgradeSoLaterRewritesSkipChat() async throws {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        nonisolated(unsafe) var chatHits = 0
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/chat/completions") {
                chatHits += 1
                return (resp(request.url!, 404), requiresResponsesBody())
            }
            return responsesOK(request.url!)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "responses-only", keyRef: "k", baseUrl: "https://gateway.example/v1")

        _ = try await client.complete(system: "s", user: "u", connection: connection)
        _ = try await client.complete(system: "s", user: "u", connection: connection)

        #expect(chatHits == 1)   // second rewrite goes straight to /responses
        #expect(await wireCache.lookup(WireAPIOverrideCache.key(for: connection)) == .responses)
    }

    @Test func responsesFallbackToChatCompletionsWhenTheEndpointRequiresIt() async throws {
        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/responses") {
                return (resp(request.url!, 405), requiresChatCompletionsBody())
            }
            return (resp(request.url!, 200), okBody("ok"))
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)

        #expect(try await stubbedClient().complete(system: "s", user: "u", connection: connection) == "ok")
        #expect(paths.map { $0.hasSuffix("/chat/completions") } == [false, true])
    }

    @Test func responsesDoesNotSpinRemediationOnANon400Error() async {
        nonisolated(unsafe) var requests = 0
        LLMStubProtocol.handler = { request in
            requests += 1
            return (resp(request.url!, 422), errBody("unsupported_parameter", "temperature"))
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)

        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        }
        #expect(requests == 1)   // a non-400 that is not a wire-API redirect fails fast, no wasted retries
    }

    @Test func geminiSendsItsDefaultMinimumThinkingLevel() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (resp(request.url!, 200), try! JSONSerialization.data(withJSONObject: [
                "candidates": [["content": ["parts": [["text": "OK"]]]]],
            ]))
        }
        let connection = Connection(
            id: "g", name: "G", provider: .gemini,
            model: "gemini-flash-lite-latest", keyRef: "k")

        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)

        let generation = body?["generationConfig"] as? [String: Any]
        let thinking = generation?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["thinkingLevel"] as? String == "minimal")
    }

    @Test func unsupportedReasoningEffortRetriesWithoutIt() async throws {
        nonisolated(unsafe) var bodies: [[String: Any]?] = []
        let steps: [(Int, Data)] = [(400, errBody("unsupported_parameter", "reasoning_effort")), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = bodies.count
            bodies.append(request.decodedBody())
            let step = steps[min(idx, steps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        let connection = Connection(
            id: "o", name: "O", provider: .openai,
            model: "gpt-4o-mini", keyRef: "k")
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(out == "OK")
        #expect(bodies.count == 2)
        #expect(bodies[0]?["reasoning_effort"] as? String == "none")
        #expect(bodies[1]?["reasoning_effort"] == nil)
    }

    @Test func geminiRejectingThinkingConfigRetriesWithoutItAndCaches() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        let connection = Connection(
            id: "g", name: "G", provider: .gemini,
            model: "gemini-2.5-flash", keyRef: "k")
        let ok = try! JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["parts": [["text": "OK"]]]]],
        ])
        let bad = try! JSONSerialization.data(withJSONObject: [
            "error": ["code": 400, "message": "Unknown name \"thinkingLevel\"", "status": "INVALID_ARGUMENT"],
        ])

        nonisolated(unsafe) var firstRun: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody()
            firstRun.append(body)
            let hasThinking = (body?["generationConfig"] as? [String: Any])?["thinkingConfig"] != nil
            return (resp(request.url!, hasThinking ? 400 : 200), hasThinking ? bad : ok)
        }
        let out = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(out == "OK")
        #expect(firstRun.count == 2)
        #expect((firstRun[0]?["generationConfig"] as? [String: Any])?["thinkingConfig"] != nil)
        #expect((firstRun[1]?["generationConfig"] as? [String: Any])?["thinkingConfig"] == nil)

        nonisolated(unsafe) var secondRun: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            secondRun.append(request.decodedBody())
            return (resp(request.url!, 200), ok)
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(secondRun.count == 1)
        #expect((secondRun[0]?["generationConfig"] as? [String: Any])?["thinkingConfig"] == nil)
    }

    @Test func geminiUnrelated400StillFailsAndCachesNothing() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        let connection = Connection(
            id: "g", name: "G", provider: .gemini,
            model: "bogus-model", keyRef: "k")
        let bad = try! JSONSerialization.data(withJSONObject: [
            "error": ["code": 400, "message": "model not found", "status": "INVALID_ARGUMENT"],
        ])

        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { request in
            calls += 1
            return (resp(request.url!, 400), bad)
        }
        await #expect(throws: ProviderTransportError.self) {
            _ = try await client.complete(system: "s", user: "u", connection: connection)
        }
        #expect(calls == 2)

        nonisolated(unsafe) var nextBody: [String: Any]?
        let ok = try! JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["parts": [["text": "OK"]]]]],
        ])
        LLMStubProtocol.handler = { request in
            nextBody = request.decodedBody()
            return (resp(request.url!, 200), ok)
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect((nextBody?["generationConfig"] as? [String: Any])?["thinkingConfig"] != nil)
    }

    @Test func openAICompatibleKeepsMaxTokens() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(body?["max_tokens"] != nil)
        #expect(body?["max_completion_tokens"] == nil)
    }

    @Test func openAICompatiblePointedAtOpenAIStartsWithMaxTokens() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await stubbedClient().complete(
            system: "s", user: "u",
            connection: compatConnection(model: "gpt-5.4-mini", baseUrl: "https://api.openai.com/v1"))
        #expect(body?["max_tokens"] != nil)
        #expect(body?["max_completion_tokens"] == nil)
    }

    @Test func maxTokensErrorRetriesWithMaxCompletionTokens() async throws {
        nonisolated(unsafe) var bodies: [[String: Any]?] = []
        let steps: [(Int, Data)] = [(400, errBody("unsupported_parameter", "max_tokens")), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = bodies.count
            bodies.append(request.decodedBody())
            let step = steps[min(idx, steps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "OK")
        #expect(bodies.count == 2)
        #expect(bodies[0]?["max_tokens"] != nil)
        #expect(bodies[1]?["max_completion_tokens"] != nil)
        #expect(bodies[1]?["max_tokens"] == nil)
    }

    @Test func temperatureErrorRetryDropsTemperature() async throws {
        nonisolated(unsafe) var bodies: [[String: Any]?] = []
        let steps: [(Int, Data)] = [(400, errBody("unsupported_value", "temperature")), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = bodies.count
            bodies.append(request.decodedBody())
            let step = steps[min(idx, steps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(bodies.count == 2)
        #expect(bodies[0]?["temperature"] != nil)
        #expect(bodies[1]?["temperature"] == nil)
    }

    @Test func compoundRemediationResolvesTokenThenTemperatureAndRaisesBudget() async throws {
        nonisolated(unsafe) var bodies: [[String: Any]?] = []
        let steps: [(Int, Data)] = [
            (400, errBody("unsupported_parameter", "max_tokens")),
            (400, errBody("unsupported_value", "temperature")),
            (200, okBody("OK")),
        ]
        LLMStubProtocol.handler = { request in
            let idx = bodies.count
            bodies.append(request.decodedBody())
            let step = steps[min(idx, steps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "OK")
        #expect(bodies.count == 3)
        #expect(bodies[2]?["max_completion_tokens"] as? Int == 8192)
        #expect(bodies[2]?["max_tokens"] == nil)
        #expect(bodies[2]?["temperature"] == nil)
    }

    @Test func legacyRoleErrorFoldsSystemIntoUser() async throws {
        nonisolated(unsafe) var bodies: [[String: Any]?] = []
        let steps: [(Int, Data)] = [(400, errBody("unsupported_value", "messages[0].role")), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = bodies.count
            bodies.append(request.decodedBody())
            let step = steps[min(idx, steps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        _ = try await stubbedClient().complete(system: "SYS", user: "USR", connection: compatConnection())
        let firstMessages = bodies[0]?["messages"] as? [[String: Any]]
        let retryMessages = bodies[1]?["messages"] as? [[String: Any]]
        #expect(firstMessages?.count == 2)
        #expect(retryMessages?.count == 1)
        #expect(retryMessages?.first?["role"] as? String == "user")
        let folded = retryMessages?.first?["content"] as? String
        #expect(folded?.contains("SYS") == true)
        #expect(folded?.contains("USR") == true)
    }

    // Some compatible servers / proxies return `content` as an array of typed parts rather than a string.
    // It must be read, not rejected as a bad response and silently dropped to local.
    @Test func openAIContentAsPartsArrayIsAccepted() async throws {
        LLMStubProtocol.handler = { request in
            let data = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": [["type": "text", "text": "Hello there."]]]]]])
            return (resp(request.url!, 200), data)
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "Hello there.")
    }

    // A proxy can wrap a SUCCESS body in a single-element top-level array too, the same shape it uses for
    // errors — unwrap it rather than failing every rewrite.
    @Test func arrayWrappedSuccessResponseIsUnwrapped() async throws {
        LLMStubProtocol.handler = { request in
            let data = try! JSONSerialization.data(withJSONObject: [
                ["choices": [["message": ["content": "OK"]]]]])
            return (resp(request.url!, 200), data)
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "OK")
    }

    // Gemini can split its reply across multiple parts; read them all, not just the first.
    @Test func geminiJoinsMultipleTextParts() async throws {
        LLMStubProtocol.handler = { request in
            let data = try! JSONSerialization.data(withJSONObject: [
                "candidates": [["content": ["parts": [["text": "Hello "], ["text": "world."]]]]]])
            return (resp(request.url!, 200), data)
        }
        let connection = Connection(
            id: "g", name: "G", provider: .gemini, model: "gemini-flash-lite-latest", keyRef: "k")
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(out == "Hello world.")
    }

    // A proxy that wraps its error in a single-element top-level array (e.g. one fronting Gemini) must
    // still drive remediation, not slip past the parser as an unrecognized body.
    @Test func arrayWrappedProxyErrorStillRemediates() async throws {
        nonisolated(unsafe) var bodies: [[String: Any]?] = []
        let wrapped = try! JSONSerialization.data(withJSONObject: [
            ["error": ["message": "temperature is not supported by this model"]]])
        let steps: [(Int, Data)] = [(400, wrapped), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = bodies.count
            bodies.append(request.decodedBody())
            let step = steps[min(idx, steps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "OK")
        #expect(bodies.count == 2)
        #expect(bodies[0]?["temperature"] != nil)
        #expect(bodies[1]?["temperature"] == nil)
    }

    @Test func messageOnlyRoleRejectionFoldsSystemIntoUser() async throws {
        nonisolated(unsafe) var bodies: [[String: Any]?] = []
        // A generic 400 with no structured `param` — only prose — the shape a non-OpenAI proxy returns.
        let roleErr = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "This model does not support the 'system' role."]])
        let steps: [(Int, Data)] = [(400, roleErr), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = bodies.count
            bodies.append(request.decodedBody())
            let step = steps[min(idx, steps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        _ = try await stubbedClient().complete(system: "SYS", user: "USR", connection: compatConnection())
        #expect(bodies.count == 2)
        #expect((bodies[0]?["messages"] as? [[String: Any]])?.count == 2)
        let retryMessages = bodies[1]?["messages"] as? [[String: Any]]
        #expect(retryMessages?.count == 1)
        #expect(retryMessages?.first?["role"] as? String == "user")
    }

    @Test func unknownParamErrorDoesNotRetry() async {
        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { request in
            calls += 1
            return (resp(request.url!, 400), errBody("unsupported_parameter", "top_p"))
        }
        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        }
        #expect(calls == 1)   // a 400 is deterministic: no transient retry
    }

    // A transient 5xx (proxy rebooting, model still warming) shouldn't cost the rewrite — one quick retry
    // recovers it.
    @Test func transientServerErrorRetriesOnceThenSucceeds() async throws {
        nonisolated(unsafe) var calls = 0
        let steps: [(Int, Data)] = [(503, Data("overloaded".utf8)), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = calls; calls += 1
            let step = steps[min(idx, steps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "OK")
        #expect(calls == 2)
    }

    // A dropped connection is transient too — retry once rather than falling back on a blip.
    @Test func droppedConnectionRetriesOnceThenSucceeds() async throws {
        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { request in
            calls += 1
            if calls == 1 { throw URLError(.networkConnectionLost) }
            return (resp(request.url!, 200), okBody("OK"))
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "OK")
        #expect(calls == 2)
    }

    // But it is a SINGLE quick retry, not a backoff ladder — a persistent 5xx fails fast so dictation
    // falls back to the local transcript promptly.
    @Test func persistentServerErrorFailsAfterExactlyOneRetry() async {
        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { request in
            calls += 1
            return (resp(request.url!, 502), Data("bad gateway".utf8))
        }
        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        }
        #expect(calls == 2)
    }

    // A timeout already waited the full request window; retrying would double the wait, so it must not.
    @Test func timeoutDoesNotRetry() async {
        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { _ in
            calls += 1
            throw URLError(.timedOut)
        }
        await #expect(throws: Error.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        }
        #expect(calls == 1)
    }

    @Test func cachedAdaptationSkipsRediscovery() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        let connection = compatConnection()

        nonisolated(unsafe) var firstRun: [[String: Any]?] = []
        let firstSteps: [(Int, Data)] = [(400, errBody("unsupported_parameter", "max_tokens")), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = firstRun.count
            firstRun.append(request.decodedBody())
            let step = firstSteps[min(idx, firstSteps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(firstRun.count == 2)

        nonisolated(unsafe) var secondRun: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            secondRun.append(request.decodedBody())
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(secondRun.count == 1)
        #expect(secondRun[0]?["max_completion_tokens"] != nil)
        #expect(secondRun[0]?["max_tokens"] == nil)
    }

    @Test func adaptationCacheIsolatesDistinctConnectionsOnSameHost() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        let portA = Connection(
            id: "a", name: "A", provider: .openaiCompatible, model: "qwen", keyRef: "k",
            baseUrl: "http://127.0.0.1:8080/v1")
        let portB = Connection(
            id: "b", name: "B", provider: .openaiCompatible, model: "qwen", keyRef: "k",
            baseUrl: "http://127.0.0.1:8081/v1")

        nonisolated(unsafe) var firstRun: [[String: Any]?] = []
        let firstSteps: [(Int, Data)] = [(400, errBody("unsupported_parameter", "max_tokens")), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = firstRun.count
            firstRun.append(request.decodedBody())
            let step = firstSteps[min(idx, firstSteps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        _ = try await client.complete(system: "s", user: "u", connection: portA)
        #expect(firstRun.count == 2)

        nonisolated(unsafe) var secondRun: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            secondRun.append(request.decodedBody())
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await client.complete(system: "s", user: "u", connection: portB)
        #expect(secondRun.count == 1)
        #expect(secondRun[0]?["max_tokens"] != nil)
        #expect(secondRun[0]?["max_completion_tokens"] == nil)
    }

    @Test func editingBaseURLDoesNotReplayAdaptationsFromTheOldServer() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        let oldServer = Connection(
            id: "svc", name: "Svc", provider: .openaiCompatible, model: "qwen", keyRef: "k",
            baseUrl: "http://127.0.0.1:8080/v1")
        let newServer = Connection(
            id: "svc", name: "Svc", provider: .openaiCompatible, model: "qwen", keyRef: "k",
            baseUrl: "http://127.0.0.1:9090/v1")

        nonisolated(unsafe) var firstRun: [[String: Any]?] = []
        let firstSteps: [(Int, Data)] = [(400, errBody("unsupported_parameter", "max_tokens")), (200, okBody("OK"))]
        LLMStubProtocol.handler = { request in
            let idx = firstRun.count
            firstRun.append(request.decodedBody())
            let step = firstSteps[min(idx, firstSteps.count - 1)]
            return (resp(request.url!, step.0), step.1)
        }
        _ = try await client.complete(system: "s", user: "u", connection: oldServer)
        #expect(firstRun.count == 2)

        nonisolated(unsafe) var secondRun: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            secondRun.append(request.decodedBody())
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await client.complete(system: "s", user: "u", connection: newServer)
        #expect(secondRun.count == 1)
        #expect(secondRun[0]?["max_tokens"] != nil)
        #expect(secondRun[0]?["max_completion_tokens"] == nil)
    }

    // A remediation the server never accepted must not be cached. A max_tokens VALUE error carries no
    // structured param, so the message scan remaps the FIELD name — the wrong remediation — and the retry
    // fails identically. Caching it would pin max_completion_tokens for the process lifetime with no
    // reverse remediation, 400ing every later rewrite including ones that would have succeeded.
    @Test func aRemediationTheServerNeverAcceptedIsNotCached() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        let connection = compatConnection()
        let valueError = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "max_tokens must be less than or equal to 4096"]])

        nonisolated(unsafe) var attempts = 0
        LLMStubProtocol.handler = { request in
            attempts += 1
            return (resp(request.url!, 400), valueError)
        }
        await #expect(throws: ProviderTransportError.self) {
            _ = try await client.complete(system: "s", user: "u", connection: connection)
        }
        #expect(attempts == 2)   // the original request plus the one unproven remediation

        nonisolated(unsafe) var next: [String: Any]?
        LLMStubProtocol.handler = { request in
            next = request.decodedBody()
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(next?["max_tokens"] != nil)
        #expect(next?["max_completion_tokens"] == nil)
    }

    // The host behind an unchanged base URL was swapped for a chat-only server: the remembered /responses
    // override now 404s with a body naming no redirect, so nothing in the error can correct it. It must be
    // forgotten rather than pinning a dead endpoint for every later rewrite until restart.
    @Test func aStaleResponsesOverrideIsForgottenAndFallsBackToChat() async throws {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1")   // wireAPI defaults to .auto
        await wireCache.remember(.responses, for: WireAPIOverrideCache.key(for: connection))

        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/responses") {
                let notFound = try! JSONSerialization.data(withJSONObject: ["detail": "Not Found"])
                return (resp(request.url!, 404), notFound)
            }
            return (resp(request.url!, 200), okBody("OK"))
        }

        #expect(try await client.complete(system: "s", user: "u", connection: connection) == "OK")
        #expect(paths.map { $0.hasSuffix("/responses") } == [true, false])
        #expect(await wireCache.lookup(WireAPIOverrideCache.key(for: connection)) == nil)

        paths.removeAll()
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(paths.count == 1)   // the dead endpoint is not probed again
        #expect(paths.first?.hasSuffix("/chat/completions") == true)
    }

    // An endpoint that answers 401/429/5xx was FOUND — that says nothing about the wire, so the override
    // must survive and the prompt must not be resent through the other wire. Only an endpoint-mismatch
    // status (404/405) is evidence the remembered wire is gone.
    @Test(arguments: [401, 429, 502])
    func anAnsweringEndpointDoesNotForgetTheWireOverride(status: Int) async {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1")   // wireAPI defaults to .auto
        let overrideKey = WireAPIOverrideCache.key(for: connection)
        await wireCache.remember(.responses, for: overrideKey)

        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            return (resp(request.url!, status), Data("nope".utf8))
        }

        await #expect(throws: ProviderTransportError.self) {
            _ = try await client.complete(system: "s", user: "u", connection: connection)
        }
        #expect(paths.allSatisfy { $0.hasSuffix("/responses") })   // never resent through chat
        #expect(await wireCache.lookup(overrideKey) == .responses)
    }

    // With two wires, a redirect's target and the stale-override fallback's target are the same endpoint.
    // A redirect that already ran and failed must not be repeated by that fallback — the prompt would be
    // sent to the same failing endpoint twice.
    @Test func aFailedRedirectFromAStaleOverrideIsNotRetriedTwice() async throws {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1")   // wireAPI defaults to .auto
        await wireCache.remember(.responses, for: WireAPIOverrideCache.key(for: connection))

        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            // The remembered wire points at chat, and chat is gone too.
            if path.hasSuffix("/responses") {
                return (resp(request.url!, 404), requiresChatCompletionsBody())
            }
            return (resp(request.url!, 404), Data("gone".utf8))
        }

        await #expect(throws: ProviderTransportError.self) {
            _ = try await client.complete(system: "s", user: "u", connection: connection)
        }
        #expect(paths.map { $0.hasSuffix("/responses") } == [true, false])   // not [true, false, false]

        // The endpoint disowned /responses, so that override is stale even though the redirect target also
        // failed. Leaving it cached would repeat this doomed pair on every later rewrite.
        #expect(await wireCache.lookup(WireAPIOverrideCache.key(for: connection)) == nil)

        paths.removeAll()
        LLMStubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            return (resp(request.url!, 200), okBody("OK"))
        }
        #expect(try await client.complete(system: "s", user: "u", connection: connection) == "OK")
        #expect(paths.count == 1)
        #expect(paths.first?.hasSuffix("/chat/completions") == true)
    }

    // OpenAI answers a bad model id with a structured 404. That is the endpoint speaking about the model —
    // which is itself part of the override's cache key — not about the wire, so the override must survive
    // and the prompt must not be resent through the other wire.
    @Test func aMissingModel404DoesNotForgetTheWireOverride() async {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "typo-model", keyRef: "k", baseUrl: "https://gateway.example/v1")   // wireAPI defaults to .auto
        let overrideKey = WireAPIOverrideCache.key(for: connection)
        await wireCache.remember(.responses, for: overrideKey)

        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            let missingModel = try! JSONSerialization.data(withJSONObject: [
                "error": [
                    "message": "The model `typo-model` does not exist or you do not have access to it.",
                    "type": "invalid_request_error",
                    "code": "model_not_found",
                ],
            ])
            return (resp(request.url!, 404), missingModel)
        }

        await #expect(throws: ProviderTransportError.self) {
            _ = try await client.complete(system: "s", user: "u", connection: connection)
        }
        #expect(paths.count == 1)   // no chat re-probe
        #expect(paths.first?.hasSuffix("/responses") == true)
        #expect(await wireCache.lookup(overrideKey) == .responses)
    }

    // An endpoint that names a wire it then fails to serve must not leave that wire behind for every later
    // rewrite to start at.
    @Test func aRedirectThatFailsIsNotRememberedAsTheWire() async {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/chat/completions") {
                return (resp(request.url!, 400), requiresResponsesBody())
            }
            return (resp(request.url!, 500), Data("responses is broken".utf8))
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "responses-only", keyRef: "k", baseUrl: "https://gateway.example/v1")

        await #expect(throws: ProviderTransportError.self) {
            _ = try await client.complete(system: "s", user: "u", connection: connection)
        }
        #expect(await wireCache.lookup(WireAPIOverrideCache.key(for: connection)) == nil)
    }

    // A response the endpoint spoke correctly is not evidence against the override — only an endpoint-
    // mismatch status is. A truncated reply must leave the remembered wire alone.
    @Test func aTruncatedReplyDoesNotForgetTheWireOverride() async {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1")
        await wireCache.remember(.responses, for: WireAPIOverrideCache.key(for: connection))

        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            let data = try! JSONSerialization.data(withJSONObject: [
                "status": "incomplete",
                "output": [["type": "message", "content": [["type": "output_text", "text": "Partial"]]]],
            ])
            return (resp(request.url!, 200), data)
        }

        await #expect(throws: ProviderTransportError.self) {
            _ = try await client.complete(system: "s", user: "u", connection: connection)
        }
        #expect(paths.count == 1)   // no chat re-probe
        #expect(await wireCache.lookup(WireAPIOverrideCache.key(for: connection)) == .responses)
    }

    // An explicitly configured wire is a starting hint, not a strict contract — the client already falls
    // back when the endpoint says so. Having learned that, it must not repeat the known-failing round trip
    // on every dictation.
    @Test func anExplicitChatConnectionStartsAtTheWireItFellBackTo() async throws {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/chat/completions") {
                return (resp(request.url!, 400), requiresResponsesBody())
            }
            return responsesOK(request.url!)
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "responses-only", keyRef: "k", baseUrl: "https://gateway.example/v1",
            wireAPI: .chatCompletions)

        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(paths.map { $0.hasSuffix("/responses") } == [false, true])

        paths.removeAll()
        #expect(try await client.complete(system: "s", user: "u", connection: connection) == "Rewritten.")
        #expect(paths.count == 1)
        #expect(paths.first?.hasSuffix("/responses") == true)
    }

    @Test func anExplicitResponsesConnectionStartsAtTheWireItFellBackTo() async throws {
        let wireCache = WireAPIOverrideCache()
        let client = stubbedClient(wireCache: wireCache)
        nonisolated(unsafe) var paths: [String] = []
        LLMStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/responses") {
                return (resp(request.url!, 405), requiresChatCompletionsBody())
            }
            return (resp(request.url!, 200), okBody("OK"))
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)

        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(paths.map { $0.hasSuffix("/chat/completions") } == [false, true])

        paths.removeAll()
        #expect(try await client.complete(system: "s", user: "u", connection: connection) == "OK")
        #expect(paths.count == 1)
        #expect(paths.first?.hasSuffix("/chat/completions") == true)
    }

    @Test func reasoningTagsAreStrippedFromContent() async throws {
        LLMStubProtocol.handler = { request in
            (resp(request.url!, 200), okBody("<think>plan the reply</think>Result text"))
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "Result text")
    }

    @Test func emptyAfterStrippingReasoningThrows() async {
        LLMStubProtocol.handler = { request in
            (resp(request.url!, 200), okBody("<think>all budget went here</think>"))
        }
        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        }
    }

    @Test func errorObjectInsideSuccessBodyThrowsWithoutLooping() async {
        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { request in
            calls += 1
            let body = try! JSONSerialization.data(withJSONObject: [
                "error": ["message": "upstream boom", "code": "server_error"]])
            return (resp(request.url!, 200), body)
        }
        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        }
        #expect(calls == 1)
    }

    @Test func openRouterHostGetsAttributionHeaders() async throws {
        nonisolated(unsafe) var referer: String?
        nonisolated(unsafe) var title: String?
        LLMStubProtocol.handler = { request in
            referer = request.value(forHTTPHeaderField: "HTTP-Referer")
            title = request.value(forHTTPHeaderField: "X-Title")
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await stubbedClient().complete(
            system: "s", user: "u",
            connection: compatConnection(baseUrl: "https://openrouter.ai/api/v1"))
        #expect(referer?.isEmpty == false)
        #expect(title?.isEmpty == false)
    }

    @Test func nonOpenRouterHostHasNoAttributionHeaders() async throws {
        nonisolated(unsafe) var referer: String?
        nonisolated(unsafe) var title: String?
        LLMStubProtocol.handler = { request in
            referer = request.value(forHTTPHeaderField: "HTTP-Referer")
            title = request.value(forHTTPHeaderField: "X-Title")
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(referer == nil)
        #expect(title == nil)
    }

    @Test func anthropicBodyUsesMaxTokensAndDoesNotRemediate() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { request in
            calls += 1
            body = request.decodedBody()
            let data = try! JSONSerialization.data(withJSONObject: ["content": [["text": "OK"]]])
            return (resp(request.url!, 200), data)
        }
        let connection = Connection(id: "a", name: "A", provider: .anthropic, model: "claude-haiku-4-5", keyRef: "k")
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(out == "OK")
        #expect(body?["max_tokens"] != nil)
        #expect(body?["max_completion_tokens"] == nil)
        #expect(calls == 1)
    }

    @Test func anthropicSkipsLeadingNonTextBlock() async throws {
        LLMStubProtocol.handler = { request in
            let data = try! JSONSerialization.data(withJSONObject: [
                "content": [
                    ["type": "thinking", "thinking": "let me consider"],
                    ["type": "text", "text": "Final answer"],
                ],
            ])
            return (resp(request.url!, 200), data)
        }
        let connection = Connection(id: "a", name: "A", provider: .anthropic, model: "claude-haiku-4-5", keyRef: "k")
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(out == "Final answer")
    }

    @Test func anthropicDoesNotRetryOnBadRequest() async {
        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { request in
            calls += 1
            return (resp(request.url!, 400), errBody("unsupported_parameter", "max_tokens"))
        }
        let connection = Connection(id: "a", name: "A", provider: .anthropic, model: "claude-haiku-4-5", keyRef: "k")
        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        }
        #expect(calls == 1)
    }

    @Test func lengthTruncatedResponseThrows() async {
        LLMStubProtocol.handler = { request in
            (resp(request.url!, 200), okBody("half a sentence", finishReason: "length"))
        }
        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
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
            return (resp(request.url!, 200), body)
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
