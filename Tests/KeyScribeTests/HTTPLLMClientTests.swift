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
    cache: RequestAdaptationCache = RequestAdaptationCache()
) -> HTTPLLMClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LLMStubProtocol.self]
    var client = HTTPLLMClient(
        session: URLSession(configuration: config),
        keyProvider: { keyProvider($0).map(SecretLookup.found) ?? .absent })
    client.adaptationCache = cache
    return client
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
            model: Connection.Provider.openai.defaultModel, keyRef: "k")

        _ = try await stubbedClient().complete(system: "s", user: "u", connection: connection)

        #expect(body?["reasoning_effort"] as? String == "none")
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
            model: Connection.Provider.gemini.defaultModel, keyRef: "k")

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
            id: "g", name: "G", provider: .gemini, model: Connection.Provider.gemini.defaultModel, keyRef: "k")
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
