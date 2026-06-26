import KeyScribeKit

// A single repair action an error HUD can offer (ui_design.md §5: an error state gives one clear next
// step). Only used where a concrete fix exists — a failure with no safe recovery offers nothing rather
// than a misleading Retry.
enum HUDErrorAction: Equatable {
    case openMicrophoneSettings
    case openAccessibilitySettings

    var buttonTitle: String {
        switch self {
        case .openMicrophoneSettings: "Open Microphone Settings"
        case .openAccessibilitySettings: "Open Accessibility Settings"
        }
    }
}

enum HUDState: Equatable {
    case hidden
    case ready(mode: String)
    case recording(mode: String?, level: Float)
    case transcribing(mode: String)
    case rewriting(connection: String, redacted: Bool, contextCategories: [String], offerLocalTranscript: Bool)
    case localFallback(outcome: DictationOutcome, mode: String)
    case complete(outcome: DictationOutcome, mode: String)
    case error(message: String, action: HUDErrorAction?)
}

extension HUDState {
    var primaryText: String? {
        switch self {
        case .hidden:
            return nil
        case .ready(let mode):
            return mode
        case .recording(let mode, _):
            return mode
        case .transcribing:
            return "Transcribing"
        case .rewriting(let connection, _, _, _):
            return "Rewriting with \(connection)"
        case .localFallback(let outcome, _):
            if case .copied = outcome { return "Copied without rewriting" }
            return "Inserted without rewriting"
        case .complete(let outcome, _):
            return Self.completePrimary(outcome)
        case .error(let message, _):
            return message
        }
    }

    var errorAction: HUDErrorAction? {
        if case .error(_, let action) = self { return action }
        return nil
    }

    var secondaryText: String? {
        switch self {
        case .ready:
            return "Next dictation"
        case .recording:
            return "Listening"
        case .transcribing(let mode):
            return mode
        case .rewriting(_, let redacted, let contextCategories, _):
            if redacted { return "Best-effort redaction" }
            let labels = contextCategories.compactMap(HistoryEntry.contextLabel)
            return labels.isEmpty ? "Cloud rewrite" : labels.joined(separator: " · ")
        case .complete(.copied(let reason), _), .localFallback(.copied(let reason), _):
            return Self.copiedSecondary(reason)
        case .complete(_, let mode):
            return mode
        case .localFallback:
            return "Rewrite could not be completed"
        case .error, .hidden:
            return nil
        }
    }

    // The data-boundary categories for the cloud-rewrite step, as discrete badge labels rather than a
    // collapsed text line (ui_components.md). A rewrite is always cloud; redaction forces context off,
    // mirroring HistoryEntry.dataBoundaryLabels.
    var dataBoundaryBadges: [String] {
        guard case .rewriting(_, let redacted, let contextCategories, _) = self else { return [] }
        var labels = ["Cloud rewrite"]
        if redacted { labels.append("Best-effort redaction") }
        labels.append(contentsOf: contextCategories.compactMap(HistoryEntry.contextLabel))
        return labels
    }

    var offersPasteLast: Bool {
        switch self {
        case .complete(.copied(let reason), _), .localFallback(.copied(let reason), _):
            // A synthetic ⌘V is itself blocked without Accessibility, so don't offer a button that
            // can't work — the text is already on the clipboard for a manual paste.
            return reason != .accessibilityDenied
        default:
            return false
        }
    }

    private static func copiedSecondary(_ reason: FallbackReason) -> String {
        switch reason {
        case .accessibilityDenied:
            return "Accessibility is off — copied to the clipboard. Paste with ⌘V."
        case .secureField:
            return "Password field — kept local and copied to the clipboard. Paste with ⌘V."
        case .appChanged, .focusChanged, .unknownTarget:
            return "Focus changed while KeyScribe was working"
        }
    }

    var offersLocalTranscript: Bool {
        if case .rewriting(_, _, _, let offer) = self { return offer }
        return false
    }

    // The cancellable states (mirrors DictationController.isCancellable, which keeps machine.state at
    // .transcribing through the cloud rewrite). The HUD takes key focus in these so ESC cancels locally.
    var holdsKeyFocus: Bool {
        switch self {
        case .recording, .transcribing, .rewriting: return true
        default: return false
        }
    }

    private static func completePrimary(_ outcome: DictationOutcome) -> String {
        switch outcome {
        case .inserted: return "Inserted"
        case .copied: return "Copied instead of inserted"
        case .noSpeech: return "No speech detected"
        case .failed: return "Dictation failed"
        }
    }
}

@MainActor
protocol HUDPresenting: AnyObject {
    func render(_ state: HUDState)
    func relinquishKeyFocus()
}

extension HUDPresenting {
    func relinquishKeyFocus() {}
}
