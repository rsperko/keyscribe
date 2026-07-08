import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct CorrectionDestinationTests {
    @Test func listExcludesDisabledAndSystemModesButKeepsGlobal() {
        var enabledMode = Mode(id: "code", name: "Code")
        enabledMode.enabled = true
        var disabledMode = Mode(id: "email", name: "Email")
        disabledMode.enabled = false
        let systemMode = Mode.direct

        let list = CorrectionDestination.list(for: [enabledMode, disabledMode, systemMode])

        #expect(list.first == .global)
        #expect(list.contains { $0.scope == .mode("code") })
        #expect(!list.contains { $0.scope == .mode("email") })
        #expect(!list.contains { $0.scope == .mode(Mode.directId) })
    }

    @MainActor
    @Test func saveFailedMessageNamesTheRightSurface() {
        let global = CorrectionPanelController.saveFailedMessage(for: .global)
        #expect(global.contains("Advanced"))

        let mode = CorrectionPanelController.saveFailedMessage(
            for: .mode(id: "email", name: "Email"))
        #expect(mode.contains("Modes"))
        #expect(mode.contains("Email"))
    }
}
