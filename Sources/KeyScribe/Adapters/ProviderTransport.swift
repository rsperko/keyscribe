import Foundation
import KeyScribeKit

enum ProviderTransportError: Error, CustomStringConvertible, LocalizedError {
    case missingKey(String)
    case keychainDenied(String, status: Int32)
    case missingBaseURL
    case http(Int, body: String?)
    case badResponse
    case truncated
    case limitBeforeAnswer(reasoningEvidence: Bool)
    case incompleteReply
    case reasoningLevelRefused(String)
    case noRouteForReasoningLevel(String)

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
        case .badResponse, .truncated, .limitBeforeAnswer, .incompleteReply, .reasoningLevelRefused, .noRouteForReasoningLevel:
            return rewriteFailureReason
        }
    }
}

// `description` above is for ephemeral UI (Settings, first run), where showing the provider's own message
// helps a user fix a misconfigured connection. History and the public log are a different boundary: a
// compatible endpoint or proxy can echo request content into an error body, so the persisted reason is built
// from the status code alone (KS-07). The body stays in the associated value for OpenAIAPIError.parse and the
// remediation loop — in memory only.
extension ProviderTransportError: RewriteFailureReporting {
    var rewriteFailureReason: String {
        switch self {
        case .missingKey: return "No API key is stored for this connection."
        case .keychainDenied: return "The keychain would not release the API key."
        case .missingBaseURL: return "This connection needs a base URL."
        case .http(let code, _): return "The model service returned an error (\(code))."
        case .badResponse: return "The model service returned an unexpected response."
        case .truncated: return "The model service cut the response off at its length limit."
        case .limitBeforeAnswer(true):
            return "The model reached its output limit while reasoning, before writing an answer. Lower Reasoning or raise Minimum output allowance in Settings."
        case .limitBeforeAnswer(false):
            return "The reply hit the output limit before any answer text. Raise Minimum output allowance or lower Reasoning in Settings."
        case .incompleteReply: return "The model service returned an incomplete reply."
        case .reasoningLevelRefused(let level):
            return "This model doesn't accept the reasoning level “\(ReasoningReport.displayName(level))”. Change it in Settings."
        case .noRouteForReasoningLevel(let level):
            return "No provider for this model accepts every setting sent, including the reasoning level “\(ReasoningReport.displayName(level))”. Choose another level or Recommended in Settings."
        }
    }
}

// URLError's copy is Foundation's own ("The Internet connection appears to be offline."), derived from the
// transport state rather than from any response the endpoint controls.
extension URLError: RewriteFailureReporting {
    public var rewriteFailureReason: String { localizedDescription }
}

// Refuses any redirect that leaves the origin the request was aimed at. Attached PER TASK, not to the
// session: one session is shared across connections with different base URLs, so a session-wide delegate
// would have no single origin to pin. Returning nil from the redirect callback declines the redirect and
// surfaces the 3xx response instead of following it.
final class OriginPinnedRedirects: NSObject, URLSessionTaskDelegate {
    private let pinned: RequestOrigin?

    init(_ url: URL?) { pinned = RequestOrigin(url) }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard RequestOrigin.redirectIsPermitted(from: pinned, to: request.url) else {
            Log.models.error("refused cross-origin redirect from a provider endpoint")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct ProviderTransport: Sendable {
    var session: URLSession
    var keyProvider: @Sendable (String) -> SecretLookup
    var tokenCommandRunner: @Sendable (String) async throws -> String
    var tokenCache: TokenCommandCache
    var now: @Sendable () -> Date
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

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

    // A longer server ask falls back at once rather than holding the dictation.
    static let maxRetries = 2
    static let backoff: [Duration] = [.milliseconds(500), .seconds(1)]
    static let longestServerWaitSeconds: Double = 10

    func send(_ request: URLRequest) async throws -> Data {
        var retry = 0
        while true {
            do {
                return try await attempt(request)
            } catch let failure as HTTPFailure {
                guard let wait = Self.retryWait(
                    for: failure.error, serverAskedSeconds: failure.retryAfterSeconds, retry: retry)
                else { throw failure.error }
                try await sleep(wait)
            } catch {
                guard let wait = Self.retryWait(for: error, serverAskedSeconds: nil, retry: retry) else { throw error }
                try await sleep(wait)
            }
            retry += 1
        }
    }

    // The server's ask is compared as a Double BEFORE it becomes a Duration: converting an enormous value
    // traps, and a header is untrusted input.
    static func retryWait(
        for error: Error, serverAskedSeconds: Double?, retry: Int, jitter: Double = .random(in: 0.75...1)
    ) -> Duration? {
        guard retry < maxRetries, isTransient(error) else { return nil }
        if let asked = serverAskedSeconds { return asked <= longestServerWaitSeconds ? .seconds(asked) : nil }
        return backoff[min(retry, backoff.count - 1)] * jitter
    }

    private struct HTTPFailure: Error {
        let error: ProviderTransportError
        let retryAfterSeconds: Double?
    }

    private func attempt(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request, delegate: OriginPinnedRedirects(request.url))
        guard let http = response as? HTTPURLResponse else { throw ProviderTransportError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPFailure(
                error: .http(http.statusCode, body: Self.errorBody(from: data)),
                retryAfterSeconds: serverWaitSeconds(http))
        }
        return data
    }

    // `retry-after-ms`, then `Retry-After` as seconds or an HTTP date (RFC 9110 §10.2.3). Infinity is kept
    // (it reads as "too long"); NaN, a negative, or anything unparseable is ignored for the normal backoff.
    func serverWaitSeconds(_ response: HTTPURLResponse) -> Double? {
        if let ms = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init), ms >= 0 {
            return ms / 1000
        }
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value) { return seconds >= 0 ? seconds : nil }
        guard let date = Self.httpDate(value) else { return nil }
        return max(0, date.timeIntervalSince(now()))
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    // Temporary: the request timed out at the server, conflicted, was rate limited, or hit a server error
    // (Anthropic's 529 "overloaded" included), or the connection dropped before an answer. Every other 4xx
    // is deterministic — a 400 goes through param remediation instead. A local timeout is not retried: the
    // rewrite already waited out its window, and the server may have done the work.
    static func isTransient(_ error: Error) -> Bool {
        if case ProviderTransportError.http(let code, _) = error {
            return code == 408 || code == 409 || code == 429 || (500...599).contains(code)
        }
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
