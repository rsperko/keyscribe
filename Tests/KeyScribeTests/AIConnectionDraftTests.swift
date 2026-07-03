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
}
