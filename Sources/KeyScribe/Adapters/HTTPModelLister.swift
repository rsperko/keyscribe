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

    func listModels(for connection: Connection, apiKey: String?) async throws -> [String] {
        let storedKey = try await credential(for: connection, apiKey: apiKey)
        let request = try request(for: connection, key: storedKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelListError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw ModelListError.http(http.statusCode) }
        return try parse(data, provider: connection.provider)
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

    private func request(for connection: Connection, key: String?) throws -> URLRequest {
        switch connection.provider {
        case .openai, .anthropic, .gemini:
            guard let key, !key.isEmpty else { throw ModelListError.missingKey(connection.keyRef) }
            return try hostedRequest(for: connection.provider, key: key)
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

    private func hostedRequest(for provider: Connection.Provider, key: String) throws -> URLRequest {
        switch provider {
        case .openai:
            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return req
        case .anthropic:
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return req
        case .gemini:
            return URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)")!)
        case .openaiCompatible:
            throw ModelListError.missingBaseURL
        }
    }

    private func parse(_ data: Data, provider: Connection.Provider) throws -> [String] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelListError.badResponse
        }
        switch provider {
        case .openai, .openaiCompatible, .anthropic:
            guard let data = json["data"] as? [[String: Any]] else { throw ModelListError.badResponse }
            return data.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }.orderedUnique
        case .gemini:
            guard let models = json["models"] as? [[String: Any]] else { throw ModelListError.badResponse }
            return models.compactMap { model -> String? in
                let methods = model["supportedGenerationMethods"] as? [String]
                guard methods?.contains("generateContent") == true else { return nil }
                if let base = model["baseModelId"] as? String, !base.isEmpty { return base }
                if let name = model["name"] as? String, !name.isEmpty {
                    return name.replacingOccurrences(of: "models/", with: "")
                }
                return nil
            }.orderedUnique
        }
    }
}

private extension String {
    var removingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

private extension Array where Element == String {
    var orderedUnique: [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
