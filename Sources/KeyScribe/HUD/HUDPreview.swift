import KeyScribeKit

enum HUDPreview {
    static let names = [
        "ready", "recording", "recording-latched", "loading-model", "transcribing",
        "rewriting", "rewriting-three-badges", "redacted-rewrite", "rewriting-with-local-transcript",
        "inserted", "copied", "copied-long-reason", "no-speech", "nothing-heard", "failed", "rewrite-fallback",
        "rewrite-fallback-reasoning", "rewrite-fallback-copied", "rewrite-fallback-copied-accessibility", "rewrite-skipped",
        "reasoning-notice",
        "microphone-error", "command-not-recognized", "command-not-recognized-long", "accessibility-error",
        "recording-countdown", "stopped-at-limit", "stopped-at-limit-local", "choice", "choice-five",
        "choice-listening", "choice-retry", "choice-heard", "choice-heard-long",
    ]

    static let reasoningLimitReason = ProviderTransportError.limitBeforeAnswer(reasoningEvidence: true).rewriteFailureReason

    static let choicePrompt = VoiceCommandChoicePrompt(
        id: 1, title: "Which one?",
        rows: [
            VoiceCommandChoiceRow(number: 1, name: "Personal Mail", detail: "Safari \u{00B7} mail.example.net", identity: "place:personal mail"),
            VoiceCommandChoiceRow(number: 2, name: "Work Mail", detail: "Google Chrome \u{00B7} inbox.example.org", identity: "place:work mail"),
        ],
        hint: "Use Right-\u{2325} and say \u{201C}two\u{201D} or \u{201C}the second one\u{201D}. Say \u{201C}cancel\u{201D} to dismiss, or give a new command.")

    static let fiveChoicePrompt = VoiceCommandChoicePrompt(
        id: 2, title: "Which one?",
        rows: (1...5).map {
            VoiceCommandChoiceRow(
                number: $0, name: $0 == 3 ? "Quarterly Planning Notes for the Platform Infrastructure Team" : "Notes \($0)",
                detail: $0 == 4 ? "com.example.notes.enterprise.preview" : "App", identity: "app:\($0)")
        },
        hint: choicePrompt.hint)

    static func state(from arguments: [String], isDevelopmentBuild: Bool = KeyScribePaths.variant.isDev) -> HUDState? {
        guard isDevelopmentBuild,
              let index = arguments.firstIndex(of: "--hud-preview"), index + 1 < arguments.count else {
            return nil
        }
        return state(named: arguments[index + 1])
    }

    static func appearance(
        from arguments: [String], isDevelopmentBuild: Bool = KeyScribePaths.variant.isDev
    ) -> HUDAppearance? {
        guard isDevelopmentBuild,
              let index = arguments.firstIndex(of: "--hud-appearance"), index + 1 < arguments.count else {
            return nil
        }
        return HUDAppearance(rawValue: arguments[index + 1])
    }

    static func state(named name: String) -> HUDState? {
        switch name {
        case "ready":
            .ready(mode: "Edit Selection")
        case "recording":
            .recording(mode: "Plain Dictation", level: 0.7, latchedTrigger: nil)
        case "recording-latched":
            .recording(mode: "Plain Dictation", level: 0.7, latchedTrigger: "Right-⌥")
        case "recording-countdown":
            .recording(mode: "Plain Dictation", level: 0.7, latchedTrigger: nil,
                       countdown: RecordingCountdown(secondsLeft: 18, totalSeconds: 30))
        case "loading-model":
            .loadingModel(mode: "Email")
        case "transcribing":
            .transcribing(mode: "Markdown")
        case "rewriting":
            .rewriting(
                connection: "Example Service", mode: "Cleanup", redacted: false,
                contextCategories: ["app", "preceding text"], offerLocalTranscript: false)
        case "rewriting-three-badges":
            .rewriting(
                connection: "Example Service", mode: "Cleanup", redacted: true,
                contextCategories: ["app", "preceding text"], offerLocalTranscript: false)
        case "redacted-rewrite":
            .rewriting(
                connection: "Example Service", mode: "Private Note", redacted: true,
                contextCategories: [], offerLocalTranscript: false)
        case "rewriting-with-local-transcript":
            .rewriting(
                connection: "Example Service", mode: "Cleanup", redacted: false,
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
            .localFallback(outcome: .inserted, mode: "Cleanup")
        case "rewrite-fallback-reasoning":
            .localFallback(outcome: .inserted, mode: "Cleanup", reason: reasoningLimitReason, connectionId: "preview-service")
        case "rewrite-fallback-copied":
            .localFallback(outcome: .copied(.focusChanged), mode: "Cleanup", reason: reasoningLimitReason, connectionId: "preview-service")
        case "rewrite-fallback-copied-accessibility":
            .localFallback(outcome: .copied(.accessibilityDenied), mode: "Cleanup", reason: reasoningLimitReason, connectionId: "preview-service")
        case "rewrite-skipped":
            .rewriteSkipped(outcome: .inserted, mode: "Cleanup", seconds: 17.5)
        case "reasoning-notice":
            .complete(
                outcome: .inserted, mode: "Cleanup",
                notice: ReasoningOutcome(kind: .notSettable).notice(service: "Example Service", model: "example-model"))
        case "microphone-error":
            .error(message: "Nothing heard — check your microphone", action: .openMicrophoneSettings)
        case "command-not-recognized":
            .error(message: "Command not recognized", action: nil, heard: HeardExcerpt(heard: "stitch to Mail"))
        case "command-not-recognized-long":
            .error(message: "Command not recognized", action: nil, heard: HeardExcerpt(heard: longHeard))
        case "accessibility-error":
            .error(message: "Accessibility is off", action: .openAccessibilitySettings)
        case "stopped-at-limit":
            .stoppedAtLimit(outcome: .inserted, limit: "5-minute", rewriteSkipped: true)
        case "stopped-at-limit-local":
            .stoppedAtLimit(outcome: .inserted, limit: "5-minute", rewriteSkipped: false)
        case "choice":
            .choice(choicePrompt, status: .waiting(note: nil))
        case "choice-five":
            .choice(fiveChoicePrompt, status: .waiting(note: nil))
        case "choice-listening":
            .choice(choicePrompt, status: .listening(latchedTrigger: nil), level: 0.6)
        case "choice-retry":
            .choice(choicePrompt, status: .waiting(note: "Choose 1\u{2013}2, say \u{201C}cancel\u{201D}, or give a new command."))
        case "choice-heard":
            .choice(choicePrompt, status: .waiting(note: nil, heard: HeardExcerpt(heard: "tube")))
        case "choice-heard-long":
            .choice(choicePrompt, status: .waiting(note: nil, heard: HeardExcerpt(heard: longHeard)))
        default:
            nil
        }
    }

    static let longHeard = "switch over to the window where I was writing the quarterly budget review notes for the "
        + "planning meeting with everyone on Thursday afternoon"
}
