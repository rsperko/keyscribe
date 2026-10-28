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
        try await listModelDetails(for: connection, apiKey: apiKey).map(\.id)
    }

    // Reasoning support is read only where a service publishes it per model; elsewhere it stays unknown,
    // which Settings reports as unverified rather than guessing.
    func listModelDetails(for connection: Connection, apiKey: String?) async throws -> [ModelListing] {
        let storedKey = try await transport.credential(for: connection, apiKey: apiKey)
        var listings: [ModelListing] = []
        var pageToken: String?
        var pages = 0
        repeat {
            let request = try request(for: connection, key: storedKey, pageToken: pageToken)
            let data = try await transport.send(request)
            let page = try parsePage(data, provider: connection.provider)
            listings.append(contentsOf: page.listings)
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < Self.maxPages
        var seen = Set<String>()
        return listings.filter { seen.insert($0.id).inserted }
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
        let listings: [ModelListing]
        let nextPageToken: String?
    }

    private func parsePage(_ data: Data, provider: Connection.Provider) throws -> Page {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderTransportError.badResponse
        }
        switch provider {
        case .openai, .openaiCompatible:
            guard let data = json["data"] as? [[String: Any]] else { throw ProviderTransportError.badResponse }
            let listings = data.compactMap { entry -> ModelListing? in
                guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                return ModelListing(id: id, reasoning: ModelReasoningSupport.openRouter(entry))
            }
            return Page(listings: listings, nextPageToken: nil)
        case .anthropic:
            guard let data = json["data"] as? [[String: Any]] else { throw ProviderTransportError.badResponse }
            let listings = data.compactMap { entry -> ModelListing? in
                guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                return ModelListing(id: id, reasoning: ModelReasoningSupport.anthropic(entry))
            }
            let hasMore = json["has_more"] as? Bool ?? false
            let lastId = (json["last_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Page(listings: listings, nextPageToken: hasMore ? lastId : nil)
        case .gemini:
            guard let models = json["models"] as? [[String: Any]] else { throw ProviderTransportError.badResponse }
            let listings = models.compactMap { model -> ModelListing? in
                let methods = model["supportedGenerationMethods"] as? [String]
                guard methods?.contains("generateContent") == true else { return nil }
                let id: String
                if let base = model["baseModelId"] as? String, !base.isEmpty {
                    id = base
                } else if let name = model["name"] as? String, !name.isEmpty {
                    id = name.replacingOccurrences(of: "models/", with: "")
                } else {
                    return nil
                }
                return ModelListing(id: id, reasoning: ModelReasoningSupport.gemini(model))
            }
            let nextPageToken = (json["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Page(listings: listings, nextPageToken: nextPageToken)
        }
    }
}
