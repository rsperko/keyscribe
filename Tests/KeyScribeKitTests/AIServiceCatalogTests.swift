import Foundation
import Testing
@testable import KeyScribeKit

// Pins the PUBLIC lineup; a downstream build that swaps the catalog replaces this file too, keeping
// the generic invariant tests below — every other test file stays lineup-agnostic.
struct AIServiceCatalogTests {
    @Test func lineupIsTheSevenPublicServicesInPickerOrder() {
        #expect(AIServiceCatalog.all.map(\.id) == [
            "openai", "anthropic", "gemini", "openrouter", "groq", "mistral", "custom",
        ])
    }

    @Test func defaultPresetIsOpenAIAndBelongsToTheLineup() {
        #expect(AIServiceCatalog.defaultPreset.id == "openai")
        #expect(AIServiceCatalog.all.contains(AIServiceCatalog.defaultPreset))
        #expect(AIServiceCatalog.all.contains(AIServiceCatalog.custom))
    }

    @Test func entryIdsAreUnique() {
        let ids = AIServiceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyEntrySatisfiesTheCatalogInvariants() {
        for preset in AIServiceCatalog.all {
            #expect(!preset.allowedAuthMethods.isEmpty)
            #expect(Set(preset.allowedAuthMethods).count == preset.allowedAuthMethods.count)
            #expect(preset.allowedAuthMethods.contains(preset.defaultAuthMethod))
            if let command = preset.defaultTokenCommand {
                #expect(!command.isEmpty)
                #expect(preset.allowedAuthMethods.contains(.tokenCommand))
            }
            if preset.isManaged {
                #expect(preset.baseURL?.isEmpty == false)
                #expect(!preset.defaultModel.isEmpty)
            }
        }
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
