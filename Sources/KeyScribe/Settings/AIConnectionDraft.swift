import Foundation
import KeyScribeKit

enum ConnectionTestState: Equatable {
    case testing
    case passed
    case failed(String)
}

enum ModelDiscoveryState: Equatable {
    case loading
    case loaded
    case failed(String)
}

struct AIConnectionDraft: Equatable {
    // Kept per preset so an accidental Service flip is restorable within the editing session
    // (ui_components.md: never silently reset a dependent user value).
    struct ServiceValues: Equatable {
        var model: String
        var baseURL: String
        var authMethod: Connection.AuthMethod
        var tokenCommand: String
    }

    var name: String
    var provider: Connection.Provider
    var model: String
    var baseURL: String
    var authMethod: Connection.AuthMethod
    var apiKey: String
    var tokenCommand: String
    var availableModels: [String]
    var modelDiscoveryState: ModelDiscoveryState?
    // Stored, not derived from baseURL — a typed custom URL matching a hosted preset would otherwise
    // hide the very fields being edited.
    var presetId: String
    var stashedServiceValues: [String: ServiceValues] = [:]

    init(
        name: String = AIServiceCatalog.defaultPreset.name,
        provider: Connection.Provider = AIServiceCatalog.defaultPreset.provider,
        model: String = AIServiceCatalog.defaultPreset.defaultModel,
        baseURL: String = AIServiceCatalog.defaultPreset.baseURL ?? "",
        authMethod: Connection.AuthMethod = AIServiceCatalog.defaultPreset.defaultAuthMethod,
        apiKey: String = "",
        tokenCommand: String = AIServiceCatalog.defaultPreset.defaultTokenCommand ?? "",
        availableModels: [String] = [],
        modelDiscoveryState: ModelDiscoveryState? = nil
    ) {
        self.name = name
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.authMethod = authMethod
        self.apiKey = apiKey
        self.tokenCommand = tokenCommand
        self.availableModels = availableModels
        self.modelDiscoveryState = modelDiscoveryState
        self.presetId = Self.derivePresetId(provider: provider, baseURL: baseURL, authMethod: authMethod)
    }

    // A connection at a hosted preset's URL with an auth method that preset doesn't offer (hand-edited
    // TOML) opens as Custom — presenting it as managed would hide the fields needed to fix it.
    static func derivePresetId(
        provider: Connection.Provider, baseURL: String, authMethod: Connection.AuthMethod,
        in presets: [ConnectionPreset] = AIServiceCatalog.all
    ) -> String {
        let match = ConnectionPreset.matching(provider: provider, baseURL: baseURL, in: presets)
        if match.isManaged, !match.allowedAuthMethods.contains(authMethod) { return ConnectionPreset.custom.id }
        return match.id
    }

    init(
        connection: Connection,
        apiKey: String = "",
        availableModels: [String] = [],
        modelDiscoveryState: ModelDiscoveryState? = nil
    ) {
        self.init(
            name: connection.name,
            provider: connection.provider,
            model: connection.model,
            baseURL: connection.baseUrl ?? "",
            authMethod: connection.authMethod,
            apiKey: apiKey,
            tokenCommand: connection.tokenCommand ?? "",
            availableModels: availableModels,
            modelDiscoveryState: modelDiscoveryState)
    }

    var effectiveAuthMethod: Connection.AuthMethod {
        if provider != .openaiCompatible, authMethod == .none { return .apiKey }
        return authMethod
    }

    var requestAPIKey: String? {
        guard effectiveAuthMethod == .apiKey else { return nil }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    var hasUnsavedAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isFetchingModels: Bool {
        modelDiscoveryState == .loading
    }

    var modelDiscoveryError: String? {
        guard case .failed(let message) = modelDiscoveryState else { return nil }
        return message
    }

    var canConnectForSetup: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && setupCredentialReady
    }

    var canFetchModelsForSetup: Bool {
        setupCredentialReady
    }

    var setupModelFetchDisabledReason: String? {
        guard !isFetchingModels, !canFetchModelsForSetup else { return nil }
        return setupCredentialDisabledReason(action: "fetching models")
    }

    var setupCredentialReady: Bool {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .openaiCompatible, base.isEmpty { return false }
        switch effectiveAuthMethod {
        case .none:
            return true
        case .apiKey:
            return hasUnsavedAPIKey
        case .tokenCommand:
            return !tokenCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func setupCredentialDisabledReason(action: String) -> String? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .openaiCompatible, base.isEmpty {
            return "Base URL is required before \(action)."
        }
        switch effectiveAuthMethod {
        case .none:
            return nil
        case .apiKey:
            return provider == .openaiCompatible
                ? "Enter an API key or choose No Auth before \(action)."
                : "API key is required before \(action)."
        case .tokenCommand:
            return "Token command is required before \(action)."
        }
    }

    func canFetchModelsInSettings(hasStoredKey: Bool) -> Bool {
        if hasUnsavedAPIKey { return false }
        switch provider {
        case .openaiCompatible:
            guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            switch effectiveAuthMethod {
            case .none:
                return true
            case .apiKey:
                return hasStoredKey
            case .tokenCommand:
                return !tokenCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .openai, .anthropic, .gemini:
            return hasStoredKey || effectiveAuthMethod == .tokenCommand
        }
    }

    func canTestInSettings(hasStoredKey: Bool) -> Bool {
        if hasUnsavedAPIKey || connection(id: "draft", keyRef: "draft").configIssue != nil { return false }
        switch provider {
        case .openaiCompatible:
            switch effectiveAuthMethod {
            case .none:
                return true
            case .apiKey:
                return hasStoredKey
            case .tokenCommand:
                return !tokenCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .openai, .anthropic, .gemini:
            return hasStoredKey || effectiveAuthMethod == .tokenCommand
        }
    }

    func modelFetchDisabledReasonInSettings(hasStoredKey: Bool) -> String? {
        guard !isFetchingModels, !canFetchModelsInSettings(hasStoredKey: hasStoredKey) else { return nil }
        if hasUnsavedAPIKey { return "Save the typed key before fetching models." }
        switch connection(id: "draft", keyRef: "draft").configIssue {
        case .missingBaseURL:
            return "Base URL is required before fetching models."
        case .missingTokenCommand:
            return "Token command is required before fetching models."
        case .missingModel, nil:
            break
        }
        if provider == .openaiCompatible {
            if effectiveAuthMethod == .apiKey && !hasStoredKey {
                return "Save an API key or choose No Auth before fetching models."
            }
        } else if effectiveAuthMethod == .apiKey && !hasStoredKey {
            return "Save an API key before fetching models."
        }
        return nil
    }

    func testDisabledReasonInSettings(hasStoredKey: Bool) -> String? {
        if hasUnsavedAPIKey { return "Typed key is not saved yet." }
        switch connection(id: "draft", keyRef: "draft").configIssue {
        case .missingModel:
            return "Model ID is required."
        case .missingBaseURL:
            return "Base URL is required."
        case .missingTokenCommand:
            return "Token command is required."
        case nil:
            break
        }
        if provider == .openaiCompatible {
            if effectiveAuthMethod == .apiKey && !hasStoredKey { return "Save an API key or choose No Auth." }
        } else if effectiveAuthMethod == .apiKey && !hasStoredKey {
            return "Save an API key before testing."
        }
        return nil
    }

    var selectedPreset: ConnectionPreset {
        ConnectionPreset.preset(id: presetId) ?? .custom
    }

    // Outgoing values are stashed and restored on switch-back, so an accidental flip destroys nothing.
    // The name follows the preset only while it still reads as a preset default (not user-typed).
    mutating func applyPreset(_ preset: ConnectionPreset, updateDefaultName: Bool) {
        guard preset.id != presetId else { return }
        stashedServiceValues[presetId] = ServiceValues(
            model: model, baseURL: baseURL, authMethod: authMethod, tokenCommand: tokenCommand)
        if updateDefaultName, ConnectionPreset.all.contains(where: { $0.name == name }) {
            name = preset.name
        }
        presetId = preset.id
        provider = preset.provider
        if let restored = stashedServiceValues[preset.id] {
            model = restored.model
            baseURL = restored.baseURL
            authMethod = restored.authMethod
            tokenCommand = restored.tokenCommand
        } else {
            model = preset.defaultModel
            baseURL = preset.baseURL ?? ""
            tokenCommand = preset.defaultTokenCommand ?? ""
        }
        // A disallowed token command survives on a non-managed preset (hand-edited TOML keeps its command);
        // any other disallowed method snaps to the preset's default.
        if !preset.allowedAuthMethods.contains(authMethod), preset.isManaged || authMethod != .tokenCommand {
            authMethod = preset.defaultAuthMethod
        }
        if authMethod != .tokenCommand, !preset.allowedAuthMethods.contains(.tokenCommand) {
            tokenCommand = ""
        }
        // A typed key belongs to the API-key flow only — carrying it into a no-auth/token-command preset
        // leaves hasUnsavedAPIKey blocking Test/fetch behind a hidden field.
        if authMethod != .apiKey { apiKey = "" }
        resetModelDiscovery()
    }

    // Params aren't editable in the form, so an edit preserves the stored connection's params — unless the
    // provider changed, where carrying them over would send one provider's reasoning knob to another
    // (e.g. reasoning_effort to Gemini).
    func resolvedParams(for existing: Connection) -> Connection.Params {
        provider == existing.provider ? existing.params : provider.defaultParams
    }

    mutating func changeAuthMethod(
        to newMethod: Connection.AuthMethod, in presets: [ConnectionPreset] = AIServiceCatalog.all
    ) {
        authMethod = provider != .openaiCompatible && newMethod == .none ? .apiKey : newMethod
        if authMethod == .tokenCommand, tokenCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tokenCommand = (ConnectionPreset.preset(id: presetId, in: presets) ?? .custom).defaultTokenCommand ?? ""
        }
        if authMethod != .tokenCommand { tokenCommand = "" }
        if authMethod != .apiKey { apiKey = "" }
        resetModelDiscovery()
    }

    mutating func applyFetchedModels(_ models: [String]) {
        availableModels = models
        modelDiscoveryState = .loaded
        if !models.isEmpty, !models.contains(model.trimmingCharacters(in: .whitespacesAndNewlines)) {
            model = models[0]
        }
    }

    mutating func resetModelDiscovery() {
        availableModels = []
        modelDiscoveryState = nil
    }

    func connection(id: String, keyRef: String) -> Connection {
        let command = tokenCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        var connection = Connection(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            keyRef: keyRef,
            authMethod: effectiveAuthMethod,
            tokenCommand: effectiveAuthMethod == .tokenCommand && !command.isEmpty ? command : nil)
        if provider == .openaiCompatible {
            let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.baseUrl = trimmedBaseURL.isEmpty ? nil : trimmedBaseURL
        }
        return connection
    }
}

func providerLabel(_ provider: Connection.Provider) -> String {
    switch provider {
    case .openai: "OpenAI"
    case .anthropic: "Anthropic"
    case .gemini: "Gemini"
    case .openaiCompatible: "OpenAI-compatible"
    }
}

// A hosted preset (OpenRouter/Groq/Mistral) reads as its own name rather than generic "OpenAI-compatible";
// a custom endpoint still reads "OpenAI-compatible". Mirrors the editor's rule so list and editor never
// name the same connection differently.
func serviceLabel(_ connection: Connection) -> String {
    let presetId = AIConnectionDraft.derivePresetId(
        provider: connection.provider, baseURL: connection.baseUrl ?? "", authMethod: connection.authMethod)
    let preset = ConnectionPreset.preset(id: presetId) ?? .custom
    return preset.isManaged ? preset.name : providerLabel(connection.provider)
}
