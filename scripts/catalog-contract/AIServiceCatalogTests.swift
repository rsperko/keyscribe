import Testing
@testable import KeyScribeKit

// Replaces the public-lineup tests in the swapped copy. It also proves the swap took effect: without it a
// broken swap would run the permissive public catalog and pass vacuously.
struct AIServiceCatalogTests {
    @Test func lineupIsTheStandInProxyOfferedTwice() {
        #expect(AIServiceCatalog.all.map(\.id) == ["proxy", "proxy-open"])
        #expect(AIServiceCatalog.defaultPreset.allowedAuthMethods == [.tokenCommand])
    }

    @Test func noPresetOffersAnAPIKey() {
        for preset in AIServiceCatalog.all + [AIServiceCatalog.custom] {
            #expect(!preset.allowedAuthMethods.contains(.apiKey))
        }
    }

    @Test func permitsOnlyTheProxyEndpoint() {
        #expect(AIServiceCatalog.permits(Connection(
            id: "c", name: "c", provider: .openaiCompatible, model: "m", keyRef: "k",
            baseUrl: "https://PROXY.example.com/v1/")))
        #expect(!AIServiceCatalog.permits(Connection(
            id: "c", name: "c", provider: .openaiCompatible, model: "m", keyRef: "k",
            baseUrl: "https://elsewhere.example.com/v1")))
        #expect(!AIServiceCatalog.permits(Connection(
            id: "c", name: "c", provider: .gemini, model: "m", keyRef: "k")))
    }
}
