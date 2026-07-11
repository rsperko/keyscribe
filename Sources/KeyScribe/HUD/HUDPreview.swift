import KeyScribeKit

enum HUDPreview {
    static let names = [
        "ready", "arming", "recording", "recording-latched", "loading-model", "transcribing",
        "rewriting", "rewriting-three-badges", "redacted-rewrite", "rewriting-with-local-transcript",
        "inserted", "copied", "copied-long-reason", "no-speech", "nothing-heard", "failed", "rewrite-fallback",
        "microphone-error", "accessibility-error",
    ]

    static func state(from arguments: [String], isDevelopmentBuild: Bool = KeyScribePaths.variant.isDev) -> HUDState? {
        guard isDevelopmentBuild,
              let index = arguments.firstIndex(of: "--hud-preview"), index + 1 < arguments.count else {
            return nil
        }
        return state(named: arguments[index + 1])
    }

    static func state(named name: String) -> HUDState? {
        switch name {
        case "ready":
            .ready(mode: "Edit Selection")
        case "arming":
            .arming(mode: "Plain Dictation")
        case "recording":
            .recording(mode: "Plain Dictation", level: 0.7, latchedTrigger: nil)
        case "recording-latched":
            .recording(mode: "Plain Dictation", level: 0.7, latchedTrigger: "Right-⌥")
        case "loading-model":
            .loadingModel(mode: "Email")
        case "transcribing":
            .transcribing(mode: "Markdown")
        case "rewriting":
            .rewriting(
                connection: "Example Service", mode: "Polish", redacted: false,
                contextCategories: ["app", "preceding text"], offerLocalTranscript: false)
        case "rewriting-three-badges":
            .rewriting(
                connection: "Example Service", mode: "Polish", redacted: true,
                contextCategories: ["app", "preceding text"], offerLocalTranscript: false)
        case "redacted-rewrite":
            .rewriting(
                connection: "Example Service", mode: "Private Note", redacted: true,
                contextCategories: [], offerLocalTranscript: false)
        case "rewriting-with-local-transcript":
            .rewriting(
                connection: "Example Service", mode: "Polish", redacted: false,
                contextCategories: ["app"], offerLocalTranscript: true)
        case "inserted":
            .complete(outcome: .inserted, mode: "Plain Dictation")
        case "copied":
            .complete(outcome: .copied(.focusChanged), mode: "Edit Selection")
        case "copied-long-reason":
            .complete(outcome: .copied(.secureField), mode: "Plain Dictation")
        case "no-speech":
            .complete(outcome: .noSpeech, mode: "Plain Dictation")
        case "nothing-heard":
            .error(message: "Nothing heard — check your microphone", action: .openMicrophoneSettings)
        case "failed":
            .complete(outcome: .failed, mode: "Plain Dictation")
        case "rewrite-fallback":
            .localFallback(outcome: .inserted, mode: "Polish")
        case "microphone-error":
            .error(message: "Nothing heard — check your microphone", action: .openMicrophoneSettings)
        case "accessibility-error":
            .error(message: "Accessibility is off", action: .openAccessibilitySettings)
        default:
            nil
        }
    }
}
