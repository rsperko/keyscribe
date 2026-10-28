import Foundation
import Testing
@testable import KeyScribeApp
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
            params: .init(), wireAPI: .responses)

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
            params: .init(maxTokens: 2048, reasoning: .level("high")), wireAPI: .responses)

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

    @Test func incompleteResponsesWithoutAReasonIsAnIncompleteReplyNotTheLimit() async {
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
            Issue.record("expected an incomplete reply")
        } catch ProviderTransportError.incompleteReply {
        } catch {
            Issue.record("expected incompleteReply, got \(error)")
        }
    }

    @Test func incompleteResponsesOutputIsTruncated() async {
        LLMStubProtocol.handler = { request in
            let response = try! JSONSerialization.data(withJSONObject: [
                "status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"],
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
        #expect(bodies[0]?["max_completion_tokens"] as? Int == 2048)
        #expect(bodies[1]?["max_completion_tokens"] as? Int == 8192)
    }

    @Test func geminiRejectingThinkingLevelMovesToABudgetAndCaches() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        let connection = Connection(
            id: "g", name: "G", provider: .gemini,
            model: "gemini-2.5-flash", keyRef: "k")
        let ok = try! JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["parts": [["text": "OK"]]]]],
        ])
        let bad = try! JSONSerialization.data(withJSONObject: [
            "error": ["code": 400, "message": "Unknown name \"thinkingLevel\" at 'generation_config.thinking_config': Cannot find field.", "status": "INVALID_ARGUMENT"],
        ])

        nonisolated(unsafe) var firstRun: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody()
            firstRun.append(body)
            let thinking = (body?["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
            let rejected = thinking?["thinkingLevel"] != nil
            return (resp(request.url!, rejected ? 400 : 200), rejected ? bad : ok)
        }
        let out = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(out == "OK")
        #expect(firstRun.count == 2)
        let retried = (firstRun[1]?["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(retried?["thinkingBudget"] as? Int == 0)
        #expect(retried?["thinkingLevel"] == nil)

        nonisolated(unsafe) var secondRun: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            secondRun.append(request.decodedBody())
            return (resp(request.url!, 200), ok)
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(secondRun.count == 1)
        let cached = (secondRun[0]?["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(cached?["thinkingBudget"] as? Int == 0)
    }

    @Test func geminiLowestWalksMinimalLowBudgetZeroBudget128() async throws {
        let connection = Connection(id: "g", name: "G", provider: .gemini, model: "gemini-x", keyRef: "k")
        let ok = try! JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["parts": [["text": "OK"]]]]],
        ])
        let valueError = try! JSONSerialization.data(withJSONObject: [
            "error": ["code": 400, "message": "This thinking setting is not valid for this model.", "status": "INVALID_ARGUMENT"],
        ])
        nonisolated(unsafe) var configs: [[String: Any]] = []
        LLMStubProtocol.handler = { request in
            let thinking = ((request.decodedBody()?["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]) ?? [:]
            configs.append(thinking)
            let accepted = thinking["thinkingBudget"] as? Int == 128
            return (resp(request.url!, accepted ? 200 : 400), accepted ? ok : valueError)
        }
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(configs.count == 4)
        #expect(configs[0]["thinkingLevel"] as? String == "minimal")
        #expect(configs[1]["thinkingLevel"] as? String == "low")
        #expect(configs[2]["thinkingBudget"] as? Int == 0)
        #expect(configs[3]["thinkingBudget"] as? Int == 128)
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
        #expect(calls == 1)

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

    @Test func openAIContentAsPartsArrayIsAccepted() async throws {
        LLMStubProtocol.handler = { request in
            let data = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": [["type": "text", "text": "Hello there."]]]]]])
            return (resp(request.url!, 200), data)
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "Hello there.")
    }

    @Test func arrayWrappedSuccessResponseIsUnwrapped() async throws {
        LLMStubProtocol.handler = { request in
            let data = try! JSONSerialization.data(withJSONObject: [
                ["choices": [["message": ["content": "OK"]]]]])
            return (resp(request.url!, 200), data)
        }
        let out = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(out == "OK")
    }

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

    @Test func persistentServerErrorFailsAfterTwoRetries() async {
        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { request in
            calls += 1
            return (resp(request.url!, 502), Data("bad gateway".utf8))
        }
        await #expect(throws: ProviderTransportError.self) {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        }
        #expect(calls == 3)
    }

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

    @Test func nullContentAtLengthWithReasoningUsageIsLimitBeforeAnswerWithEvidence() async {
        LLMStubProtocol.handler = { request in
            let body = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["role": "assistant", "content": NSNull()], "finish_reason": "length"]],
                "usage": ["completion_tokens": 2048, "completion_tokens_details": ["reasoning_tokens": 2048]],
            ])
            return (resp(request.url!, 200), body)
        }
        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection(model: "kimi-k3"))
            Issue.record("expected the reasoning-exhaustion error")
        } catch ProviderTransportError.limitBeforeAnswer(let evidence) {
            #expect(evidence)
        } catch {
            Issue.record("expected limitBeforeAnswer, got \(error)")
        }
    }

    @Test func nullContentAtLengthWithoutUsageIsLimitBeforeAnswerWithoutEvidence() async {
        LLMStubProtocol.handler = { request in
            let body = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": NSNull()], "finish_reason": "length"]],
            ])
            return (resp(request.url!, 200), body)
        }
        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
            Issue.record("expected a limit error")
        } catch ProviderTransportError.limitBeforeAnswer(let evidence) {
            #expect(!evidence)
        } catch {
            Issue.record("expected limitBeforeAnswer, got \(error)")
        }
    }

    @Test func lengthWithTextIsTruncatedAnswer() async {
        LLMStubProtocol.handler = { request in
            (resp(request.url!, 200), okBody("half a sentence", finishReason: "length"))
        }
        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
            Issue.record("expected truncation")
        } catch ProviderTransportError.truncated {
        } catch {
            Issue.record("expected truncated, got \(error)")
        }
    }

    @Test func geminiMaxTokensWithEmptyTextUsesThoughtsTokenCountAsEvidence() async {
        LLMStubProtocol.handler = { request in
            let body = try! JSONSerialization.data(withJSONObject: [
                "candidates": [["content": ["parts": []], "finishReason": "MAX_TOKENS"]],
                "usageMetadata": ["thoughtsTokenCount": 2048],
            ])
            return (resp(request.url!, 200), body)
        }
        let connection = Connection(id: "g", name: "G", provider: .gemini, model: "gemini-3", keyRef: "k")
        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
            Issue.record("expected a limit error")
        } catch ProviderTransportError.limitBeforeAnswer(let evidence) {
            #expect(evidence)
        } catch {
            Issue.record("expected limitBeforeAnswer, got \(error)")
        }
    }

    @Test func anthropicMaxTokensWithOnlyThinkingBlocksIsLimitBeforeAnswer() async {
        LLMStubProtocol.handler = { request in
            let body = try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "thinking", "thinking": ""]],
                "stop_reason": "max_tokens",
            ])
            return (resp(request.url!, 200), body)
        }
        let connection = Connection(id: "a", name: "A", provider: .anthropic, model: "claude-x", keyRef: "k")
        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
            Issue.record("expected a limit error")
        } catch ProviderTransportError.limitBeforeAnswer(let evidence) {
            #expect(evidence)
        } catch {
            Issue.record("expected limitBeforeAnswer, got \(error)")
        }
    }

    @Test func responsesIncompleteAttributesOnlyMaxOutputTokens() async {
        func incomplete(_ reason: String) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "status": "incomplete", "incomplete_details": ["reason": reason], "output": [],
            ])
        }
        let connection = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible,
            model: "m", keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)
        LLMStubProtocol.handler = { request in (resp(request.url!, 200), incomplete("content_filter")) }
        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
            Issue.record("expected an incomplete reply")
        } catch ProviderTransportError.incompleteReply {
        } catch {
            Issue.record("expected incompleteReply, got \(error)")
        }
        LLMStubProtocol.handler = { request in (resp(request.url!, 200), incomplete("max_output_tokens")) }
        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
            Issue.record("expected a limit error")
        } catch ProviderTransportError.limitBeforeAnswer {
        } catch {
            Issue.record("expected limitBeforeAnswer, got \(error)")
        }
    }

    @Test func openAICompatibleStartsAtNoneWithoutHeadroom() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
        #expect(body?["reasoning_effort"] as? String == "none")
        #expect(body?["max_tokens"] as? Int == 2048)
    }

    @Test func anUnsupportedValueClimbsTheLadderAndCachesTheAcceptedRung() async throws {
        let client = stubbedClient(cache: RequestAdaptationCache())
        let connection = compatConnection(model: "kimi-k3")
        let rejected = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "Invalid value for reasoning_effort. This model always reasons.", "type": "invalid_request_error"]])
        nonisolated(unsafe) var efforts: [String?] = []
        nonisolated(unsafe) var tokens: [Int?] = []
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody()
            let effort = body?["reasoning_effort"] as? String
            efforts.append(effort)
            tokens.append(body?["max_tokens"] as? Int)
            return effort == "low" ? (resp(request.url!, 200), okBody("OK")) : (resp(request.url!, 400), rejected)
        }
        #expect(try await client.complete(system: "s", user: "u", connection: connection) == "OK")
        #expect(efforts == ["none", "minimal", "low"])
        #expect(tokens.last == 8192)
        #expect(await client.reasoningOutcome(for: connection)?.summary == "Low — the lowest this model accepts")

        efforts = []
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(efforts == ["low"])
    }

    @Test func aListedSupportedValueSkipsRungs() async throws {
        let rejected = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "reasoning_effort must be one of low, high, max"]])
        nonisolated(unsafe) var efforts: [String?] = []
        LLMStubProtocol.handler = { request in
            let effort = request.decodedBody()?["reasoning_effort"] as? String
            efforts.append(effort)
            return effort == "low" ? (resp(request.url!, 200), okBody("OK")) : (resp(request.url!, 400), rejected)
        }
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection(model: "kimi-k3"))
        #expect(efforts == ["none", "low"])
    }

    @Test func anUnknownParameterIsRecordedInOneRoundTripAndKeepsHeadroom() async throws {
        let client = stubbedClient(cache: RequestAdaptationCache())
        let connection = compatConnection()
        let unknown = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "Unrecognized request argument supplied: reasoning_effort"]])
        nonisolated(unsafe) var bodies: [[String: Any]?] = []
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody()
            bodies.append(body)
            return body?["reasoning_effort"] == nil ? (resp(request.url!, 200), okBody("OK")) : (resp(request.url!, 400), unknown)
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(bodies.count == 2)
        #expect(bodies[1]?["max_tokens"] as? Int == 8192)
        let outcome = await client.reasoningOutcome(for: connection)
        #expect(outcome?.kind == .notSettable)
        #expect(outcome?.deservesNotice == true)
    }

    @Test func aRemovedControlOnAModelThatReportsNoReasoningIsNotAnnounced() async throws {
        let client = stubbedClient(cache: RequestAdaptationCache())
        let connection = compatConnection(model: "gpt-4o-mini")
        let unknown = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "Unrecognized request argument supplied: reasoning_effort"]])
        LLMStubProtocol.handler = { request in
            guard request.decodedBody()?["reasoning_effort"] == nil else { return (resp(request.url!, 400), unknown) }
            let body = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "OK"], "finish_reason": "stop"]],
                "usage": ["completion_tokens": 3, "completion_tokens_details": ["reasoning_tokens": 0]],
            ])
            return (resp(request.url!, 200), body)
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        let outcome = await client.reasoningOutcome(for: connection)
        #expect(outcome?.kind == .notAdjustable)
        #expect(outcome?.deservesNotice == false)
    }

    @Test func anAcceptedOffWithoutAReasoningCountIsReportedAsUnconfirmed() async throws {
        let client = stubbedClient(cache: RequestAdaptationCache())
        let connection = compatConnection()
        LLMStubProtocol.handler = { request in (resp(request.url!, 200), okBody("OK")) }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(await client.reasoningOutcome(for: connection)?.kind == .offUnconfirmed)
    }

    @Test func aServerThatCannotTakeTheSettingButReasonsAnywayIsReported() async throws {
        let client = stubbedClient(cache: RequestAdaptationCache())
        let connection = compatConnection(model: "qwen3")
        let unknown = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "Unrecognized request argument supplied: reasoning_effort"]])
        LLMStubProtocol.handler = { request in
            guard request.decodedBody()?["reasoning_effort"] == nil else { return (resp(request.url!, 400), unknown) }
            let body = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "OK", "reasoning_content": "let me think"], "finish_reason": "stop"]],
            ])
            return (resp(request.url!, 200), body)
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        let outcome = await client.reasoningOutcome(for: connection)
        #expect(outcome?.kind == .uncontrolledReasoning)
        #expect(outcome?.deservesNotice == true)
    }

    @Test func anAcceptedNoneThatStillReportsReasoningTokensIsNotHonored() async throws {
        let client = stubbedClient(cache: RequestAdaptationCache())
        let connection = compatConnection()
        nonisolated(unsafe) var tokens: [Int?] = []
        LLMStubProtocol.handler = { request in
            tokens.append(request.decodedBody()?["max_tokens"] as? Int)
            let body = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "OK"], "finish_reason": "stop"]],
                "usage": ["completion_tokens": 300, "completion_tokens_details": ["reasoning_tokens": 290]],
            ])
            return (resp(request.url!, 200), body)
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(await client.reasoningOutcome(for: connection)?.kind == .notHonored)
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(tokens == [2048, 8192])
    }

    @Test func openRouterRequestsRequireParametersAndUseItsReasoningObject() async throws {
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await stubbedClient().complete(
            system: "s", user: "u", connection: compatConnection(baseUrl: "https://openrouter.ai/api/v1"))
        #expect((body?["reasoning"] as? [String: Any])?["effort"] as? String == "none")
        #expect((body?["provider"] as? [String: Any])?["require_parameters"] as? Bool == true)
        #expect(body?["reasoning_effort"] == nil)
    }

    private struct RoutedRequest: Sendable {
        let effort: String?
        let required: Bool
        let temperature: Bool
    }

    private static func routed(_ request: URLRequest) -> RoutedRequest {
        let body = request.decodedBody()
        return RoutedRequest(
            effort: (body?["reasoning"] as? [String: Any])?["effort"] as? String,
            required: (body?["provider"] as? [String: Any])?["require_parameters"] as? Bool == true,
            temperature: body?["temperature"] != nil)
    }

    private static let noRouteBody = try! JSONSerialization.data(withJSONObject: [
        "error": ["message": "No endpoints found that can handle the requested parameters.", "code": 404]])

    @Test func aRouterThatCannotRouteTemperatureDropsItAndKeepsTheReasoningEnforced() async throws {
        var connection = compatConnection(baseUrl: "https://openrouter.ai/api/v1")
        connection.params.reasoning = .level("high")
        nonisolated(unsafe) var sent: [RoutedRequest] = []
        LLMStubProtocol.handler = { request in
            let routed = Self.routed(request)
            sent.append(routed)
            return routed.temperature ? (resp(request.url!, 404), Self.noRouteBody) : (resp(request.url!, 200), okBody("OK"))
        }
        let client = stubbedClient(cache: RequestAdaptationCache())
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(sent.map(\.effort) == ["high", "high"])
        #expect(sent.map(\.required) == [true, true])
        #expect(sent.map(\.temperature) == [true, false])
        #expect(await client.reasoningOutcome(for: connection)?.kind == .level)
    }

    @Test func aChosenLevelWithNoRouteFailsInsteadOfBeingSentUnenforced() async {
        var connection = compatConnection(baseUrl: "https://openrouter.ai/api/v1")
        connection.params.reasoning = .level("high")
        nonisolated(unsafe) var sent: [RoutedRequest] = []
        LLMStubProtocol.handler = { request in
            let routed = Self.routed(request)
            sent.append(routed)
            return routed.required ? (resp(request.url!, 404), Self.noRouteBody) : (resp(request.url!, 200), okBody("OK"))
        }
        do {
            _ = try await stubbedClient(cache: RequestAdaptationCache()).complete(system: "s", user: "u", connection: connection)
            Issue.record("expected the rewrite to fail")
        } catch ProviderTransportError.noRouteForReasoningLevel(let level) {
            #expect(level == "high")
        } catch {
            Issue.record("expected noRouteForReasoningLevel, got \(error)")
        }
        #expect(sent.allSatisfy { $0.required })
    }

    @Test func lowestAvailableWithNoEnforcedRouteIsReportedAsNotGuaranteed() async throws {
        let connection = compatConnection(baseUrl: "https://openrouter.ai/api/v1")
        nonisolated(unsafe) var sent: [RoutedRequest] = []
        LLMStubProtocol.handler = { request in
            let routed = Self.routed(request)
            sent.append(routed)
            return routed.required ? (resp(request.url!, 404), Self.noRouteBody) : (resp(request.url!, 200), okBody("OK"))
        }
        let client = stubbedClient(cache: RequestAdaptationCache())
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(sent.map(\.required) == [true, true, false])
        let outcome = await client.reasoningOutcome(for: connection)
        #expect(outcome?.kind == .unenforced)
        #expect(outcome?.deservesNotice == true)
    }

    @Test func aRouterWithNoEndpointsForTheModelFailsWithoutTouchingReasoning() async {
        let unavailable = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "No endpoints found for moonshotai/kimi-k3.", "code": 404]])
        nonisolated(unsafe) var efforts: [String?] = []
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody()
            efforts.append((body?["reasoning"] as? [String: Any])?["effort"] as? String)
            return (resp(request.url!, 404), unavailable)
        }
        await #expect(throws: (any Error).self) {
            _ = try await stubbedClient(cache: RequestAdaptationCache()).complete(
                system: "s", user: "u", connection: compatConnection(baseUrl: "https://openrouter.ai/api/v1"))
        }
        #expect(!efforts.isEmpty)
        #expect(efforts.allSatisfy { $0 == "none" })
    }

    @Test func anExplicitLevelThatIsRejectedFailsWithTheRefusedReason() async {
        var connection = compatConnection(model: "kimi-k3")
        connection.params.reasoning = .level("medium")
        nonisolated(unsafe) var calls = 0
        LLMStubProtocol.handler = { request in
            calls += 1
            return (resp(request.url!, 400), try! JSONSerialization.data(withJSONObject: [
                "error": ["message": "reasoning_effort must be one of low, high, max"]]))
        }
        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
            Issue.record("expected a refusal")
        } catch ProviderTransportError.reasoningLevelRefused(let level) {
            #expect(level == "medium")
            #expect(ProviderTransportError.reasoningLevelRefused(level).rewriteFailureReason.contains("Medium"))
        } catch {
            Issue.record("expected reasoningLevelRefused, got \(error)")
        }
        #expect(calls == 1)
    }

    @Test func anthropicLowestWalksDisabledBetweenToolsEffortLow() async throws {
        let cache = RequestAdaptationCache()
        let client = stubbedClient(cache: cache)
        let connection = Connection(id: "a", name: "A", provider: .anthropic, model: "claude-opus-5-5", keyRef: "k")
        let rejected = try! JSONSerialization.data(withJSONObject: [
            "type": "error", "error": ["type": "invalid_request_error", "message": "thinking.type: this model does not accept this value"]])
        let ok = try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "OK"]], "stop_reason": "end_turn"])
        nonisolated(unsafe) var bodies: [[String: Any]] = []
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody() ?? [:]
            bodies.append(body)
            return body["thinking"] == nil ? (resp(request.url!, 200), ok) : (resp(request.url!, 400), rejected)
        }
        #expect(try await client.complete(system: "s", user: "u", connection: connection) == "OK")
        #expect(bodies.count == 3)
        #expect((bodies[0]["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((bodies[1]["thinking"] as? [String: Any])?["type"] as? String == "between_tools")
        #expect((bodies[2]["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(bodies[2]["thinking"] == nil)
        #expect(bodies[0]["max_tokens"] as? Int == 2048)
        #expect(bodies[2]["max_tokens"] as? Int == 8192)

        bodies = []
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(bodies.count == 1)
        #expect((bodies[0]["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func anthropicExplicitLevelSendsAdaptiveWithEffort() async throws {
        var connection = Connection(id: "a", name: "A", provider: .anthropic, model: "claude-sonnet-4-6", keyRef: "k")
        connection.params.reasoning = .level("high")
        nonisolated(unsafe) var body: [String: Any]?
        LLMStubProtocol.handler = { request in
            body = request.decodedBody()
            return (resp(request.url!, 200), try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "OK"]]]))
        }
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect((body?["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((body?["output_config"] as? [String: Any])?["effort"] as? String == "high")
    }

    @Test func anthropicDropsTemperatureWhenThinkingRequiresTheDefault() async throws {
        var connection = Connection(id: "a", name: "A", provider: .anthropic, model: "claude-sonnet-4-6", keyRef: "k")
        connection.params.reasoning = .level("high")
        let rejected = try! JSONSerialization.data(withJSONObject: [
            "type": "error", "error": ["type": "invalid_request_error",
                                       "message": "`temperature` may only be set to 1 when thinking is enabled or in adaptive mode."]])
        nonisolated(unsafe) var bodies: [[String: Any]] = []
        LLMStubProtocol.handler = { request in
            let body = request.decodedBody() ?? [:]
            bodies.append(body)
            return body["temperature"] == nil
                ? (resp(request.url!, 200), try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "OK"]]]))
                : (resp(request.url!, 400), rejected)
        }
        #expect(try await stubbedClient().complete(system: "s", user: "u", connection: connection) == "OK")
        #expect(bodies.count == 2)
        #expect((bodies[1]["output_config"] as? [String: Any])?["effort"] as? String == "high")
    }

    @Test func changingThePreferenceDoesNotReplayTheOldLadder() async throws {
        let client = stubbedClient(cache: RequestAdaptationCache())
        var connection = compatConnection()
        LLMStubProtocol.handler = { request in
            let effort = request.decodedBody()?["reasoning_effort"] as? String
            return effort == "none"
                ? (resp(request.url!, 400), errBody("unsupported_value", "reasoning_effort"))
                : (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)

        connection.params.reasoning = .level("high")
        nonisolated(unsafe) var effort: String?
        LLMStubProtocol.handler = { request in
            effort = request.decodedBody()?["reasoning_effort"] as? String
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(effort == "high")
    }

    @Test func aServerCeilingClampsTheTokenValueAndIsCached() async throws {
        let client = stubbedClient(cache: RequestAdaptationCache())
        var connection = compatConnection()
        connection.params.reasoning = .modelDefault
        nonisolated(unsafe) var tokens: [Int?] = []
        LLMStubProtocol.handler = { request in
            let value = request.decodedBody()?["max_tokens"] as? Int
            tokens.append(value)
            guard let value, value <= 4096 else {
                return (resp(request.url!, 400), try! JSONSerialization.data(withJSONObject: [
                    "error": ["message": "max_tokens must be less than or equal to 4096"]]))
            }
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        _ = try await client.complete(system: "s", user: "u", connection: connection)
        #expect(tokens == [8192, 4096, 4096])
    }

    @Test func aPublishedOutputCeilingClampsBeforeTheFirstRequest() async throws {
        var connection = compatConnection()
        connection.params.reasoning = .modelDefault
        connection.params.outputCeiling = 5000
        nonisolated(unsafe) var tokens: Int?
        LLMStubProtocol.handler = { request in
            tokens = request.decodedBody()?["max_tokens"] as? Int
            return (resp(request.url!, 200), okBody("OK"))
        }
        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)
        #expect(tokens == 5000)
    }

    @Test func anUnclosedThinkBlockAtTheLimitIsReasoningNotAnAnswer() async {
        LLMStubProtocol.handler = { request in
            (resp(request.url!, 200), okBody("<think>still working through it", finishReason: "length"))
        }
        do {
            _ = try await stubbedClient().complete(system: "s", user: "u", connection: compatConnection())
            Issue.record("expected a limit error")
        } catch ProviderTransportError.limitBeforeAnswer(let evidence) {
            #expect(evidence)
        } catch {
            Issue.record("expected limitBeforeAnswer, got \(error)")
        }
    }
}

private extension URLRequest {
    func decodedBody() -> [String: Any]? {
        guard let data = httpBodyStreamData() ?? httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

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
