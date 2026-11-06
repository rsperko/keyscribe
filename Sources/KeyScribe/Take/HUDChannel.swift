import Foundation

// The only path to the HUD: a pending voice-command choice must stay readable, so anything that would
// cover it becomes its status instead.
@MainActor
final class HUDChannel {
    struct Choices {
        var answering: VoiceCommandChoicePrompt?
        var pending: VoiceCommandChoicePrompt?
    }

    private weak var hud: HUDPresenting?
    private(set) var lastPresented: HUDState?
    var choices: @MainActor () -> Choices = { Choices() }

    init(hud: HUDPresenting?) {
        self.hud = hud
    }

    func present(_ state: HUDState) {
        let shown = shown(state)
        lastPresented = shown
        hud?.render(shown)
    }

    func relinquishKeyFocus() {
        hud?.relinquishKeyFocus()
    }

    func shown(_ state: HUDState) -> HUDState {
        let choices = choices()
        if let prompt = choices.answering {
            switch state {
            case .recording(_, let level, let latched, _):
                return .choice(prompt, status: .listening(latchedTrigger: latched), level: level)
            case .transcribing, .loadingModel:
                return .choice(prompt, status: .working)
            default:
                break
            }
        }
        guard let prompt = choices.answering ?? choices.pending else { return state }
        switch state {
        case .hidden, .error, .advisory, .complete(.noSpeech, _, _):
            return .choice(prompt, status: Self.choiceWaiting(after: state))
        default:
            return state
        }
    }

    static func choiceWaiting(after state: HUDState?) -> VoiceCommandChoiceStatus {
        switch state {
        case .error(let message, let action, _): .waiting(note: message, action: action)
        case .advisory(let message): .waiting(note: message)
        case .complete(.noSpeech, _, _): .waiting(note: "No speech detected")
        case .choice(_, .waiting(let note, let heard, let action), _): .waiting(note: note, heard: heard, action: action)
        default: .waiting(note: nil)
        }
    }
}
