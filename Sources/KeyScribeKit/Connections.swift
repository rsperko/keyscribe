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
            case .openai: "gpt-5.6-luna"
            case .anthropic: "claude-haiku-4-5"
            case .gemini: "gemini-flash-lite-latest"
            case .openaiCompatible: ""
            }
        }

        public var defaultParams: Params {
            switch self {
            case .openai: Params(reasoningEffort: "none")
            case .gemini: Params(geminiThinkingLevel: "minimal")
            case .anthropic, .openaiCompatible: Params()
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
        public var reasoningEffort: String?
        public var geminiThinkingLevel: String?
        enum CodingKeys: String, CodingKey {
            case temperature, reasoningEffort = "reasoning_effort", geminiThinkingLevel = "gemini_thinking_level"
            case maxTokens = "max_tokens"
        }
        public init(
            temperature: Double = 0.2, maxTokens: Int = 2048,
            reasoningEffort: String? = nil, geminiThinkingLevel: String? = nil
        ) {
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.reasoningEffort = reasoningEffort
            self.geminiThinkingLevel = geminiThinkingLevel
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2
            maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 2048
            reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
            geminiThinkingLevel = try c.decodeIfPresent(String.self, forKey: .geminiThinkingLevel)
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
        tokenCommand: String? = nil, params: Params? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.model = model
        self.keyRef = keyRef
        self.baseUrl = baseUrl
        self.authMethod = authMethod ?? (tokenCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? .tokenCommand : .apiKey)
        self.tokenCommand = tokenCommand
        self.params = params ?? provider.defaultParams
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
        params = try c.decodeIfPresent(Params.self, forKey: .params) ?? provider.defaultParams
    }
}

public extension Connection {
    func crossesCredentialBoundary(to updated: Connection) -> Bool {
        guard provider == updated.provider else { return true }
        guard provider == .openaiCompatible else { return false }
        let currentOrigin = normalizedOrigin(baseUrl)
        let updatedOrigin = normalizedOrigin(updated.baseUrl)
        // A base URL that won't parse to an origin can't be compared structurally — two *different*
        // unparseable endpoints both normalize to nil and would read as the same origin, reusing the key
        // across a real endpoint change. Fall back to the raw trimmed text so any change still crosses.
        if currentOrigin == nil || updatedOrigin == nil {
            return trimmedBaseURL(baseUrl) != trimmedBaseURL(updated.baseUrl)
        }
        return currentOrigin != updatedOrigin
    }

    private func trimmedBaseURL(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedOrigin(_ value: String?) -> String? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = switch (scheme, url.port) {
        case ("https", 443), ("http", 80), (_, nil): ""
        case (_, let port?): ":\(port)"
        }
        return "\(scheme)://\(host)\(port)"
    }
}

extension Connection {
    // Structural misconfiguration detectable without a network call (unlike a wrong key, which only Test
    // Connection reveals). A missing key is NOT here — it's legitimate for a local/no-auth endpoint.
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

    public static func load(supportDir: URL) -> ConfigLoad<ConnectionSet> {
        .read(supportDir.appendingPathComponent(fileName), decode: decode)
    }

    public static func loadOrDefault(supportDir: URL) -> ConnectionSet {
        if case .loaded(let set) = load(supportDir: supportDir) { return set }
        return ConnectionSet()
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
