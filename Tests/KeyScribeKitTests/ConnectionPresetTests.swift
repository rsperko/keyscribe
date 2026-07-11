import Testing
@testable import KeyScribeKit

struct ConnectionPresetTests {
    @Test func hostedPresetsAreOpenAICompatibleWithFixedEndpointAndLightweightModel() {
        for preset in [ConnectionPreset.openRouter, .groq, .mistral] {
            #expect(preset.provider == .openaiCompatible)
            #expect(preset.isManaged)
            #expect(!preset.isCustom)
            #expect(preset.baseURL?.isEmpty == false)
            #expect(!preset.defaultModel.isEmpty)
            #expect(preset.keysURL != nil)
        }
    }

    @Test func hostedPresetDefaultModels() {
        #expect(ConnectionPreset.openRouter.defaultModel == "google/gemini-3.1-flash-lite")
        #expect(ConnectionPreset.groq.defaultModel == "openai/gpt-oss-20b")
        #expect(ConnectionPreset.mistral.defaultModel == "mistral-small-latest")
    }

    @Test func hostedPresetBaseURLsHaveNoTrailingChatCompletions() {
        #expect(ConnectionPreset.openRouter.baseURL == "https://openrouter.ai/api/v1")
        #expect(ConnectionPreset.groq.baseURL == "https://api.groq.com/openai/v1")
        #expect(ConnectionPreset.mistral.baseURL == "https://api.mistral.ai/v1")
    }

    @Test func customPresetHasNoBaseURLAndIsTheEscapeHatch() {
        #expect(ConnectionPreset.custom.isCustom)
        #expect(!ConnectionPreset.custom.isManaged)
        #expect(ConnectionPreset.custom.baseURL == nil)
        #expect(ConnectionPreset.custom.pickerLabel == "Custom (OpenAI-compatible)")
    }

    @Test func presetIdsAreUnique() {
        let ids = ConnectionPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func matchingResolvesHostedPresetFromBaseURLIgnoringTrailingSlashAndCase() {
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: "https://openrouter.ai/api/v1").id == "openrouter")
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: "https://api.groq.com/openai/v1/").id == "groq")
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: "HTTPS://API.MISTRAL.AI/V1").id == "mistral")
    }

    @Test func matchingFallsBackToCustomForUnknownOpenAICompatibleEndpoint() {
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: "http://127.0.0.1:11234/v1").id == "custom")
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: nil).id == "custom")
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: "").id == "custom")
    }

    @Test func matchingResolvesFirstPartyProvidersByKind() {
        #expect(ConnectionPreset.matching(provider: .openai, baseURL: nil).id == "openai")
        #expect(ConnectionPreset.matching(provider: .anthropic, baseURL: nil).id == "anthropic")
        #expect(ConnectionPreset.matching(provider: .gemini, baseURL: nil).id == "gemini")
    }
}
