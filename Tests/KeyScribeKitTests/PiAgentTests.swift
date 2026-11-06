import Foundation
import KeyScribeKit
import Testing

struct PiAgentTests {
    @Test func piIsAnAgentKindWithItsOwnReloadCommandAndShippedFeatures() {
        #expect(AgentKind.pi.id == "pi")
        #expect(AgentKind.pi.displayName == "Pi")
        #expect(AgentKind.pi.reloadCommand == "/reload")
        #expect(AgentKind.pi.connectorFeatures == ["focus", "label", "readiness"])
        #expect(AgentKind.pi != AgentKind.claude)
    }

    @Test func everyAgentConnectorSharesTheVariantsConnectorSlug() {
        #expect(AppVariant.production.connectorSlug == "keyscribe")
        #expect(AppVariant.dev.connectorSlug == "keyscribe-dev")
        #expect(AppVariant.custom(displayName: "My Scribe 2", keychainService: "x").connectorSlug == "my-scribe-2")
    }
}
