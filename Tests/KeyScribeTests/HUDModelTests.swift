import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct HUDModelTests {
    @Test func hidingKeepsTheLastCardOnScreenWhileThePanelFades() {
        let model = HUDModel()
        let prompt = VoiceCommandChoicePrompt(id: 1, title: "Which one?", rows: [], hint: "")
        let choice = HUDState.choice(prompt, status: .waiting(note: nil))
        model.state = choice
        model.state = .hidden
        #expect(model.state == .hidden)
        #expect(model.shown == choice)
        model.state = .ready(mode: "Notes")
        #expect(model.shown == .ready(mode: "Notes"))
    }
}
