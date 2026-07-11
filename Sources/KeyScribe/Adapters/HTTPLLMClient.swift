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
    var now: @Sendable () -> Date = { Date() }

    private static let maxRemediations = 4

    private var transport: ProviderTransport {
        ProviderTransport(session: session, keyProvider: keyProvider,
                          tokenCommandRunner: tokenCommandRunner, tokenCache: tokenCache, now: now)
    }

    // Open the pooled connection to the host (no auth, no body) so a rewrite moments later reuses it.
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
            return try await completeOpenAI(system: system, user: user, connection: connection, key: key)
        case .anthropic, .gemini:
            let request = try buildRequest(
                system: system, user: user, connection: connection, key: key,
                adaptations: .default(for: connection.provider))
            let data = try await transport.send(request)
            return try parse(data, provider: connection.provider)
        }
    }

    private func completeOpenAI(system: String, user: String, connection: Connection, key: String?) async throws -> String {
        let cacheKey = adaptationCacheKey(for: connection)
        var adaptations = await adaptationCache.lookup(cacheKey) ?? .default(for: connection.provider)
        var attempts = 0
        while true {
            let request = try buildRequest(
                system: system, user: user, connection: connection, key: key, adaptations: adaptations)
            do {
                let data = try await transport.send(request)
                return try parse(data, provider: connection.provider)
            } catch let ProviderTransportError.http(status, body) where status == 400 {
                guard attempts < Self.maxRemediations,
                      let apiError = OpenAIAPIError.parse(body: body),
                      let next = remediatedAdaptations(adaptations, for: apiError) else {
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
        [connection.id, connection.model, connection.baseUrl ?? ""].joined(separator: "\n")
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
            guard let base, !base.isEmpty, let url = URL(string: base + "/chat/completions") else {
                throw ProviderTransportError.missingBaseURL
            }
            var req = jsonRequest(url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            applyOpenRouterHeaders(to: &req, host: url.host())
            let sizedTokens = adaptations.indicatesReasoningModel ? reasoningSafeMaxTokens(maxTokens) : maxTokens
            var payload: [String: Any] = [
                "model": connection.model,
                adaptations.tokenLimitField.jsonKey: sizedTokens,
                "messages": chatMessages(system: system, user: user, fold: adaptations.foldSystemIntoUser),
            ]
            if adaptations.includeTemperature { payload["temperature"] = temp }
            if let reasoningEffort = connection.params.reasoningEffort {
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
            if let thinkingLevel = connection.params.geminiThinkingLevel {
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

    private func parse(_ data: Data, provider: Connection.Provider) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderTransportError.badResponse
        }
        switch provider {
        case .openai, .openaiCompatible:
            if json["error"] is [String: Any] {
                throw ProviderTransportError.http(400, body: String(data: data, encoding: .utf8))
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let message = choice["message"] as? [String: Any],
                  let content = message["content"] as? String else { throw ProviderTransportError.badResponse }
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
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else { throw ProviderTransportError.badResponse }
            if (candidate["finishReason"] as? String) == "MAX_TOKENS" { throw ProviderTransportError.truncated }
            return text
        }
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
