import Foundation

// A pickable AI service in the connection editor. First-party providers, hosted OpenAI-compatible
// services, and the raw "Custom (OpenAI-compatible)" escape hatch are all presets, so one picker drives
// them all. This type is the machinery only — the actual lineup (which services exist, their endpoints
// and defaults) lives in AIServiceCatalog, the one file a rebranded downstream build swaps.
//
// A preset is UI seed data only — nothing here changes the on-disk schema. A seeded OpenRouter connection
// persists as a plain `openai_compatible` connection with a base_url; `matching(provider:baseURL:)` recovers
// which preset it represents when it is reopened.
public struct ConnectionPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let provider: Connection.Provider
    public let baseURL: String?
    public let defaultModel: String
    public let keysURL: URL?
    public let allowedAuthMethods: [Connection.AuthMethod]
    public let defaultAuthMethod: Connection.AuthMethod
    public let defaultTokenCommand: String?
    public let pickerLabelOverride: String?

    public init(
        id: String, name: String, provider: Connection.Provider,
        baseURL: String? = nil, defaultModel: String, keysURL: URL? = nil,
        allowedAuthMethods: [Connection.AuthMethod] = [.apiKey],
        defaultAuthMethod: Connection.AuthMethod = .apiKey,
        defaultTokenCommand: String? = nil,
        pickerLabelOverride: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.keysURL = keysURL
        self.allowedAuthMethods = allowedAuthMethods
        self.defaultAuthMethod = defaultAuthMethod
        self.defaultTokenCommand = defaultTokenCommand
        self.pickerLabelOverride = pickerLabelOverride
    }

    // A hosted OpenAI-compatible service with a fixed endpoint: hide the base URL and auth mechanics.
    public var isManaged: Bool { provider == .openaiCompatible && baseURL != nil }

    // The raw OpenAI-compatible escape hatch: the user supplies the base URL and chooses the auth mode.
    public var isCustom: Bool { provider == .openaiCompatible && baseURL == nil }

    public var offersAuthChoice: Bool { allowedAuthMethods.count > 1 }

    public var pickerLabel: String { pickerLabelOverride ?? name }
}

extension ConnectionPreset {
    public static var all: [ConnectionPreset] { AIServiceCatalog.all }

    public static var custom: ConnectionPreset { AIServiceCatalog.custom }

    public static func preset(
        id: String, in presets: [ConnectionPreset] = AIServiceCatalog.all
    ) -> ConnectionPreset? {
        presets.first { $0.id == id }
    }

    // Recover the preset a stored/edited connection represents. An OpenAI-compatible connection whose base
    // URL matches a hosted preset resolves to that preset; anything else OpenAI-compatible is Custom. The
    // first-party providers resolve by provider kind.
    public static func matching(
        provider: Connection.Provider, baseURL: String?,
        in presets: [ConnectionPreset] = AIServiceCatalog.all
    ) -> ConnectionPreset {
        if provider == .openaiCompatible {
            let normalized = normalize(baseURL)
            if !normalized.isEmpty,
               let match = presets.first(where: { $0.baseURL.map(normalize) == normalized }) {
                return match
            }
            return custom
        }
        return presets.first { $0.provider == provider && $0.baseURL == nil } ?? custom
    }

    static func normalize(_ baseURL: String?) -> String {
        (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().removingTrailingSlash
    }
}
