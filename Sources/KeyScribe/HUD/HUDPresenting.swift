import CoreGraphics
import KeyScribeKit

// A single repair action an error HUD can offer (ui_design.md §5: one clear next step). Only used
// where a concrete fix exists — otherwise the state offers nothing rather than a misleading Retry.
enum HUDErrorAction: Equatable {
    case openMicrophoneSettings
    case openAccessibilitySettings
    case openSpeechModels

    var buttonTitle: String {
        switch self {
        case .openMicrophoneSettings: "Open Microphone Settings"
        case .openAccessibilitySettings: "Open Accessibility Settings"
        case .openSpeechModels: "Open Speech Models"
        }
    }
}

struct RecordingCountdown: Equatable {
    let secondsLeft: Int
    let totalSeconds: Int

    init(secondsLeft: Int, totalSeconds: Int) {
        self.secondsLeft = secondsLeft
        self.totalSeconds = totalSeconds
    }

    init?(remaining: Double, warningSeconds: Double) {
        guard remaining <= warningSeconds else { return nil }
        self.init(secondsLeft: max(0, Int(remaining.rounded(.up))), totalSeconds: Int(warningSeconds.rounded(.up)))
    }

    var fractionLeft: Double {
        totalSeconds > 0 ? Double(secondsLeft) / Double(totalSeconds) : 0
    }

    var clockText: String {
        String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60)
    }
}

struct VoiceCommandChoicePrompt: Equatable {
    let id: Int
    let title: String
    let rows: [VoiceCommandChoiceRow]
    let hint: String

    var announcement: String {
        let rows = rows.map { "\($0.number), \($0.name), \($0.detail)" }
        return ([title] + rows + [hint]).joined(separator: ". ")
    }
}

enum VoiceCommandChoiceStatus: Equatable {
    case waiting(note: String?, heard: HeardExcerpt? = nil, action: HUDErrorAction? = nil)
    case listening(latchedTrigger: String?)
    case working
}

enum HUDState: Equatable {
    case hidden
    case ready(mode: String)
    case recording(mode: String?, level: Float, latchedTrigger: String?, countdown: RecordingCountdown? = nil)
    case loadingModel(mode: String)
    case transcribing(mode: String, status: String? = nil)
    case rewriting(connection: String, mode: String, redacted: Bool, contextCategories: [String], offerLocalTranscript: Bool)
    case localFallback(outcome: DictationOutcome, mode: String)
    case complete(outcome: DictationOutcome, mode: String)
    case commandDone(summary: String, detail: String = HUDState.commandDetail)
    case stoppedAtLimit(outcome: DictationOutcome, limit: String, rewriteSkipped: Bool)
    case error(message: String, action: HUDErrorAction?, heard: HeardExcerpt? = nil)
    case advisory(message: String)
    case choice(VoiceCommandChoicePrompt, status: VoiceCommandChoiceStatus, level: Float = 0)
}

enum HUDIndicator: Equatable {
    case none
    case choice
    case ready
    case preparing
    case recording
    case processing
    case complete
    case warning
    case limit
    case error
    case advisory
}

extension HUDState {
    var indicator: HUDIndicator {
        switch self {
        case .hidden:
            return .none
        case .ready:
            return .ready
        case .recording:
            return .recording
        case .loadingModel:
            return .preparing
        case .transcribing, .rewriting:
            return .processing
        case .complete, .commandDone:
            return .complete
        case .localFallback:
            return .warning
        case .stoppedAtLimit:
            return .limit
        case .error:
            return .error
        case .advisory:
            return .advisory
        case .choice(_, .waiting, _):
            return .choice
        case .choice(_, .listening, _):
            return .recording
        case .choice(_, .working, _):
            return .processing
        }
    }

    var primaryText: String? {
        switch self {
        case .hidden:
            return nil
        case .ready(let mode):
            return mode
        case .recording(let mode, _, _, _):
            return mode
        case .loadingModel(let mode):
            return mode
        case .transcribing(let mode, _):
            return mode
        case .rewriting(_, let mode, _, _, _):
            return mode
        case .localFallback(let outcome, _):
            if case .copied = outcome { return "Copied without rewriting" }
            return "Inserted without rewriting"
        case .complete(let outcome, _):
            return Self.completePrimary(outcome)
        case .commandDone(let summary, _):
            return summary
        case .stoppedAtLimit(_, let limit, _):
            return "Stopped at the \(limit) limit"
        case .error(let message, _, _), .advisory(let message):
            return message
        case .choice(let prompt, _, _):
            return prompt.title
        }
    }

    var errorAction: HUDErrorAction? {
        switch self {
        case .error(_, let action, _), .choice(_, .waiting(_, _, let action), _): action
        default: nil
        }
    }

    var secondaryText: String? {
        switch self {
        case .ready:
            return "Next dictation"
        case .recording(_, _, _, let countdown?):
            return "Stops in \(countdown.clockText)"
        case .recording(_, _, let latchedTrigger, nil):
            return latchedTrigger.map { "Listening — tap \($0) again to stop" } ?? "Listening"
        case .loadingModel:
            return "Loading speech model…"
        case .transcribing(_, let status):
            return status ?? "Transcribing"
        case .rewriting(let connection, _, _, _, _):
            return "Rewriting with \(connection)"
        case .complete(.copied(let reason), _), .localFallback(.copied(let reason), _),
             .stoppedAtLimit(.copied(let reason), _, _):
            return Self.copiedSecondary(reason)
        case .stoppedAtLimit(_, _, let rewriteSkipped):
            return rewriteSkipped
                ? "Inserted without rewriting — dictate again to continue"
                : "Inserted — dictate again to continue"
        case .complete(_, let mode):
            return mode
        case .commandDone(_, let detail):
            return detail
        case .localFallback:
            return "Rewrite could not be completed"
        case .choice(_, .waiting(let note, let heard, _), _):
            return heard?.text ?? note
        case .choice(_, .listening(let latchedTrigger), _):
            return latchedTrigger.map { "Listening \u{2014} tap \($0) again to stop" } ?? "Listening"
        case .choice(_, .working, _):
            return "Transcribing"
        case .error(_, _, let heard):
            return heard?.text
        case .advisory:
            return nil
        case .hidden:
            return nil
        }
    }

    var secondaryIsHeardExcerpt: Bool {
        switch self {
        case .error(_, _, _?), .choice(_, .waiting(_, _?, _), _): true
        default: false
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
        case .complete(.copied(let reason), _), .localFallback(.copied(let reason), _),
             .stoppedAtLimit(.copied(let reason), _, _):
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
            // Says only what the insert path can prove. A field that turns secure after the commit-time probe
            // is caught here but may already have been rewritten, so this must not claim "kept local" (X-1).
            return "Password field — copied to the clipboard. Paste with ⌘V."
        case .appChanged, .focusChanged, .unknownTarget:
            return "Focus changed while \(Branding.appName) was working"
        }
    }

    var recordingCountdown: RecordingCountdown? {
        if case .recording(_, _, _, let countdown) = self { return countdown }
        return nil
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
        case .hidden, .ready:
            return nil
        case .recording(_, _, _, let countdown?):
            return "Recording stops in \(countdown.secondsLeft) seconds"
        case .recording:
            return "Recording"
        case .loadingModel:
            return "Loading speech model"
        case .transcribing(_, let status):
            return status ?? "Transcribing"
        case .rewriting(let connection, _, _, _, _):
            return "Rewriting with \(connection)"
        case .localFallback, .complete, .commandDone, .stoppedAtLimit, .error, .advisory:
            return [primaryText, secondaryText].compactMap { $0 }.joined(separator: ". ")
        case .choice(let prompt, _, _):
            return prompt.announcement
        }
    }

    // A retained list is announced once; later edges announce only what changed about it.
    func voiceOverAnnouncement(after previous: HUDState) -> String? {
        guard case .choice(let prompt, let status, _) = self,
              case .choice(let shown, _, _) = previous, shown.id == prompt.id else { return voiceOverAnnouncement }
        switch status {
        case .waiting(let note, let heard, _): return heard?.text ?? note
        case .listening: return "Recording"
        case .working: return "Transcribing"
        }
    }

    var isWaitingForChoice: Bool {
        if case .choice(_, .waiting, _) = self { return true }
        return false
    }

    var panelWidth: CGFloat {
        if case .choice = self { return 320 }
        return 280
    }

    // The cancellable states that are also VISIBLE (machine.state stays .transcribing through the cloud
    // rewrite). The HUD takes key focus in these so ESC cancels locally. Arming is cancellable but shows no
    // HUD, so ESC does not reach us there — the trigger itself cancels an arming dictation (handleCommit).
    var holdsKeyFocus: Bool {
        switch self {
        case .transcribing(_, _?): return false
        case .recording, .loadingModel, .transcribing, .rewriting: return true
        case .choice(_, .listening, _), .choice(_, .working, _): return true
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

extension HUDState {
    static let commandDetail = "Voice command"
    static let commandStillRunningDetail = "Started, still running"
}
