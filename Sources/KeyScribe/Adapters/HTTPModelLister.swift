import Foundation
import KeyScribeKit

enum ModelListError: Error, CustomStringConvertible {
    case missingKey(String)
    case missingBaseURL
    case http(Int)
    case badResponse

    var description: String {
        switch self {
        case .missingKey(let ref): return "No API key stored for \(ref)."
        case .missingBaseURL: return "This connection needs a base URL."
        case .http(let code): return "The model service returned an error (\(code))."
        case .badResponse: return "The model service returned an unexpected model list."
        }
    }
}

struct HTTPModelLister {
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    var keyProvider: @Sendable (String) -> String? = { KeychainStore.get($0) }
    var tokenCommandRunner: @Sendable (String) async throws -> String = { try await TokenCommandRunner.run($0) }
    var tokenCache: TokenCommandCache = .shared
    var now: @Sendable () -> Date = { Date() }

    private static let maxPages = 20

    func listModels(for connection: Connection, apiKey: String?) async throws -> [String] {
        let storedKey = try await credential(for: connection, apiKey: apiKey)
        var ids: [String] = []
        var pageToken: String?
        var pages = 0
        repeat {
            let request = try request(for: connection, key: storedKey, pageToken: pageToken)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ModelListError.badResponse }
            guard (200..<300).contains(http.statusCode) else { throw ModelListError.http(http.statusCode) }
            let page = try parsePage(data, provider: connection.provider)
            ids.append(contentsOf: page.ids)
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < Self.maxPages
        return ids.orderedUnique
    }

    private func credential(for connection: Connection, apiKey: String?) async throws -> String? {
        switch connection.authMethod {
        case .none:
            return nil
        case .apiKey:
            let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            return key?.isEmpty == false ? key : keyProvider(connection.keyRef)
        case .tokenCommand:
            guard let command = connection.tokenCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                throw TokenCommandError.emptyCommand
            }
            return try await tokenCache.token(forKey: command, now: now()) {
                try await tokenCommandRunner(command)
            }
        }
    }

    private func request(for connection: Connection, key: String?, pageToken: String?) throws -> URLRequest {
        switch connection.provider {
        case .openai, .anthropic, .gemini:
            guard let key, !key.isEmpty else { throw ModelListError.missingKey(connection.keyRef) }
            return try hostedRequest(for: connection.provider, key: key, pageToken: pageToken)
        case .openaiCompatible:
            let base = connection.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !base.isEmpty, let url = URL(string: base.removingTrailingSlash + "/models") else {
                throw ModelListError.missingBaseURL
            }
            var req = URLRequest(url: url)
            if let key, !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            return req
        }
    }

    private func hostedRequest(for provider: Connection.Provider, key: String, pageToken: String?) throws -> URLRequest {
        switch provider {
        case .openai:
            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return req
        case .anthropic:
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "after_id", value: pageToken))
            }
            guard let url = components.url else { throw ModelListError.badResponse }
            var req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return req
        case .gemini:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            guard let url = components.url else { throw ModelListError.badResponse }
            var req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            return req
        case .openaiCompatible:
            throw ModelListError.missingBaseURL
        }
    }

    private struct Page {
        let ids: [String]
        let nextPageToken: String?
    }

    private func parsePage(_ data: Data, provider: Connection.Provider) throws -> Page {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelListError.badResponse
        }
        switch provider {
        case .openai, .openaiCompatible:
            guard let data = json["data"] as? [[String: Any]] else { throw ModelListError.badResponse }
            let ids = data.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            return Page(ids: ids, nextPageToken: nil)
        case .anthropic:
            guard let data = json["data"] as? [[String: Any]] else { throw ModelListError.badResponse }
            let ids = data.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            let hasMore = json["has_more"] as? Bool ?? false
            let lastId = (json["last_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Page(ids: ids, nextPageToken: hasMore ? lastId : nil)
        case .gemini:
            guard let models = json["models"] as? [[String: Any]] else { throw ModelListError.badResponse }
            let ids = models.compactMap { model -> String? in
                let methods = model["supportedGenerationMethods"] as? [String]
                guard methods?.contains("generateContent") == true else { return nil }
                if let base = model["baseModelId"] as? String, !base.isEmpty { return base }
                if let name = model["name"] as? String, !name.isEmpty {
                    return name.replacingOccurrences(of: "models/", with: "")
                }
                return nil
            }
            let nextPageToken = (json["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Page(ids: ids, nextPageToken: nextPageToken)
        }
    }
}

private extension Array where Element == String {
    var orderedUnique: [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
