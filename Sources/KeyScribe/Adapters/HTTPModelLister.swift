import Foundation
import KeyScribeKit

struct HTTPModelLister {
    var session: URLSession = ProviderTransport.makeSession(requestTimeout: 10, resourceTimeout: 15)
    var keyProvider: @Sendable (String) -> SecretLookup = { KeychainStore.lookup($0) }
    var tokenCommandRunner: @Sendable (String) async throws -> String = { try await TokenCommandRunner.run($0) }
    var tokenCache: TokenCommandCache = .shared
    var now: @Sendable () -> Date = { Date() }

    private static let maxPages = 20

    private var transport: ProviderTransport {
        ProviderTransport(session: session, keyProvider: keyProvider,
                          tokenCommandRunner: tokenCommandRunner, tokenCache: tokenCache, now: now)
    }

    func listModels(for connection: Connection, apiKey: String?) async throws -> [String] {
        let storedKey = try await transport.credential(for: connection, apiKey: apiKey)
        var ids: [String] = []
        var pageToken: String?
        var pages = 0
        repeat {
            let request = try request(for: connection, key: storedKey, pageToken: pageToken)
            let data = try await transport.send(request)
            let page = try parsePage(data, provider: connection.provider)
            ids.append(contentsOf: page.ids)
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < Self.maxPages
        return ids.orderedUnique
    }

    private func request(for connection: Connection, key: String?, pageToken: String?) throws -> URLRequest {
        switch connection.provider {
        case .openai, .anthropic, .gemini:
            guard let key, !key.isEmpty else { throw ProviderTransportError.missingKey(connection.keyRef) }
            return try hostedRequest(for: connection.provider, key: key, pageToken: pageToken)
        case .openaiCompatible:
            let base = connection.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !base.isEmpty, let url = URL(string: base.removingTrailingSlash + "/models") else {
                throw ProviderTransportError.missingBaseURL
            }
            var req = URLRequest(url: url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            return req
        }
    }

    private func hostedRequest(for provider: Connection.Provider, key: String, pageToken: String?) throws -> URLRequest {
        switch provider {
        case .openai:
            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            transport.applyAuth(key, for: provider, to: &req)
            return req
        case .anthropic:
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "after_id", value: pageToken))
            }
            guard let url = components.url else { throw ProviderTransportError.badResponse }
            var req = URLRequest(url: url)
            transport.applyAuth(key, for: provider, to: &req)
            return req
        case .gemini:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            guard let url = components.url else { throw ProviderTransportError.badResponse }
            var req = URLRequest(url: url)
            transport.applyAuth(key, for: provider, to: &req)
            return req
        case .openaiCompatible:
            throw ProviderTransportError.missingBaseURL
        }
    }

    private struct Page {
        let ids: [String]
        let nextPageToken: String?
    }

    private func parsePage(_ data: Data, provider: Connection.Provider) throws -> Page {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderTransportError.badResponse
        }
        switch provider {
        case .openai, .openaiCompatible:
            guard let data = json["data"] as? [[String: Any]] else { throw ProviderTransportError.badResponse }
            let ids = data.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            return Page(ids: ids, nextPageToken: nil)
        case .anthropic:
            guard let data = json["data"] as? [[String: Any]] else { throw ProviderTransportError.badResponse }
            let ids = data.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            let hasMore = json["has_more"] as? Bool ?? false
            let lastId = (json["last_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Page(ids: ids, nextPageToken: hasMore ? lastId : nil)
        case .gemini:
            guard let models = json["models"] as? [[String: Any]] else { throw ProviderTransportError.badResponse }
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
