import Foundation
import Testing
@testable import KeyScribeKit

// Pins the PUBLIC lineup. A downstream build that swaps the catalog replaces this file too; the invariants
// every lineup must keep live in AIServiceCatalogContractTests, and every other test file stays
// lineup-agnostic (scripts/check-catalog-contract.sh proves it).
struct AIServiceCatalogTests {
    @Test func lineupIsTheSevenPublicServicesInPickerOrder() {
        #expect(AIServiceCatalog.all.map(\.id) == [
            "openai", "anthropic", "gemini", "openrouter", "groq", "mistral", "custom",
        ])
    }

    @Test func defaultPresetIsOpenAIAndCustomIsInThePicker() {
        #expect(AIServiceCatalog.defaultPreset.id == "openai")
        #expect(AIServiceCatalog.all.contains(AIServiceCatalog.custom))
    }

    @Test func publicCatalogPermitsEveryConnection() {
        #expect(AIServiceCatalog.permits(Connection(
            id: "c", name: "c", provider: .openaiCompatible, model: "m", keyRef: "k",
            baseUrl: "https://anywhere.example/v1")))
        #expect(AIServiceCatalog.permits(Connection(
            id: "c", name: "c", provider: .gemini, model: "m", keyRef: "k")))
    }

    @Test func firstPartyEntriesCarryTheCurrentDefaultModels() {
        #expect(AIServiceCatalog.openAI.defaultModel == "gpt-5.6-luna")
        #expect(AIServiceCatalog.anthropic.defaultModel == "claude-haiku-4-5")
        #expect(AIServiceCatalog.gemini.defaultModel == "gemini-flash-lite-latest")
        #expect(AIServiceCatalog.custom.defaultModel.isEmpty)
    }

    @Test func entriesCarryTheirDisplayNames() {
        #expect(AIServiceCatalog.openAI.name == "OpenAI")
        #expect(AIServiceCatalog.anthropic.name == "Anthropic")
        #expect(AIServiceCatalog.gemini.name == "Gemini")
        #expect(AIServiceCatalog.custom.name == "Custom AI")
        #expect(AIServiceCatalog.custom.pickerLabel == "Custom (OpenAI-compatible)")
    }

    @Test func hostedEntriesAreOpenAICompatibleWithFixedEndpointAndLightweightModel() {
        for preset in [AIServiceCatalog.openRouter, AIServiceCatalog.groq, AIServiceCatalog.mistral] {
            #expect(preset.provider == .openaiCompatible)
            #expect(preset.isManaged)
            #expect(!preset.isCustom)
        }
    }

    @Test func hostedEntryEndpointsAndDefaultModels() {
        #expect(AIServiceCatalog.openRouter.baseURL == "https://openrouter.ai/api/v1")
        #expect(AIServiceCatalog.groq.baseURL == "https://api.groq.com/openai/v1")
        #expect(AIServiceCatalog.mistral.baseURL == "https://api.mistral.ai/v1")
        #expect(AIServiceCatalog.openRouter.defaultModel == "google/gemini-3.1-flash-lite")
        #expect(AIServiceCatalog.groq.defaultModel == "openai/gpt-oss-20b")
        #expect(AIServiceCatalog.mistral.defaultModel == "mistral-small-latest")
    }

    @Test func onlyCustomOffersAnAuthChoiceInThePublicLineup() {
        for preset in AIServiceCatalog.all where preset.id != "custom" {
            #expect(preset.allowedAuthMethods == [.apiKey])
            #expect(preset.defaultAuthMethod == .apiKey)
            #expect(!preset.offersAuthChoice)
        }
        #expect(AIServiceCatalog.custom.allowedAuthMethods == [.none, .apiKey, .tokenCommand])
        #expect(AIServiceCatalog.custom.defaultAuthMethod == .apiKey)
        #expect(AIServiceCatalog.custom.offersAuthChoice)
    }

    @Test func everyEntryButCustomLinksToAKeyConsole() {
        for preset in AIServiceCatalog.all {
            #expect((preset.keysURL == nil) == (preset.id == "custom"))
        }
    }

    @Test func matchingResolvesThePublicLineupFromStoredConnections() {
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: "https://openrouter.ai/api/v1").id == "openrouter")
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: "https://api.groq.com/openai/v1/").id == "groq")
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: "HTTPS://API.MISTRAL.AI/V1").id == "mistral")
        #expect(ConnectionPreset.matching(provider: .openaiCompatible, baseURL: "http://127.0.0.1:11234/v1").id == "custom")
        #expect(ConnectionPreset.matching(provider: .openai, baseURL: nil).id == "openai")
        #expect(ConnectionPreset.matching(provider: .anthropic, baseURL: nil).id == "anthropic")
        #expect(ConnectionPreset.matching(provider: .gemini, baseURL: nil).id == "gemini")
    }
}
