import Foundation

// A pickable AI service in the connection editor. First-party providers (OpenAI/Anthropic/Gemini) and a
// raw "Custom (OpenAI-compatible)" escape hatch are presets too, so one picker drives them all. The three
// hosted OpenAI-compatible aggregators (OpenRouter, Groq, Mistral) are the "add a key and go" cases: a
// preset pins their base URL and a lightweight, fast default model, so the user only pastes a key.
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

    public init(
        id: String, name: String, provider: Connection.Provider,
        baseURL: String? = nil, defaultModel: String, keysURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.keysURL = keysURL
    }

    // A hosted OpenAI-compatible service with a fixed endpoint: hide the base URL and auth mechanics, just
    // take a key.
    public var isManaged: Bool { provider == .openaiCompatible && baseURL != nil }

    // The raw OpenAI-compatible escape hatch: the user supplies the base URL and chooses the auth mode.
    public var isCustom: Bool { provider == .openaiCompatible && baseURL == nil }

    public var pickerLabel: String { isCustom ? "Custom (OpenAI-compatible)" : name }
}

extension ConnectionPreset {
    public static let openAI = ConnectionPreset(
        id: "openai", name: Connection.Provider.openai.defaultName, provider: .openai,
        defaultModel: Connection.Provider.openai.defaultModel,
        keysURL: URL(string: "https://platform.openai.com/api-keys"))

    public static let anthropic = ConnectionPreset(
        id: "anthropic", name: Connection.Provider.anthropic.defaultName, provider: .anthropic,
        defaultModel: Connection.Provider.anthropic.defaultModel,
        keysURL: URL(string: "https://console.anthropic.com/settings/keys"))

    public static let gemini = ConnectionPreset(
        id: "gemini", name: Connection.Provider.gemini.defaultName, provider: .gemini,
        defaultModel: Connection.Provider.gemini.defaultModel,
        keysURL: URL(string: "https://aistudio.google.com/apikey"))

    public static let openRouter = ConnectionPreset(
        id: "openrouter", name: "OpenRouter", provider: .openaiCompatible,
        baseURL: "https://openrouter.ai/api/v1", defaultModel: "google/gemini-3.1-flash-lite",
        keysURL: URL(string: "https://openrouter.ai/keys"))

    public static let groq = ConnectionPreset(
        id: "groq", name: "Groq", provider: .openaiCompatible,
        baseURL: "https://api.groq.com/openai/v1", defaultModel: "openai/gpt-oss-20b",
        keysURL: URL(string: "https://console.groq.com/keys"))

    public static let mistral = ConnectionPreset(
        id: "mistral", name: "Mistral", provider: .openaiCompatible,
        baseURL: "https://api.mistral.ai/v1", defaultModel: "mistral-small-latest",
        keysURL: URL(string: "https://console.mistral.ai/api-keys"))

    public static let custom = ConnectionPreset(
        id: "custom", name: Connection.Provider.openaiCompatible.defaultName, provider: .openaiCompatible,
        baseURL: nil, defaultModel: "", keysURL: nil)

    public static let all: [ConnectionPreset] = [openAI, anthropic, gemini, openRouter, groq, mistral, custom]

    public static func preset(id: String) -> ConnectionPreset? {
        all.first { $0.id == id }
    }

    // Recover the preset a stored/edited connection represents. An OpenAI-compatible connection whose base
    // URL matches a hosted preset resolves to that preset; anything else OpenAI-compatible is Custom. The
    // first-party providers resolve by provider kind.
    public static func matching(provider: Connection.Provider, baseURL: String?) -> ConnectionPreset {
        if provider == .openaiCompatible {
            let normalized = normalize(baseURL)
            if !normalized.isEmpty,
               let match = all.first(where: { $0.baseURL.map(normalize) == normalized }) {
                return match
            }
            return custom
        }
        return all.first { $0.provider == provider && $0.baseURL == nil } ?? custom
    }

    static func normalize(_ baseURL: String?) -> String {
        (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().removingTrailingSlash
    }
}
