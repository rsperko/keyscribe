import Foundation
import KeyScribeKit

// Thin BYOK transport over the OpenAI / Anthropic / Gemini HTTP APIs (design.md §5). Key fetched from
// Keychain by the connection's key_ref. Provider-agnostic orchestration (assemble → gate → retry/fallback)
// lives in KeyScribeKit.RewriteService.
struct HTTPLLMClient: LLMClient {
    // Bounded session, not URLSession.shared (60s default, doubled by the gate's stricter-retry). A hung
    // BYOK endpoint must fall back to the local transcript promptly, so cap each attempt.
    var session: URLSession = ProviderTransport.makeSession(requestTimeout: 30, resourceTimeout: 45)
    var keyProvider: @Sendable (String) -> SecretLookup = { KeychainStore.lookup($0) }
    var tokenCommandRunner: @Sendable (String) async throws -> String = { try await TokenCommandRunner.run($0) }
    var tokenCache: TokenCommandCache = .shared
    var adaptationCache: RequestAdaptationCache = .shared
    var wireOverrideCache: WireAPIOverrideCache = .shared
    var now: @Sendable () -> Date = { Date() }

    private static let maxRemediations = 4

    private var transport: ProviderTransport {
        ProviderTransport(session: session, keyProvider: keyProvider,
                          tokenCommandRunner: tokenCommandRunner, tokenCache: tokenCache, now: now)
    }

    // Bodyless, auth-less HEAD warm-up — carries no user content — so a rewrite moments later reuses the
    // pooled connection.
    func preconnect(connection: Connection) async {
        guard let url = preconnectURL(for: connection) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        _ = try? await session.data(for: req)
    }

    private func preconnectURL(for connection: Connection) -> URL? {
        switch connection.provider {
        case .openai, .openaiCompatible:
            let base = connection.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines).removingTrailingSlash
                ?? (connection.provider == .openai ? "https://api.openai.com/v1" : nil)
            return base.flatMap { URL(string: $0) }
        case .anthropic:
            return URL(string: "https://api.anthropic.com")
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com")
        }
    }

    func complete(system: String, user: String, connection: Connection) async throws -> String {
        let key = try await transport.credential(for: connection)
        if connection.provider != .openaiCompatible, key?.isEmpty != false {
            throw ProviderTransportError.missingKey(connection.keyRef)
        }
        switch connection.provider {
        case .openai, .openaiCompatible:
            switch connection.wireAPI {
            case .responses:
                return try await completeResponses(system: system, user: user, connection: connection, key: key)
            case .chatCompletions:
                return try await completeOpenAI(
                    system: system, user: user, connection: connection, key: key, allowResponsesUpgrade: true)
            case .auto:
                // Discovered protocol: skip straight to Responses if this host already told us to; otherwise
                // try Chat Completions and upgrade on the endpoint's own "use /responses" signal.
                if await wireOverrideCache.lookup(Self.hostKey(for: connection)) == .responses {
                    var responsesConn = connection
                    responsesConn.wireAPI = .responses
                    return try await completeResponses(
                        system: system, user: user, connection: responsesConn, key: key)
                }
                return try await completeOpenAI(
                    system: system, user: user, connection: connection, key: key, allowResponsesUpgrade: true)
            }
        case .anthropic:
            let request = try buildRequest(
                system: system, user: user, connection: connection, key: key,
                adaptations: .default(for: .anthropic))
            let data = try await transport.send(request)
            return try parse(data, provider: .anthropic)
        case .gemini:
            return try await completeGemini(system: system, user: user, connection: connection, key: key)
        }
    }

    // Gemini has no structured unsupported-parameter error to key a remediation loop on, but a model that
    // rejects thinkingConfig (e.g. one that takes thinkingBudget instead of thinkingLevel) must not break
    // every rewrite permanently. On a 400 with thinkingConfig in the payload, retry once without it and
    // remember only if the retry succeeds — a 400 with an unrelated cause fails again identically and
    // caches nothing.
    private func completeGemini(system: String, user: String, connection: Connection, key: String?) async throws -> String {
        let cacheKey = adaptationCacheKey(for: connection)
        let adaptations = await adaptationCache.lookup(cacheKey) ?? .default(for: .gemini)
        let request = try buildRequest(
            system: system, user: user, connection: connection, key: key, adaptations: adaptations)
        do {
            return try parse(try await transport.send(request), provider: .gemini)
        } catch let ProviderTransportError.http(status, body) where status == 400 {
            guard adaptations.includeThinkingConfig, connection.params.geminiThinkingLevel != nil else {
                throw ProviderTransportError.http(status, body: body)
            }
            var next = adaptations
            next.includeThinkingConfig = false
            let retry = try buildRequest(
                system: system, user: user, connection: connection, key: key, adaptations: next)
            let output = try parse(try await transport.send(retry), provider: .gemini)
            await adaptationCache.remember(next, for: cacheKey)
            return output
        }
    }

    private func completeOpenAI(
        system: String, user: String, connection: Connection, key: String?, allowResponsesUpgrade: Bool
    ) async throws -> String {
        let cacheKey = adaptationCacheKey(for: connection)
        var adaptations = await adaptationCache.lookup(cacheKey) ?? .default(for: connection.provider)
        var attempts = 0
        while true {
            let request = try buildRequest(
                system: system, user: user, connection: connection, key: key, adaptations: adaptations)
            do {
                let data = try await transport.send(request)
                return try parse(data, provider: connection.provider, wireAPI: .chatCompletions)
            } catch let ProviderTransportError.http(status, body) where status == 400 || status == 404 || status == 405 || status == 422 {
                let apiError = OpenAIAPIError.parse(body: body)
                if allowResponsesUpgrade, apiError?.indicatesRequiresResponsesAPI == true {
                    await wireOverrideCache.remember(.responses, for: Self.hostKey(for: connection))
                    var responsesConn = connection
                    responsesConn.wireAPI = .responses
                    return try await completeResponses(
                        system: system, user: user, connection: responsesConn, key: key)
                }
                guard status == 400, attempts < Self.maxRemediations,
                      let apiError, let next = remediatedAdaptations(adaptations, for: apiError) else {
                    throw ProviderTransportError.http(status, body: body)
                }
                adaptations = next
                await adaptationCache.remember(next, for: cacheKey)
                attempts += 1
            }
        }
    }

    private func completeResponses(system: String, user: String, connection: Connection, key: String?) async throws -> String {
        let cacheKey = adaptationCacheKey(for: connection)
        var adaptations = await adaptationCache.lookup(cacheKey) ?? .default(for: connection.provider)
        var attempts = 0
        while true {
            let request = try buildRequest(
                system: system, user: user, connection: connection, key: key, adaptations: adaptations)
            do {
                let data = try await transport.send(request)
                return try parse(data, provider: connection.provider, wireAPI: .responses)
            } catch let ProviderTransportError.http(status, body) where status == 400 || status == 404 || status == 405 || status == 422 {
                let apiError = OpenAIAPIError.parse(body: body)
                if apiError?.indicatesRequiresChatCompletionsAPI == true {
                    await wireOverrideCache.remember(.chatCompletions, for: Self.hostKey(for: connection))
                    var chatConnection = connection
                    chatConnection.wireAPI = .chatCompletions
                    return try await completeOpenAI(
                        system: system, user: user, connection: chatConnection, key: key, allowResponsesUpgrade: false)
                }
                guard status == 400, attempts < Self.maxRemediations,
                      let apiError, let next = remediatedAdaptations(adaptations, for: apiError) else {
                    throw ProviderTransportError.http(status, body: body)
                }
                adaptations = next
                await adaptationCache.remember(next, for: cacheKey)
                attempts += 1
            }
        }
    }

    // Adaptations are what a specific SERVER accepts (temperature support, token-limit field name,
    // system-fold). Editing a connection's base URL points it at a different server, so the base URL is
    // part of the identity — keying on id+model alone would replay adaptations learned from the old host.
    private func adaptationCacheKey(for connection: Connection) -> String {
        [connection.id, connection.model, connection.baseUrl ?? "", connection.wireAPI.rawValue]
            .joined(separator: "\n")
    }

    static func hostKey(for connection: Connection) -> String {
        WireAPIOverrideCache.key(for: connection)
    }

    private func buildRequest(
        system: String, user: String, connection: Connection, key: String?, adaptations: RequestAdaptations
    ) throws -> URLRequest {
        let temp = connection.params.temperature
        let maxTokens = connection.params.maxTokens

        switch connection.provider {
        case .openai, .openaiCompatible:
            let base = connection.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines).removingTrailingSlash
                ?? (connection.provider == .openai ? "https://api.openai.com/v1" : nil)
            let endpoint = connection.wireAPI == .responses ? "/responses" : "/chat/completions"
            guard let base, !base.isEmpty, let url = URL(string: base + endpoint) else {
                throw ProviderTransportError.missingBaseURL
            }
            var req = jsonRequest(url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            applyOpenRouterHeaders(to: &req, host: url.host())
            if connection.wireAPI == .responses {
                let reasoningEffort = adaptations.includeReasoningEffort ? connection.params.reasoningEffort : nil
                // Reasoning tokens are billed against max_output_tokens on Responses, so a reasoning model
                // needs the same safety floor the Chat path applies — otherwise reasoning can consume the
                // whole budget and the reply comes back status:"incomplete".
                let usesReasoning = reasoningEffort.map { $0.lowercased() != "none" } ?? false
                let reasoningModel = adaptations.indicatesReasoningModel || usesReasoning
                let sizedTokens = reasoningModel ? reasoningSafeMaxTokens(maxTokens) : maxTokens
                var payload: [String: Any] = [
                    "model": connection.model,
                    "instructions": system,
                    "input": user,
                    "max_output_tokens": sizedTokens,
                ]
                payload["store"] = false
                if let reasoningEffort { payload["reasoning"] = ["effort": reasoningEffort] }
                req.httpBody = try body(payload)
                return req
            }
            let sizedTokens = adaptations.indicatesReasoningModel ? reasoningSafeMaxTokens(maxTokens) : maxTokens
            var payload: [String: Any] = [
                "model": connection.model,
                adaptations.tokenLimitField.jsonKey: sizedTokens,
                "messages": chatMessages(system: system, user: user, fold: adaptations.foldSystemIntoUser),
            ]
            if adaptations.includeTemperature { payload["temperature"] = temp }
            if adaptations.includeReasoningEffort, let reasoningEffort = connection.params.reasoningEffort {
                payload["reasoning_effort"] = reasoningEffort
            }
            req.httpBody = try body(payload)
            return req

        case .anthropic:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw ProviderTransportError.badResponse }
            var req = jsonRequest(url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            req.httpBody = try body([
                "model": connection.model,
                "max_tokens": maxTokens,
                "temperature": temp,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ])
            return req

        case .gemini:
            let base = "https://generativelanguage.googleapis.com/v1beta/models"
            guard let key, let url = URL(string: "\(base)/\(connection.model):generateContent") else {
                throw ProviderTransportError.badResponse
            }
            var req = jsonRequest(url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            var generationConfig: [String: Any] = [
                "temperature": temp,
                "maxOutputTokens": maxTokens,
            ]
            if adaptations.includeThinkingConfig, let thinkingLevel = connection.params.geminiThinkingLevel {
                generationConfig["thinkingConfig"] = ["thinkingLevel": thinkingLevel]
            }
            req.httpBody = try body([
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": user]]]],
                "generationConfig": generationConfig,
            ])
            return req
        }
    }

    private func chatMessages(system: String, user: String, fold: Bool) -> [[String: String]] {
        guard fold else {
            return [["role": "system", "content": system], ["role": "user", "content": user]]
        }
        let combined = system.isEmpty ? user : system + "\n\n" + user
        return [["role": "user", "content": combined]]
    }

    private func applyOpenRouterHeaders(to req: inout URLRequest, host: String?) {
        guard let host = host?.lowercased(),
              host == "openrouter.ai" || host.hasSuffix(".openrouter.ai") else { return }
        req.setValue(Self.openRouterReferer, forHTTPHeaderField: "HTTP-Referer")
        req.setValue(Branding.appName, forHTTPHeaderField: "X-Title")
    }

    private static let openRouterReferer = "https://keyscribe.app"

    private func parse(
        _ data: Data, provider: Connection.Provider, wireAPI: Connection.WireAPI = .chatCompletions
    ) throws -> String {
        // A proxy fronting another backend can wrap the whole payload in a single-element top-level array
        // (`[{...}]`), the same shape it uses for errors. Unwrap it so a success body is read, not rejected.
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = Self.responseObject(root) else {
            throw ProviderTransportError.badResponse
        }
        switch provider {
        case .openai, .openaiCompatible:
            if json["error"] is [String: Any] {
                throw ProviderTransportError.http(400, body: String(data: data, encoding: .utf8))
            }
            if wireAPI == .responses {
                return try responsesText(from: json)
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let message = choice["message"] as? [String: Any],
                  let content = Self.messageText(message["content"]) else { throw ProviderTransportError.badResponse }
            // A response cut off at max_tokens passes the gate when no sentinels were issued (common
            // privacy-off case), pasting half a sentence. Treat truncation as an error → local fallback.
            if (choice["finish_reason"] as? String) == "length" { throw ProviderTransportError.truncated }
            guard let cleaned = ReasoningOutput.clean(content) else { throw ProviderTransportError.badResponse }
            return cleaned
        case .anthropic:
            if (json["stop_reason"] as? String) == "max_tokens" { throw ProviderTransportError.truncated }
            guard let content = json["content"] as? [[String: Any]],
                  let text = anthropicText(from: content) else { throw ProviderTransportError.badResponse }
            return text
        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let candidate = candidates.first,
                  let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw ProviderTransportError.badResponse }
            // Join every text part, not just the first — Gemini can split the reply across parts (or lead
            // with a non-text part), and reading `parts.first` alone would drop or miss the answer.
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw ProviderTransportError.badResponse }
            if (candidate["finishReason"] as? String) == "MAX_TOKENS" { throw ProviderTransportError.truncated }
            return text
        }
    }

    // The response object, whether the body is a plain `{...}` or wrapped in a single-element top-level
    // array `[{...}]` (a proxy normalizing another backend). Mirrors OpenAIAPIError's error-object unwrap.
    private static func responseObject(_ root: Any) -> [String: Any]? {
        if let object = root as? [String: Any] { return object }
        if let array = root as? [Any], let first = array.first { return responseObject(first) }
        return nil
    }

    // OpenAI `content` is normally a string, but some compatible servers and proxies (normalizing from
    // Anthropic/Gemini) return it as an array of typed parts — `[{"type":"text","text":"…"}]`. Accept both,
    // so a parts-shaped reply isn't rejected as a bad response and silently dropped to local.
    private static func messageText(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private func responsesText(from json: [String: Any]) throws -> String {
        if (json["status"] as? String) == "incomplete" { throw ProviderTransportError.truncated }
        guard (json["status"] as? String) == "completed",
              let output = json["output"] as? [[String: Any]] else {
            throw ProviderTransportError.badResponse
        }
        let text = output
            .filter { ($0["type"] as? String) == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { ($0["type"] as? String) == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let cleaned = ReasoningOutput.clean(text) else { throw ProviderTransportError.badResponse }
        return cleaned
    }

    private func anthropicText(from blocks: [[String: Any]]) -> String? {
        let joined = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        if !joined.isEmpty { return joined }
        return blocks.compactMap { $0["text"] as? String }.first
    }

    private func jsonRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func body(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }
}
