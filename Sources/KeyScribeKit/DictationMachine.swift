public enum DictationOutcome: Equatable, Sendable {
    case inserted
    case copied(FallbackReason)
    case noSpeech
    case failed
}

// The full lifecycle of one dictation. `isBusy`, `isCancellable`, and transition guards derive from
// this enum so controller-side state cannot drift from the machine.
public enum DictationState: Equatable, Sendable {
    case idle
    case arming
    case recording
    case cancellingBringUp
    case transcribing
    case inserting
    case finished(DictationOutcome)
}

public struct DictationMachine: Sendable {
    public private(set) var state: DictationState = .idle

    public init() {}

    public var isBusy: Bool {
        switch state {
        case .idle, .finished: return false
        case .arming, .recording, .cancellingBringUp, .transcribing, .inserting: return true
        }
    }

    // Never cancellable mid-insert: text may already be landing.
    public var isCancellable: Bool {
        switch state {
        case .arming, .recording, .transcribing: return true
        case .idle, .cancellingBringUp, .inserting, .finished: return false
        }
    }

    @discardableResult
    public mutating func beginArming() -> Bool {
        guard !isBusy else { return false }
        state = .arming
        return true
    }

    @discardableResult
    public mutating func markRecording() -> Bool {
        guard case .arming = state else { return false }
        state = .recording
        return true
    }

    // A release/ESC arrived before the mic was live; the caller waits for bring-up teardown.
    @discardableResult
    public mutating func beginCancellingBringUp() -> Bool {
        guard case .arming = state else { return false }
        state = .cancellingBringUp
        return true
    }

    @discardableResult
    public mutating func beginTranscribing() -> Bool {
        guard case .recording = state else { return false }
        state = .transcribing
        return true
    }

    // Guarded so a second terminal path cannot double-insert.
    @discardableResult
    public mutating func beginInserting() -> Bool {
        guard case .transcribing = state else { return false }
        state = .inserting
        return true
    }

    public mutating func finish(_ outcome: DictationOutcome) { state = .finished(outcome) }

    public mutating func cancel() { state = .idle }

    public static func outcome(for decision: InsertionDecision) -> DictationOutcome {
        switch decision {
        case .insert: return .inserted
        case .clipboardFallback(let reason): return .copied(reason)
        }
    }

    // Silence is keyed off the HEARD transcript, not finalText — so command-only output like "\n" (real
    // content) survives — but finalText must still be non-empty to insert.
    public static func outcomeForTranscript(finalText: String, heard: String, decision: InsertionDecision) -> DictationOutcome {
        let spoke = heard.contains { !$0.isWhitespace }
        guard spoke, !finalText.isEmpty else { return .noSpeech }
        return outcome(for: decision)
    }
}
