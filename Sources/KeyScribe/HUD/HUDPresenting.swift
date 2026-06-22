import KeyScribeKit

enum HUDState: Equatable {
    case hidden
    case ready(mode: String)
    case recording(mode: String, level: Float)
    case transcribing(mode: String)
    case rewriting(connection: String, redacted: Bool, contextCategories: [String], offerLocalTranscript: Bool)
    case localFallback(outcome: DictationOutcome, mode: String)
    case complete(outcome: DictationOutcome, mode: String)
    case error(String)
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
            return "Transcribing locally"
        case .rewriting(let connection, _, _, _):
            return "Polishing with \(connection)"
        case .localFallback(let outcome, _):
            if case .copied = outcome { return "Copied local transcript instead of inserting" }
            return "Inserted local transcript"
        case .complete(let outcome, _):
            return Self.completePrimary(outcome)
        case .error(let message):
            return message
        }
    }

    var secondaryText: String? {
        switch self {
        case .ready:
            return "Next dictation"
        case .recording:
            return "Listening locally"
        case .transcribing(let mode):
            return mode
        case .rewriting(_, let redacted, let contextCategories, _):
            if redacted { return "Best-effort redaction" }
            let labels = contextCategories.compactMap(HistoryEntry.contextLabel)
            return labels.isEmpty ? "Cloud rewrite" : labels.joined(separator: " · ")
        case .complete(.copied, _), .localFallback(.copied, _):
            return "Focus changed while KeyScribe was working"
        case .complete(_, let mode):
            return mode
        case .localFallback:
            return "Rewrite could not be completed"
        case .error, .hidden:
            return nil
        }
    }

    var offersPasteLast: Bool {
        switch self {
        case .complete(.copied, _), .localFallback(.copied, _):
            return true
        default:
            return false
        }
    }

    var offersLocalTranscript: Bool {
        if case .rewriting(_, _, _, let offer) = self { return offer }
        return false
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
}
