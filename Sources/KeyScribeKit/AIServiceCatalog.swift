import Foundation

// The single source of truth for the AI-service lineup: which services the picker and Add chooser
// offer, their endpoints, default models, key-console links, allowed sign-in methods, and which entry
// onboarding seeds. A rebranded downstream build replaces this file plus its test-side mirror
// (AIServiceCatalogTests, the one test file that pins the lineup) — everything else (picker, onboarding
// default, auth UI, model discovery, every other test) derives from the catalog and stays untouched.
//
// The swap contract: `all`, `defaultPreset`, and `custom` must stay defined; `defaultPreset` must be a
// member of `all`; `custom` must remain defined even if a lineup chooses not to list it — `matching` and
// the managed-preset demotion fall back to it. Every other test file is lineup-agnostic (fixtures and
// contract members only), so no lineup shape beyond this contract is assumed anywhere.
public enum AIServiceCatalog {
    public static let openAI = ConnectionPreset(
        id: "openai", name: "OpenAI", provider: .openai,
        defaultModel: "gpt-5.6-luna",
        keysURL: URL(string: "https://platform.openai.com/api-keys"))

    public static let anthropic = ConnectionPreset(
        id: "anthropic", name: "Anthropic", provider: .anthropic,
        defaultModel: "claude-haiku-4-5",
        keysURL: URL(string: "https://console.anthropic.com/settings/keys"))

    public static let gemini = ConnectionPreset(
        id: "gemini", name: "Gemini", provider: .gemini,
        defaultModel: "gemini-flash-lite-latest",
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
        id: "custom", name: "Custom AI", provider: .openaiCompatible,
        baseURL: nil, defaultModel: "", keysURL: nil,
        allowedAuthMethods: [.none, .apiKey, .tokenCommand],
        pickerLabelOverride: "Custom (OpenAI-compatible)")

    public static let all: [ConnectionPreset] = [openAI, anthropic, gemini, openRouter, groq, mistral, custom]

    public static let defaultPreset = openAI
}
