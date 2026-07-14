import Foundation
import KeyScribeKit

enum ProviderTransportError: Error, CustomStringConvertible, LocalizedError {
    case missingKey(String)
    case keychainDenied(String, status: Int32)
    case missingBaseURL
    case http(Int, body: String?)
    case badResponse
    case truncated

    // Routes `description` through localizedDescription so a caught rewrite error carries the real cause
    // into logs and history, instead of the generic "The operation couldn't be completed" a bare Error yields.
    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .missingKey(let ref): return "No API key stored for \(ref)."
        case .keychainDenied(let ref, _):
            return "The keychain would not release the API key for \(ref) — it may be locked or access was denied. Unlock your login keychain or re-authorize the key."
        case .missingBaseURL: return "This connection needs a base URL."
        case .http(let code, let body):
            // The stored body is the full provider payload (kept parseable for OpenAIAPIError.parse and the
            // remediation loop); truncate only here, at display time.
            if let body, let snippet = ProviderTransport.errorSnippet(from: Data(body.utf8)) {
                return "The model service returned an error (\(code)): \(snippet)"
            }
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
        do {
            return try await attempt(request)
        } catch let error where Self.isTransient(error) {
            // One quick retry, not exponential backoff: dictation is commit-on-release, so a persistent
            // failure must fall back to the local transcript promptly, not stall the insert on a retry ladder.
            try? await Task.sleep(for: Self.quickRetryDelay)
            return try await attempt(request)
        }
    }

    static let quickRetryDelay: Duration = .milliseconds(250)

    private func attempt(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderTransportError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderTransportError.http(http.statusCode, body: Self.errorBody(from: data))
        }
        return data
    }

    // Retry only genuinely transient failures. Not 4xx (deterministic — a 400 goes through param
    // remediation instead), not timeouts (already waited the full request window), not offline (won't
    // recover in 250 ms) — those fall straight back to the local transcript.
    static func isTransient(_ error: Error) -> Bool {
        if case ProviderTransportError.http(let code, _) = error { return (500...599).contains(code) }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed: return true
            default: return false
            }
        }
        return false
    }

    // Trimmed but NOT truncated: the error machinery (OpenAIAPIError.parse, the 400-remediation loop,
    // model-not-found detection) needs valid JSON, so a >1000-char body must stay parseable. This is the
    // provider's response body — never user content.
    static func errorBody(from data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func errorSnippet(from data: Data, limit: Int = 300) -> String? {
        errorBody(from: data).map { $0.count > limit ? String($0.prefix(limit)) + "…" : $0 }
    }
}
