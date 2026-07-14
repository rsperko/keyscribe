import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Lineup-agnostic by design: reference the catalog only through its contract members (defaultPreset,
// custom, all) or local fixtures, so a swapped downstream AIServiceCatalog stays green. Exact
// public-lineup pinning lives in AIServiceCatalogTests.
struct AIConnectionDraftTests {
    private let noAuthGateway = ConnectionPreset(
        id: "gateway-open", name: "Gateway (Open)", provider: .openaiCompatible,
        baseURL: "https://gateway.example.com/open/v1", defaultModel: "standard-model",
        allowedAuthMethods: [.none], defaultAuthMethod: Connection.AuthMethod.none)

    private let keyedGateway = ConnectionPreset(
        id: "gateway-keyed", name: "Gateway (Keyed)", provider: .openaiCompatible,
        baseURL: "https://gateway.example.com/keyed/v1", defaultModel: "standard-model",
        allowedAuthMethods: [.apiKey, .tokenCommand])

    private let commandGateway = ConnectionPreset(
        id: "gateway-command", name: "Gateway (Command)", provider: .openaiCompatible,
        baseURL: "https://gateway.example.com/command/v1", defaultModel: "standard-model",
        allowedAuthMethods: [.apiKey, .tokenCommand], defaultAuthMethod: .tokenCommand,
        defaultTokenCommand: "gateway-cli token mint")

    @Test func defaultDraftMirrorsTheCatalogDefaultPreset() {
        let draft = AIConnectionDraft()
        let preset = AIServiceCatalog.defaultPreset

        #expect(draft.name == preset.name)
        #expect(draft.provider == preset.provider)
        #expect(draft.model == preset.defaultModel)
        #expect(draft.baseURL == (preset.baseURL ?? ""))
        #expect(draft.authMethod == preset.defaultAuthMethod)
        #expect(draft.tokenCommand == (preset.defaultTokenCommand ?? ""))
        #expect(draft.selectedPreset.id == preset.id)
    }

    @Test func draftPreservesTheConfiguredWireAPI() {
        let stored = Connection(
            id: "gateway", name: "Gateway", provider: .openaiCompatible, model: "new-model",
            keyRef: "k", baseUrl: "https://gateway.example/v1", wireAPI: .responses)
        let draft = AIConnectionDraft(connection: stored)

        #expect(draft.wireAPI == .responses)
        #expect(draft.connection(id: stored.id, keyRef: stored.keyRef).wireAPI == .responses)
    }

    @Test func derivePresetIdKeepsAManagedPresetThatAllowsTheStoredAuth() {
        let lineup = [noAuthGateway, keyedGateway, ConnectionPreset.custom]

        #expect(AIConnectionDraft.derivePresetId(
            provider: .openaiCompatible, baseURL: "https://gateway.example.com/open/v1",
            authMethod: .none, in: lineup) == "gateway-open")
        #expect(AIConnectionDraft.derivePresetId(
            provider: .openaiCompatible, baseURL: "https://gateway.example.com/keyed/v1",
            authMethod: .tokenCommand, in: lineup) == "gateway-keyed")
        #expect(AIConnectionDraft.derivePresetId(
            provider: .openaiCompatible, baseURL: "https://gateway.example.com/open/v1",
            authMethod: .apiKey, in: lineup) == "custom")
    }

    @Test func draftOpensAStoredConnectionAtItsCatalogPreset() {
        let preset = AIServiceCatalog.defaultPreset
        let connection = Connection(
            id: "stored", name: preset.name, provider: preset.provider,
            model: preset.defaultModel, keyRef: "keyscribe.llm.stored",
            baseUrl: preset.baseURL, authMethod: preset.defaultAuthMethod,
            tokenCommand: preset.defaultTokenCommand)
        let draft = AIConnectionDraft(connection: connection)

        #expect(draft.selectedPreset.id == preset.id)
    }

    @Test func applyingANoAuthOnlyPresetSnapsToNoAuthAndDropsCredentials() {
        var draft = AIConnectionDraft()
        draft.apiKey = "secret"

        draft.applyPreset(noAuthGateway, updateDefaultName: false)

        #expect(draft.authMethod == .none)
        #expect(draft.baseURL == "https://gateway.example.com/open/v1")
        #expect(draft.model == "standard-model")
        #expect(draft.tokenCommand.isEmpty)
        #expect(!draft.hasUnsavedAPIKey)
        #expect(draft.requestAPIKey == nil)
    }

    // A token command is endpoint-scoped: the first visit to a preset starts from that preset's own
    // default (or empty), never the outgoing service's command.
    @Test func applyingAKeyOrCommandPresetPreservesTheAuthChoiceButNotTheCommand() {
        var fromCommand = AIConnectionDraft(
            provider: .openaiCompatible, baseURL: "https://self-hosted.example.com/v1",
            authMethod: .tokenCommand, tokenCommand: "print-token")
        fromCommand.applyPreset(keyedGateway, updateDefaultName: false)
        #expect(fromCommand.authMethod == .tokenCommand)
        #expect(fromCommand.tokenCommand.isEmpty)

        fromCommand.applyPreset(.custom, updateDefaultName: false)
        #expect(fromCommand.tokenCommand == "print-token")

        var fromNone = AIConnectionDraft(
            provider: .openaiCompatible, baseURL: "https://self-hosted.example.com/v1",
            authMethod: .none)
        fromNone.applyPreset(keyedGateway, updateDefaultName: false)
        #expect(fromNone.authMethod == keyedGateway.defaultAuthMethod)
    }

    @Test func applyingACommandDefaultPresetSeedsItsDefaultCommand() {
        var fromDisallowed = AIConnectionDraft(
            provider: .openaiCompatible, baseURL: "https://self-hosted.example.com/v1",
            authMethod: .none)
        fromDisallowed.apiKey = "stale-typed-key"
        fromDisallowed.applyPreset(commandGateway, updateDefaultName: false)
        #expect(fromDisallowed.authMethod == .tokenCommand)
        #expect(fromDisallowed.tokenCommand == "gateway-cli token mint")
        #expect(!fromDisallowed.hasUnsavedAPIKey)

        var fromKey = AIConnectionDraft(
            provider: .openaiCompatible, baseURL: "https://self-hosted.example.com/v1",
            authMethod: .apiKey, apiKey: "secret")
        fromKey.applyPreset(commandGateway, updateDefaultName: false)
        #expect(fromKey.authMethod == .apiKey)
        #expect(fromKey.tokenCommand == "gateway-cli token mint")
        #expect(fromKey.apiKey == "secret")
    }

    @Test func switchingToCommandAuthReseedsThePresetDefaultWhenEmpty() {
        let lineup = [commandGateway, ConnectionPreset.custom]
        var draft = AIConnectionDraft(
            provider: .openaiCompatible, baseURL: "https://self-hosted.example.com/v1",
            authMethod: .apiKey, apiKey: "secret")
        draft.applyPreset(commandGateway, updateDefaultName: false)

        draft.changeAuthMethod(to: .tokenCommand, in: lineup)
        #expect(draft.tokenCommand == "gateway-cli token mint")

        draft.tokenCommand = "my-own-command"
        draft.changeAuthMethod(to: .apiKey, in: lineup)
        #expect(draft.tokenCommand.isEmpty)

        draft.changeAuthMethod(to: .tokenCommand, in: lineup)
        #expect(draft.tokenCommand == "gateway-cli token mint")
    }

    // presetId is seeded to a non-lineup id so the switch to Custom is a real transition, not a no-op.
    @Test func onboardingKeepsAPIKeyAsTheOpenAICompatibleDefault() {
        var draft = AIConnectionDraft(provider: .openai, authMethod: .apiKey)
        draft.presetId = "seed"

        draft.applyPreset(.custom, updateDefaultName: true)

        #expect(draft.provider == .openaiCompatible)
        #expect(draft.authMethod == .apiKey)
        #expect(draft.name == ConnectionPreset.custom.name)
    }

    @Test func settingsDefaultsOpenAICompatibleWithoutAStoredKeyToAPIKey() {
        var draft = AIConnectionDraft(name: "New AI Service", provider: .openai, authMethod: .apiKey)
        draft.presetId = "seed"

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

        draft.applyPreset(keyedGateway, updateDefaultName: true)

        #expect(draft.provider == .openaiCompatible)
        #expect(draft.baseURL == "https://gateway.example.com/keyed/v1")
        #expect(draft.model == "standard-model")
        #expect(draft.authMethod == .apiKey)
        #expect(draft.name == "Gateway (Keyed)")
        #expect(draft.presetId == keyedGateway.id)
    }

    @Test func hostedPresetIsConnectableInSetupWithOnlyAKey() {
        var draft = AIConnectionDraft()
        draft.applyPreset(keyedGateway, updateDefaultName: true)
        draft.changeAuthMethod(to: .apiKey)

        #expect(!draft.canConnectForSetup)
        draft.apiKey = "sk-secret"
        #expect(draft.canConnectForSetup)
        #expect(draft.presetId == keyedGateway.id)
    }

    @Test func applyPresetKeepsAUserTypedNameButFollowsPresetDefaults() {
        var custom = AIConnectionDraft(name: "My Rewriter", provider: .openai)
        custom.applyPreset(keyedGateway, updateDefaultName: true)
        #expect(custom.name == "My Rewriter")

        var defaulted = AIConnectionDraft(name: AIServiceCatalog.defaultPreset.name, provider: .openai)
        defaulted.applyPreset(keyedGateway, updateDefaultName: true)
        #expect(defaulted.name == "Gateway (Keyed)")
    }

    @Test func switchingBackToCustomClearsTheManagedEndpoint() {
        var draft = AIConnectionDraft()
        draft.applyPreset(keyedGateway, updateDefaultName: true)
        draft.applyPreset(.custom, updateDefaultName: true)

        #expect(draft.selectedPreset.isCustom)
        #expect(draft.baseURL.isEmpty)
        #expect(draft.provider == .openaiCompatible)
    }

    @Test func typingAHostedPresetURLIntoCustomStaysCustom() {
        let managedURL = AIServiceCatalog.all.first { $0.isManaged }?.baseURL
            ?? "https://gateway.example.com/keyed/v1"
        var draft = AIConnectionDraft()
        draft.applyPreset(.custom, updateDefaultName: true)

        draft.baseURL = managedURL

        #expect(draft.selectedPreset.isCustom)
    }

    @Test func switchingServiceAndBackRestoresThePreviousEndpointModelAndAuth() {
        var draft = AIConnectionDraft(
            provider: .openaiCompatible,
            model: "qwen3",
            baseURL: "https://self-hosted.example.com/v1",
            authMethod: .none)
        #expect(draft.selectedPreset.isCustom)

        draft.applyPreset(keyedGateway, updateDefaultName: true)
        #expect(draft.baseURL == "https://gateway.example.com/keyed/v1")
        #expect(draft.model == "standard-model")

        draft.applyPreset(.custom, updateDefaultName: true)
        #expect(draft.model == "qwen3")
        #expect(draft.baseURL == "https://self-hosted.example.com/v1")
        #expect(draft.authMethod == .none)
    }

    @Test func reapplyingTheCurrentPresetChangesNothing() {
        var draft = AIConnectionDraft()
        draft.model = "custom-typed-model"

        draft.applyPreset(AIServiceCatalog.defaultPreset, updateDefaultName: true)

        #expect(draft.model == "custom-typed-model")
        #expect(draft.baseURL == (AIServiceCatalog.defaultPreset.baseURL ?? ""))
    }

    @Test func resolvedParamsPreservesStoredParamsForTheSameProvider() {
        let stored = Connection(
            id: "o", name: "OpenAI", provider: .openai, model: "gpt-5.6-luna",
            keyRef: "k", params: .init(temperature: 0.7, maxTokens: 4096, reasoningEffort: "low"))
        let draft = AIConnectionDraft(connection: stored)

        #expect(draft.resolvedParams(for: stored) == stored.params)
    }

    @Test func resolvedParamsRestampsProviderDefaultsOnProviderSwitch() {
        let geminiPreset = ConnectionPreset(
            id: "gemini-fixture", name: "Gemini Fixture", provider: .gemini, defaultModel: "gemini-model")
        let stored = Connection(
            id: "o", name: "OpenAI", provider: .openai, model: "gpt-5.6-luna", keyRef: "k")
        #expect(stored.params.reasoningEffort == "none")

        var toCompat = AIConnectionDraft(connection: stored)
        toCompat.applyPreset(keyedGateway, updateDefaultName: false)
        #expect(toCompat.resolvedParams(for: stored).reasoningEffort == nil)

        var toGemini = AIConnectionDraft(connection: stored)
        toGemini.applyPreset(geminiPreset, updateDefaultName: false)
        #expect(toGemini.resolvedParams(for: stored).reasoningEffort == nil)
        #expect(toGemini.resolvedParams(for: stored).geminiThinkingLevel == "minimal")
    }
}
