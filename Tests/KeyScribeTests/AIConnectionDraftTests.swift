import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct AIConnectionDraftTests {
    @Test func onboardingKeepsAPIKeyAsTheOpenAICompatibleDefault() {
        var draft = AIConnectionDraft(provider: .openai, authMethod: .apiKey)

        draft.applyPreset(.custom, updateDefaultName: true)

        #expect(draft.provider == .openaiCompatible)
        #expect(draft.authMethod == .apiKey)
        #expect(draft.name == Connection.Provider.openaiCompatible.defaultName)
    }

    @Test func settingsDefaultsOpenAICompatibleWithoutAStoredKeyToAPIKey() {
        var draft = AIConnectionDraft(name: "New AI Service", provider: .openai, authMethod: .apiKey)

        draft.applyPreset(.custom, updateDefaultName: false)

        #expect(draft.provider == .openaiCompatible)
        #expect(draft.authMethod == .apiKey)
        #expect(draft.name == "New AI Service")
    }

    @Test func setupReadinessAllowsOpenAICompatibleNoAuthWithBaseURLAndModel() {
        let draft = AIConnectionDraft(
            provider: .openaiCompatible,
            model: "qwen3",
            baseURL: "http://127.0.0.1:11234/v1",
            authMethod: .none)

        #expect(draft.canConnectForSetup)
        #expect(draft.requestAPIKey == nil)
    }

    @Test func setupReadinessExplainsMissingBaseURLBeforeFetchingModels() {
        let draft = AIConnectionDraft(
            provider: .openaiCompatible,
            model: "qwen3",
            baseURL: "",
            authMethod: .apiKey,
            apiKey: "secret")

        #expect(!draft.canFetchModelsForSetup)
        #expect(draft.setupModelFetchDisabledReason == "Base URL is required before fetching models.")
    }

    @Test func settingsRequiresSavedKeyBeforeTestingAPIKeyConnections() {
        let draft = AIConnectionDraft(
            provider: .gemini,
            model: "gemini-2.5-flash",
            authMethod: .apiKey)

        #expect(!draft.canTestInSettings(hasStoredKey: false))
        #expect(draft.testDisabledReasonInSettings(hasStoredKey: false) == "Save an API key before testing.")
        #expect(draft.canTestInSettings(hasStoredKey: true))
    }

    @Test func applyHostedPresetSeedsEndpointModelAndAPIKeyAuth() {
        var draft = AIConnectionDraft(provider: .openai, authMethod: .apiKey)

        draft.applyPreset(.groq, updateDefaultName: true)

        #expect(draft.provider == .openaiCompatible)
        #expect(draft.baseURL == "https://api.groq.com/openai/v1")
        #expect(draft.model == "openai/gpt-oss-20b")
        #expect(draft.authMethod == .apiKey)
        #expect(draft.name == "Groq")
        #expect(draft.selectedPreset.id == "groq")
    }

    @Test func hostedPresetIsConnectableInSetupWithOnlyAKey() {
        var draft = AIConnectionDraft()
        draft.applyPreset(.openRouter, updateDefaultName: true)

        #expect(!draft.canConnectForSetup)
        draft.apiKey = "sk-or-secret"
        #expect(draft.canConnectForSetup)
        #expect(draft.selectedPreset.isManaged)
    }

    @Test func applyPresetKeepsAUserTypedNameButFollowsPresetDefaults() {
        var custom = AIConnectionDraft(name: "My Rewriter", provider: .openai)
        custom.applyPreset(.mistral, updateDefaultName: true)
        #expect(custom.name == "My Rewriter")

        var defaulted = AIConnectionDraft(name: Connection.Provider.openai.defaultName, provider: .openai)
        defaulted.applyPreset(.mistral, updateDefaultName: true)
        #expect(defaulted.name == "Mistral")
    }

    @Test func selectedPresetRecoversHostedServiceFromStoredConnection() {
        let connection = Connection(
            id: "groq", name: "Groq", provider: .openaiCompatible,
            model: "openai/gpt-oss-20b", keyRef: "keyscribe.llm.groq",
            baseUrl: "https://api.groq.com/openai/v1")
        let draft = AIConnectionDraft(connection: connection)

        #expect(draft.selectedPreset.id == "groq")
        #expect(draft.selectedPreset.isManaged)
    }

    @Test func switchingBackToCustomClearsTheManagedEndpoint() {
        var draft = AIConnectionDraft()
        draft.applyPreset(.mistral, updateDefaultName: true)
        draft.applyPreset(.custom, updateDefaultName: true)

        #expect(draft.selectedPreset.isCustom)
        #expect(draft.baseURL.isEmpty)
        #expect(draft.provider == .openaiCompatible)
    }

    @Test func typingAHostedPresetURLIntoCustomStaysCustom() {
        var draft = AIConnectionDraft()
        draft.applyPreset(.custom, updateDefaultName: true)

        draft.baseURL = "https://openrouter.ai/api/v1"

        #expect(draft.selectedPreset.isCustom)
    }

    @Test func storedConnectionAtHostedURLWithNonKeyAuthOpensAsCustom() {
        for (authMethod, tokenCommand): (Connection.AuthMethod, String?) in [(.none, nil), (.tokenCommand, "print-token")] {
            let connection = Connection(
                id: "or", name: "OpenRouter", provider: .openaiCompatible,
                model: "google/gemini-3.1-flash-lite", keyRef: "keyscribe.llm.or",
                baseUrl: "https://openrouter.ai/api/v1", authMethod: authMethod, tokenCommand: tokenCommand)
            let draft = AIConnectionDraft(connection: connection)

            #expect(draft.selectedPreset.isCustom)
        }
    }

    @Test func switchingServiceAndBackRestoresThePreviousEndpointModelAndAuth() {
        var draft = AIConnectionDraft(
            provider: .openaiCompatible,
            model: "qwen3",
            baseURL: "http://127.0.0.1:11234/v1",
            authMethod: .none)
        #expect(draft.selectedPreset.isCustom)

        draft.applyPreset(.groq, updateDefaultName: true)
        #expect(draft.baseURL == "https://api.groq.com/openai/v1")
        #expect(draft.model == "openai/gpt-oss-20b")

        draft.applyPreset(.custom, updateDefaultName: true)
        #expect(draft.model == "qwen3")
        #expect(draft.baseURL == "http://127.0.0.1:11234/v1")
        #expect(draft.authMethod == .none)
    }

    @Test func reapplyingTheCurrentPresetChangesNothing() {
        var draft = AIConnectionDraft(
            provider: .openaiCompatible,
            model: "qwen3",
            baseURL: "https://api.groq.com/openai/v1")
        #expect(draft.selectedPreset.id == "groq")

        draft.applyPreset(.groq, updateDefaultName: true)

        #expect(draft.model == "qwen3")
        #expect(draft.baseURL == "https://api.groq.com/openai/v1")
    }

    @Test func resolvedParamsPreservesStoredParamsForTheSameProvider() {
        let stored = Connection(
            id: "o", name: "OpenAI", provider: .openai, model: "gpt-5.6-luna",
            keyRef: "k", params: .init(temperature: 0.7, maxTokens: 4096, reasoningEffort: "low"))
        let draft = AIConnectionDraft(connection: stored)

        #expect(draft.resolvedParams(for: stored) == stored.params)
    }

    @Test func resolvedParamsRestampsProviderDefaultsOnProviderSwitch() {
        let stored = Connection(
            id: "o", name: "OpenAI", provider: .openai, model: "gpt-5.6-luna", keyRef: "k")
        #expect(stored.params.reasoningEffort == "none")

        var toCompat = AIConnectionDraft(connection: stored)
        toCompat.applyPreset(.groq, updateDefaultName: false)
        #expect(toCompat.resolvedParams(for: stored).reasoningEffort == nil)

        var toGemini = AIConnectionDraft(connection: stored)
        toGemini.applyPreset(.gemini, updateDefaultName: false)
        #expect(toGemini.resolvedParams(for: stored).reasoningEffort == nil)
        #expect(toGemini.resolvedParams(for: stored).geminiThinkingLevel == "minimal")
    }
}
