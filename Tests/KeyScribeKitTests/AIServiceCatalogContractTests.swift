import Testing
@testable import KeyScribeKit

// Holds for any lineup, so it runs unchanged against a downstream catalog. AIServiceCatalogTests pins the
// public lineup and is the one test file a downstream replaces alongside AIServiceCatalog.swift.
struct AIServiceCatalogContractTests {
    @Test func defaultPresetBelongsToTheLineup() {
        #expect(AIServiceCatalog.all.contains(AIServiceCatalog.defaultPreset))
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
}
