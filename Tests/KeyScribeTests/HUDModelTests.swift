import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct HUDModelTests {
    @Test func eachRecordingAdmissionResetsScrollingButLiveUpdatesDoNot() {
        let model = HUDModel()
        let recording = HUDState.recording(mode: "Coding agent", level: 0, latchedTrigger: nil)
        model.state = recording
        let first = model.recordingAdmission
        #expect(first == 1)
        model.state = .recording(mode: "Coding agent", level: 0.8, latchedTrigger: nil)
        #expect(model.recordingAdmission == first)
        model.state = .hidden
        model.state = recording
        #expect(model.recordingAdmission == first + 1)
        model.state = .transcribing(mode: "Coding agent")
        model.state = recording
        #expect(model.recordingAdmission == first + 2)
    }

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
