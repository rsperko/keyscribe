import Foundation
import TOMLKit

public struct Connection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var provider: Provider
    public var model: String
    public var keyRef: String
    public var baseUrl: String?
    public var authMethod: AuthMethod
    public var tokenCommand: String?
    public var params: Params

    public enum Provider: String, Codable, Sendable {
        case openai, anthropic, gemini
        case openaiCompatible = "openai_compatible"

        public var defaultModel: String {
            switch self {
            case .openai: "gpt-5.4-mini"
            case .anthropic: "claude-haiku-4-5"
            case .gemini: "gemini-2.5-flash"
            case .openaiCompatible: ""
            }
        }

        public var defaultName: String {
            switch self {
            case .openai: "OpenAI"
            case .anthropic: "Anthropic"
            case .gemini: "Gemini"
            case .openaiCompatible: "Custom AI"
            }
        }
    }

    public enum AuthMethod: String, Codable, Sendable {
        case apiKey = "api_key"
        case tokenCommand = "token_command"
        case none
    }

    public struct Params: Codable, Equatable, Sendable {
        public var temperature: Double
        public var maxTokens: Int
        enum CodingKeys: String, CodingKey { case temperature; case maxTokens = "max_tokens" }
        public init(temperature: Double = 0.2, maxTokens: Int = 2048) {
            self.temperature = temperature
            self.maxTokens = maxTokens
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2
            maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 2048
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, provider, model
        case keyRef = "key_ref"
        case baseUrl = "base_url"
        case authMethod = "auth_method"
        case tokenCommand = "token_command"
        case params
    }

    public init(
        id: String, name: String, provider: Provider, model: String,
        keyRef: String, baseUrl: String? = nil, authMethod: AuthMethod? = nil,
        tokenCommand: String? = nil, params: Params = .init()
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.model = model
        self.keyRef = keyRef
        self.baseUrl = baseUrl
        self.authMethod = authMethod ?? (tokenCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? .tokenCommand : .apiKey)
        self.tokenCommand = tokenCommand
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        provider = try c.decode(Provider.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        keyRef = try c.decode(String.self, forKey: .keyRef)
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl)
        tokenCommand = try c.decodeIfPresent(String.self, forKey: .tokenCommand)
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod)
            ?? (tokenCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? .tokenCommand : .apiKey)
        params = try c.decodeIfPresent(Params.self, forKey: .params) ?? .init()
    }
}

extension Connection {
    // A structural misconfiguration detectable without any network call (distinct from a wrong key,
    // which only a Test Connection reveals). Every provider needs a model; an OpenAI-compatible
    // connection also needs a base URL to reach. A missing key is *not* here — it is legitimate for a
    // local/no-auth endpoint.
    public enum ConfigIssue: Equatable, Sendable {
        case missingModel
        case missingBaseURL
        case missingTokenCommand
    }

    public var configIssue: ConfigIssue? {
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingModel }
        if provider == .openaiCompatible,
           (baseUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingBaseURL
        }
        if authMethod == .tokenCommand,
           (tokenCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingTokenCommand
        }
        return nil
    }
}

public struct ConnectionSet: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var connections: [Connection]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case connections = "connection"
    }

    public init(schemaVersion: Int = 1, connections: [Connection] = []) {
        self.schemaVersion = schemaVersion
        self.connections = connections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        connections = try c.decodeIfPresent([Connection].self, forKey: .connections) ?? []
    }

    public func connection(id: String) -> Connection? {
        connections.first { $0.id == id }
    }
}

public enum ConnectionStore {
    public static let currentSchemaVersion = 1
    public static let fileName = "connections.toml"

    public static func decode(from toml: String) throws -> ConnectionSet {
        try ConfigDecode.table(toml, supportedVersion: currentSchemaVersion) {
            try TOMLDecoder().decode(ConnectionSet.self, from: $0)
        }
    }

    public static func loadOrDefault(supportDir: URL) -> ConnectionSet {
        let file = supportDir.appendingPathComponent(fileName)
        guard let toml = try? String(contentsOf: file, encoding: .utf8) else { return ConnectionSet() }
        return (try? decode(from: toml)) ?? ConnectionSet()
    }

    public static func write(_ set: ConnectionSet, to supportDir: URL) throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try TOMLEncoder().encode(set).write(
            to: supportDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    public static func newID(for name: String, existing: [String]) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        let base = words.map(String.init).joined(separator: "-").isEmpty
            ? "connection"
            : words.map(String.init).joined(separator: "-")
        let used = Set(existing)
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
