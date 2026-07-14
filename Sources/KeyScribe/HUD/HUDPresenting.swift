import CoreGraphics
import KeyScribeKit

// A single repair action an error HUD can offer (ui_design.md §5: one clear next step). Only used
// where a concrete fix exists — otherwise the state offers nothing rather than a misleading Retry.
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
    case arming(mode: String?)
    case recording(mode: String?, level: Float, latchedTrigger: String?)
    case loadingModel(mode: String)
    case transcribing(mode: String)
    case rewriting(connection: String, mode: String, redacted: Bool, contextCategories: [String], offerLocalTranscript: Bool)
    case localFallback(outcome: DictationOutcome, mode: String)
    case complete(outcome: DictationOutcome, mode: String)
    case error(message: String, action: HUDErrorAction?)
}

enum HUDIndicator: Equatable {
    case none
    case ready
    case preparing
    case recording
    case processing
    case complete
    case warning
    case error
}

extension HUDState {
    var indicator: HUDIndicator {
        switch self {
        case .hidden:
            return .none
        case .ready:
            return .ready
        case .arming:
            return .preparing
        case .recording:
            return .recording
        case .loadingModel:
            return .preparing
        case .transcribing, .rewriting:
            return .processing
        case .complete:
            return .complete
        case .localFallback:
            return .warning
        case .error:
            return .error
        }
    }

    var primaryText: String? {
        switch self {
        case .hidden:
            return nil
        case .ready(let mode):
            return mode
        case .arming(let mode):
            return mode
        case .recording(let mode, _, _):
            return mode
        case .loadingModel(let mode):
            return mode
        case .transcribing(let mode):
            return mode
        case .rewriting(_, let mode, _, _, _):
            return mode
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
        case .arming:
            return "Preparing dictation"
        case .recording(_, _, let latchedTrigger):
            return latchedTrigger.map { "Listening — tap \($0) again to stop" } ?? "Listening"
        case .loadingModel:
            return "Loading speech model…"
        case .transcribing:
            return "Transcribing"
        case .rewriting(let connection, _, _, _, _):
            return "Rewriting with \(connection)"
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

    // Cloud-rewrite data-boundary categories as discrete badges rather than one collapsed line
    // (ui_components.md). A rewrite is always cloud; redaction forces context off, mirroring
    // HistoryEntry.dataBoundaryLabels.
    var dataBoundaryBadges: [String] {
        guard case .rewriting(_, _, let redacted, let contextCategories, _) = self else { return [] }
        var labels = ["Cloud rewrite"]
        if redacted { labels.append("Best-effort redaction") }
        labels.append(contentsOf: contextCategories.compactMap(HistoryEntry.contextLabel))
        return labels
    }

    var offersPasteLast: Bool {
        switch self {
        case .complete(.copied(let reason), _), .localFallback(.copied(let reason), _):
            // A synthetic ⌘V is itself blocked without Accessibility, so don't offer a button that can't
            // work — the text is already on the clipboard for a manual paste.
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
            return "Focus changed while \(Branding.appName) was working"
        }
    }

    var offersLocalTranscript: Bool {
        if case .rewriting(_, _, _, _, let offer) = self { return offer }
        return false
    }

    var contentHeight: CGFloat {
        if offersLocalTranscript || offersPasteLast || errorAction != nil {
            return dataBoundaryBadges.isEmpty ? 92 : 104
        }
        return dataBoundaryBadges.isEmpty ? 64 : 78
    }

    // A stable VoiceOver announcement per state-change edge (ui_design.md §9). Level ticks are
    // deliberately NOT announced (HUDController.render early-returns before this is read), so a recording
    // announcement fires once on entry, never per tick. Transient/dismissal states carry none.
    var voiceOverAnnouncement: String? {
        switch self {
        case .hidden, .ready, .arming:
            return nil
        case .recording:
            return "Recording"
        case .loadingModel:
            return "Loading speech model"
        case .transcribing:
            return "Transcribing"
        case .rewriting(let connection, _, _, _, _):
            return "Rewriting with \(connection)"
        case .localFallback, .complete, .error:
            return [primaryText, secondaryText].compactMap { $0 }.joined(separator: ". ")
        }
    }

    // Mirrors DictationController.isCancellable (machine.state stays .transcribing through the cloud
    // rewrite). The HUD takes key focus in these states so ESC cancels locally.
    var holdsKeyFocus: Bool {
        switch self {
        case .arming, .recording, .loadingModel, .transcribing, .rewriting: return true
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
