import Foundation
import KeyScribeKit

// Thin BYOK transport over the OpenAI / Anthropic / Gemini HTTP APIs (design.md §5). Key fetched from
// Keychain by the connection's key_ref. Provider-agnostic orchestration (assemble → gate → retry/fallback)
// lives in KeyScribeKit.RewriteService.
struct HTTPLLMClient: LLMClient {
    // Bounded session, not URLSession.shared (60s default, doubled by the gate's stricter-retry). A hung
    // BYOK endpoint must fall back to the local transcript promptly, so cap each attempt.
    var session: URLSession = ProviderTransport.makeSession(requestTimeout: 30, resourceTimeout: 45)
    var keyProvider: @Sendable (String) -> String? = { KeychainStore.get($0) }
    var tokenCommandRunner: @Sendable (String) async throws -> String = { try await TokenCommandRunner.run($0) }
    var tokenCache: TokenCommandCache = .shared
    var now: @Sendable () -> Date = { Date() }

    private var transport: ProviderTransport {
        ProviderTransport(session: session, keyProvider: keyProvider,
                          tokenCommandRunner: tokenCommandRunner, tokenCache: tokenCache, now: now)
    }

    func complete(system: String, user: String, connection: Connection) async throws -> String {
        let key = try await transport.credential(for: connection)
        if connection.provider != .openaiCompatible, key?.isEmpty != false {
            throw ProviderTransportError.missingKey(connection.keyRef)
        }
        let request = try buildRequest(system: system, user: user, connection: connection, key: key)
        let data = try await transport.send(request)
        return try parse(data, provider: connection.provider)
    }

    private func buildRequest(system: String, user: String, connection: Connection, key: String?) throws -> URLRequest {
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
            let tokenLimitKey = usesHostedOpenAIParameterNames(provider: connection.provider, baseURL: base)
                ? "max_completion_tokens"
                : "max_tokens"
            req.httpBody = try body([
                "model": connection.model,
                "temperature": temp,
                tokenLimitKey: maxTokens,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ])
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
            req.httpBody = try body([
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": user]]]],
                "generationConfig": ["temperature": temp, "maxOutputTokens": maxTokens],
            ])
            return req
        }
    }

    private func usesHostedOpenAIParameterNames(provider: Connection.Provider, baseURL: String) -> Bool {
        if provider == .openai { return true }
        guard provider == .openaiCompatible, let host = URL(string: baseURL)?.host()?.lowercased() else {
            return false
        }
        return host == "api.openai.com"
    }

    private func parse(_ data: Data, provider: Connection.Provider) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderTransportError.badResponse
        }
        switch provider {
        case .openai, .openaiCompatible:
            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let message = choice["message"] as? [String: Any],
                  let content = message["content"] as? String else { throw ProviderTransportError.badResponse }
            // A response cut off at max_tokens passes the gate when no sentinels were issued (common
            // privacy-off case), pasting half a sentence. Treat truncation as an error → local fallback.
            if (choice["finish_reason"] as? String) == "length" { throw ProviderTransportError.truncated }
            return content
        case .anthropic:
            if (json["stop_reason"] as? String) == "max_tokens" { throw ProviderTransportError.truncated }
            guard let content = json["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else { throw ProviderTransportError.badResponse }
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
