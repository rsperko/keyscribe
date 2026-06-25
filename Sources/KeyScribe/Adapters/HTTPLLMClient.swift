import Foundation
import KeyScribeKit

enum LLMClientError: Error, CustomStringConvertible {
    case missingKey(String)
    case http(Int)
    case badResponse
    case missingBaseURL

    var description: String {
        switch self {
        case .missingKey(let ref): return "No API key stored for \(ref)."
        case .http(let code): return "The model service returned an error (\(code))."
        case .badResponse: return "The model service returned an unexpected response."
        case .missingBaseURL: return "This connection needs a base URL."
        }
    }
}

// Thin BYOK client over the OpenAI / Anthropic / Gemini HTTP APIs (design.md §5). The key is
// fetched from the Keychain by the connection's key_ref. Provider-agnostic orchestration
// (assemble → gate → retry/fallback) lives in KeyScribeKit.RewriteService; this only does transport.
// Runtime-unverified without a real key — flagged in docs/session-status.md.
struct HTTPLLMClient: LLMClient {
    // A bounded session, not URLSession.shared (whose default request timeout is 60s — and the gate's
    // stricter-retry would double that). A hung BYOK endpoint must fall back to the local transcript
    // promptly, so cap each attempt; RewriteService turns the thrown timeout into a local fallback.
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    var keyProvider: @Sendable (String) -> String? = { KeychainStore.get($0) }

    func complete(system: String, user: String, connection: Connection) async throws -> String {
        let key = keyProvider(connection.keyRef)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if connection.provider != .openaiCompatible, key?.isEmpty != false {
            throw LLMClientError.missingKey(connection.keyRef)
        }
        let request = try buildRequest(system: system, user: user, connection: connection, key: key)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMClientError.http(http.statusCode)
        }
        return try parse(data, provider: connection.provider)
    }

    private func buildRequest(system: String, user: String, connection: Connection, key: String?) throws -> URLRequest {
        let temp = connection.params.temperature
        let maxTokens = connection.params.maxTokens

        switch connection.provider {
        case .openai, .openaiCompatible:
            let base = connection.baseUrl ?? (connection.provider == .openai ? "https://api.openai.com/v1" : nil)
            guard let base, let url = URL(string: base + "/chat/completions") else { throw LLMClientError.missingBaseURL }
            var req = jsonRequest(url)
            if let key, !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try body([
                "model": connection.model,
                "temperature": temp,
                "max_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ])
            return req

        case .anthropic:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw LLMClientError.badResponse }
            var req = jsonRequest(url)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
            guard let key, let url = URL(string: "\(base)/\(connection.model):generateContent?key=\(key)") else {
                throw LLMClientError.badResponse
            }
            var req = jsonRequest(url)
            req.httpBody = try body([
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": user]]]],
                "generationConfig": ["temperature": temp, "maxOutputTokens": maxTokens],
            ])
            return req
        }
    }

    private func parse(_ data: Data, provider: Connection.Provider) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMClientError.badResponse
        }
        switch provider {
        case .openai, .openaiCompatible:
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { throw LLMClientError.badResponse }
            return content
        case .anthropic:
            guard let content = json["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else { throw LLMClientError.badResponse }
            return text
        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else { throw LLMClientError.badResponse }
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
