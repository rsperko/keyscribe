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
    var name: String
    var provider: Connection.Provider
    var model: String
    var baseURL: String
    var authMethod: Connection.AuthMethod
    var apiKey: String
    var tokenCommand: String
    var availableModels: [String]
    var modelDiscoveryState: ModelDiscoveryState?

    init(
        name: String = Connection.Provider.openai.defaultName,
        provider: Connection.Provider = .openai,
        model: String = Connection.Provider.openai.defaultModel,
        baseURL: String = "",
        authMethod: Connection.AuthMethod = .apiKey,
        apiKey: String = "",
        tokenCommand: String = "",
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

    // The service the draft currently represents, recovered from provider + base URL (a hosted OpenAI-
    // compatible endpoint resolves to its preset; anything else OpenAI-compatible is Custom).
    var selectedPreset: ConnectionPreset {
        ConnectionPreset.matching(provider: provider, baseURL: baseURL)
    }

    // Seed the draft from a picked service. Hosted presets pin the base URL, a lightweight default model, and
    // API-key auth so the user only pastes a key. The name follows only while it still reads as a preset
    // default (i.e. the user has not typed their own).
    mutating func applyPreset(_ preset: ConnectionPreset, hasStoredKey: Bool, updateDefaultName: Bool) {
        if updateDefaultName, ConnectionPreset.all.contains(where: { $0.name == name }) {
            name = preset.name
        }
        provider = preset.provider
        model = preset.defaultModel
        baseURL = preset.baseURL ?? ""
        if preset.isManaged {
            authMethod = .apiKey
        } else if authMethod == .none {
            authMethod = .apiKey
        }
        if preset.provider != .openaiCompatible, authMethod != .tokenCommand {
            tokenCommand = ""
        }
        if preset.isManaged { tokenCommand = "" }
        resetModelDiscovery()
    }

    mutating func changeProvider(
        to newProvider: Connection.Provider,
        defaultOpenAICompatibleAuth: Connection.AuthMethod,
        hasStoredKey: Bool,
        updateDefaultName: Bool
    ) {
        let oldProvider = provider
        provider = newProvider
        if updateDefaultName, name == oldProvider.defaultName {
            name = newProvider.defaultName
        }
        model = newProvider.defaultModel
        if newProvider == .openaiCompatible {
            authMethod = hasStoredKey ? .apiKey : defaultOpenAICompatibleAuth
        } else if authMethod == .none {
            authMethod = .apiKey
        }
        if newProvider != .openaiCompatible, authMethod != .tokenCommand {
            tokenCommand = ""
        }
        resetModelDiscovery()
    }

    mutating func changeAuthMethod(to newMethod: Connection.AuthMethod) {
        authMethod = provider != .openaiCompatible && newMethod == .none ? .apiKey : newMethod
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

// The service label for a stored connection: a hosted preset (OpenRouter/Groq/Mistral) reads as its own
// name rather than the generic "OpenAI-compatible", so the quick-setup services feel first-class in the
// list and summary. A custom endpoint still reads "OpenAI-compatible".
func serviceLabel(_ connection: Connection) -> String {
    let preset = ConnectionPreset.matching(provider: connection.provider, baseURL: connection.baseUrl)
    return preset.isManaged ? preset.name : providerLabel(connection.provider)
}
