public enum DictationOutcome: Equatable, Sendable {
    case inserted
    case copied(FallbackReason)
    case noSpeech
    case failed(String)
}

// The full lifecycle of one dictation. `arming` (mic bring-up in flight, not yet live) and
// `cancellingBringUp` (a release/ESC landed before the mic came up, awaiting teardown) are first-class
// states so the controller no longer mirrors them in side flags — `isBusy`/`isCancellable` and every
// transition guard derive from this one enum, which is what makes flag-drift bugs unrepresentable.
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

    // ESC-cancellable only while the mic is arming/live or during transcribe/rewrite — never mid-insert,
    // where the text is already landing and a cancel would race finishInsertion, nor while already tearing
    // a cancelled bring-up down.
    public var isCancellable: Bool {
        switch state {
        case .arming, .recording, .transcribing: return true
        case .idle, .cancellingBringUp, .inserting, .finished: return false
        }
    }

    // idle/finished → arming. Rejected if a dictation is already in flight so overlapping presses can't
    // start a second capture.
    @discardableResult
    public mutating func beginArming() -> Bool {
        guard !isBusy else { return false }
        state = .arming
        return true
    }

    // arming → recording: the mic went live.
    @discardableResult
    public mutating func markRecording() -> Bool {
        guard case .arming = state else { return false }
        state = .recording
        return true
    }

    // arming → cancellingBringUp: a release/ESC arrived before the mic was live and a bring-up is still
    // settling; the caller waits for that teardown before returning to idle.
    @discardableResult
    public mutating func beginCancellingBringUp() -> Bool {
        guard case .arming = state else { return false }
        state = .cancellingBringUp
        return true
    }

    // recording → transcribing: commit-on-release.
    @discardableResult
    public mutating func beginTranscribing() -> Bool {
        guard case .recording = state else { return false }
        state = .transcribing
        return true
    }

    // transcribing → inserting. Guarded so a second insert (escape hatch racing the in-flight task) is a
    // no-op instead of a double insert.
    @discardableResult
    public mutating func beginInserting() -> Bool {
        guard case .transcribing = state else { return false }
        state = .inserting
        return true
    }

    // Any state → finished(outcome). A terminal (error, no-speech, inserted) can be reached from arming
    // onward, so this is unconditional by design.
    public mutating func finish(_ outcome: DictationOutcome) { state = .finished(outcome) }

    // Any state → idle. Used by both the cancel paths and the bring-up-cancellation teardown.
    public mutating func cancel() { state = .idle }

    public static func outcome(for decision: InsertionDecision) -> DictationOutcome {
        switch decision {
        case .insert: return .inserted
        case .clipboardFallback(let reason): return .copied(reason)
        }
    }

    // "Did the user speak?" keys off the HEARD (raw, post annotation-blanking) transcript — never the
    // finalText — so whitespace-only silence (or a blanked "[BLANK_AUDIO]") is noSpeech, while a
    // command-only utterance ("insert new line") whose finalText is a bare control char ("\n") is real
    // content, not silence. There must also be something to insert: a finalText the pipeline stripped
    // to empty (e.g. a spoken trigger phrase it consumed) is noSpeech, not a phantom insert.
    public static func outcomeForTranscript(finalText: String, heard: String, decision: InsertionDecision) -> DictationOutcome {
        let spoke = heard.contains { !$0.isWhitespace }
        guard spoke, !finalText.isEmpty else { return .noSpeech }
        return outcome(for: decision)
    }
}
