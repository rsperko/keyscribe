import Foundation
import Testing
@testable import KeyScribeApp

@MainActor
struct HUDChannelTests {
    private final class HUDSpy: HUDPresenting {
        var states: [HUDState] = []
        var relinquished = 0
        func render(_ state: HUDState) { states.append(state) }
        func relinquishKeyFocus() { relinquished += 1 }
    }

    private let prompt = VoiceCommandChoicePrompt(id: 7, title: "Which one?", rows: [], hint: "Say a number")

    @Test func withNoChoiceEveryStateIsDrawnAsIs() {
        let spy = HUDSpy()
        let channel = HUDChannel(hud: spy)
        channel.present(.hidden)
        channel.present(.transcribing(mode: "Notes"))
        #expect(spy.states == [.hidden, .transcribing(mode: "Notes")])
        #expect(channel.lastPresented == .transcribing(mode: "Notes"))
    }

    @Test func aStateThatWouldCoverAPendingChoiceBecomesItsStatus() {
        let spy = HUDSpy()
        let channel = HUDChannel(hud: spy)
        channel.choices = { [prompt] in .init(answering: nil, pending: prompt) }
        channel.present(.hidden)
        channel.present(.error(message: "Nope", action: nil))
        channel.present(.transcribing(mode: "Notes"))
        #expect(spy.states == [
            .choice(prompt, status: .waiting(note: nil)),
            .choice(prompt, status: .waiting(note: "Nope", action: nil)),
            .transcribing(mode: "Notes"),
        ])
    }

    @Test func whileATakeAnswersAChoiceItsWorkShowsOnTheChoice() {
        let spy = HUDSpy()
        let channel = HUDChannel(hud: spy)
        channel.choices = { [prompt] in .init(answering: prompt, pending: prompt) }
        channel.present(.transcribing(mode: "Voice Commands"))
        #expect(spy.states == [.choice(prompt, status: .working)])
    }

    @Test func focusIsHandedBackThroughTheChannel() {
        let spy = HUDSpy()
        HUDChannel(hud: spy).relinquishKeyFocus()
        #expect(spy.relinquished == 1)
    }
}
