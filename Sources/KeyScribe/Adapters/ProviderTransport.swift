import Foundation
import KeyScribeKit

enum ProviderTransportError: Error, CustomStringConvertible {
    case missingKey(String)
    case keychainDenied(String, status: Int32)
    case missingBaseURL
    case http(Int, body: String?)
    case badResponse
    case truncated

    var description: String {
        switch self {
        case .missingKey(let ref): return "No API key stored for \(ref)."
        case .keychainDenied(let ref, _):
            return "The keychain would not release the API key for \(ref) — it may be locked or access was denied. Unlock your login keychain or re-authorize the key."
        case .missingBaseURL: return "This connection needs a base URL."
        case .http(let code, let body):
            if let body, !body.isEmpty { return "The model service returned an error (\(code)): \(body)" }
            return "The model service returned an error (\(code))."
        case .badResponse: return "The model service returned an unexpected response."
        case .truncated: return "The model service cut the response off at its length limit."
        }
    }
}

struct ProviderTransport: Sendable {
    var session: URLSession
    var keyProvider: @Sendable (String) -> SecretLookup
    var tokenCommandRunner: @Sendable (String) async throws -> String
    var tokenCache: TokenCommandCache
    var now: @Sendable () -> Date

    static func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    func credential(for connection: Connection, apiKey: String? = nil) async throws -> String? {
        switch connection.authMethod {
        case .none:
            return nil
        case .apiKey:
            if let override = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
                return override
            }
            switch keyProvider(connection.keyRef) {
            case .found(let secret): return secret.trimmingCharacters(in: .whitespacesAndNewlines)
            case .absent: return nil
            case .denied(let status): throw ProviderTransportError.keychainDenied(connection.keyRef, status: status)
            }
        case .tokenCommand:
            guard let command = connection.tokenCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                throw TokenCommandError.emptyCommand
            }
            return try await tokenCache.token(forKey: command, now: now()) {
                try await tokenCommandRunner(command)
            }
        }
    }

    func applyAuth(_ key: String?, for provider: Connection.Provider, to req: inout URLRequest) {
        switch provider {
        case .openai, .openaiCompatible:
            if let key, !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderTransportError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderTransportError.http(http.statusCode, body: Self.errorSnippet(from: data, limit: 1000))
        }
        return data
    }

    // Length-capped snippet of the provider's error payload so a failure shows the provider's own message
    // (e.g. "invalid model") instead of a bare status code. Provider's response body, never user content.
    static func errorSnippet(from data: Data, limit: Int = 300) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
