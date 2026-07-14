import Foundation
import Testing
@testable import KeyScribeKit

// Machinery-only: exercises ConnectionPreset semantics over local fixtures and the catalog contract
// members (custom), never named public-lineup entries — so a swapped downstream AIServiceCatalog keeps
// this file green. Public-lineup pinning lives in AIServiceCatalogTests.
struct ConnectionPresetTests {
    private let hosted = ConnectionPreset(
        id: "gateway-keyed", name: "Gateway (Keyed)", provider: .openaiCompatible,
        baseURL: "https://gateway.example.com/keyed/v1", defaultModel: "standard-model",
        keysURL: URL(string: "https://gateway.example.com/keys"),
        allowedAuthMethods: [.apiKey, .tokenCommand])

    private let openGateway = ConnectionPreset(
        id: "gateway-open", name: "Gateway (Open)", provider: .openaiCompatible,
        baseURL: "https://gateway.example.com/open/v1", defaultModel: "standard-model",
        allowedAuthMethods: [.none], defaultAuthMethod: Connection.AuthMethod.none)

    private let firstParty = ConnectionPreset(
        id: "first-party", name: "First Party", provider: .openai, defaultModel: "first-model")

    private var lineup: [ConnectionPreset] { [firstParty, openGateway, hosted, ConnectionPreset.custom] }

    @Test func managedPresetHasAFixedEndpointAndIsNotCustom() {
        #expect(hosted.isManaged)
        #expect(!hosted.isCustom)
        #expect(openGateway.isManaged)
        #expect(!firstParty.isManaged)
        #expect(!firstParty.isCustom)
    }

    @Test func customPresetIsTheEscapeHatch() {
        #expect(ConnectionPreset.custom.isCustom)
        #expect(!ConnectionPreset.custom.isManaged)
        #expect(ConnectionPreset.custom.baseURL == nil)
    }

    @Test func authDefaultsAreAPIKeyOnlyUnlessOverridden() {
        #expect(firstParty.allowedAuthMethods == [.apiKey])
        #expect(firstParty.defaultAuthMethod == .apiKey)
        #expect(!firstParty.offersAuthChoice)
        #expect(hosted.offersAuthChoice)
        #expect(openGateway.allowedAuthMethods == [.none])
        #expect(openGateway.defaultAuthMethod == .none)
    }

    @Test func pickerLabelDefaultsToTheNameUnlessOverridden() {
        #expect(hosted.pickerLabel == "Gateway (Keyed)")
        let overridden = ConnectionPreset(
            id: "labeled", name: "Labeled", provider: .openaiCompatible, defaultModel: "",
            pickerLabelOverride: "Labeled (OpenAI-compatible)")
        #expect(overridden.pickerLabel == "Labeled (OpenAI-compatible)")
    }

    @Test func matchingResolvesAFixedEndpointIgnoringTrailingSlashAndCase() {
        #expect(ConnectionPreset.matching(
            provider: .openaiCompatible, baseURL: "https://gateway.example.com/keyed/v1", in: lineup).id == "gateway-keyed")
        #expect(ConnectionPreset.matching(
            provider: .openaiCompatible, baseURL: "https://gateway.example.com/keyed/v1/", in: lineup).id == "gateway-keyed")
        #expect(ConnectionPreset.matching(
            provider: .openaiCompatible, baseURL: "HTTPS://GATEWAY.EXAMPLE.COM/KEYED/V1", in: lineup).id == "gateway-keyed")
    }

    @Test func matchingDisambiguatesSameHostEntriesByFullBaseURL() {
        #expect(ConnectionPreset.matching(
            provider: .openaiCompatible, baseURL: "https://gateway.example.com/open/v1", in: lineup).id == "gateway-open")
        #expect(ConnectionPreset.matching(
            provider: .openaiCompatible, baseURL: "https://gateway.example.com/keyed/v1", in: lineup).id == "gateway-keyed")
    }

    @Test func matchingFallsBackToCustomForUnknownOpenAICompatibleEndpoint() {
        #expect(ConnectionPreset.matching(
            provider: .openaiCompatible, baseURL: "https://elsewhere.example.com/v1", in: lineup).id == ConnectionPreset.custom.id)
        #expect(ConnectionPreset.matching(
            provider: .openaiCompatible, baseURL: nil, in: lineup).id == ConnectionPreset.custom.id)
        #expect(ConnectionPreset.matching(
            provider: .openaiCompatible, baseURL: "", in: lineup).id == ConnectionPreset.custom.id)
    }

    @Test func matchingResolvesFirstPartyProvidersByKindWithCustomFallback() {
        #expect(ConnectionPreset.matching(provider: .openai, baseURL: nil, in: lineup).id == "first-party")
        #expect(ConnectionPreset.matching(provider: .anthropic, baseURL: nil, in: lineup).id == ConnectionPreset.custom.id)
    }

    @Test func presetLookupFindsOnlyLineupMembers() {
        #expect(ConnectionPreset.preset(id: "gateway-open", in: lineup)?.name == "Gateway (Open)")
        #expect(ConnectionPreset.preset(id: "absent", in: lineup) == nil)
    }
}
