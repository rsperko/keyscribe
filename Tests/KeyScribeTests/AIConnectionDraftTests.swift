import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct AIConnectionDraftTests {
    @Test func onboardingKeepsAPIKeyAsTheOpenAICompatibleDefault() {
        var draft = AIConnectionDraft(provider: .openai, authMethod: .apiKey)

        draft.changeProvider(
            to: .openaiCompatible,
            defaultOpenAICompatibleAuth: .apiKey,
            hasStoredKey: false,
            updateDefaultName: true)

        #expect(draft.provider == .openaiCompatible)
        #expect(draft.authMethod == .apiKey)
        #expect(draft.name == Connection.Provider.openaiCompatible.defaultName)
    }

    @Test func settingsDefaultsOpenAICompatibleWithoutAStoredKeyToAPIKey() {
        var draft = AIConnectionDraft(name: "New AI Service", provider: .openai, authMethod: .apiKey)

        draft.changeProvider(
            to: .openaiCompatible,
            defaultOpenAICompatibleAuth: .apiKey,
            hasStoredKey: false,
            updateDefaultName: false)

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

        draft.applyPreset(.groq, hasStoredKey: false, updateDefaultName: true)

        #expect(draft.provider == .openaiCompatible)
        #expect(draft.baseURL == "https://api.groq.com/openai/v1")
        #expect(draft.model == "openai/gpt-oss-20b")
        #expect(draft.authMethod == .apiKey)
        #expect(draft.name == "Groq")
        #expect(draft.selectedPreset.id == "groq")
    }

    @Test func hostedPresetIsConnectableInSetupWithOnlyAKey() {
        var draft = AIConnectionDraft()
        draft.applyPreset(.openRouter, hasStoredKey: false, updateDefaultName: true)

        #expect(!draft.canConnectForSetup)
        draft.apiKey = "sk-or-secret"
        #expect(draft.canConnectForSetup)
        #expect(draft.selectedPreset.isManaged)
    }

    @Test func applyPresetKeepsAUserTypedNameButFollowsPresetDefaults() {
        var custom = AIConnectionDraft(name: "My Rewriter", provider: .openai)
        custom.applyPreset(.mistral, hasStoredKey: false, updateDefaultName: true)
        #expect(custom.name == "My Rewriter")

        var defaulted = AIConnectionDraft(name: Connection.Provider.openai.defaultName, provider: .openai)
        defaulted.applyPreset(.mistral, hasStoredKey: false, updateDefaultName: true)
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
        draft.applyPreset(.mistral, hasStoredKey: false, updateDefaultName: true)
        draft.applyPreset(.custom, hasStoredKey: false, updateDefaultName: true)

        #expect(draft.selectedPreset.isCustom)
        #expect(draft.baseURL.isEmpty)
        #expect(draft.provider == .openaiCompatible)
    }
}
