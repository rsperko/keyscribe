public enum DictationOutcome: Equatable, Sendable {
    case inserted
    case copied(FallbackReason)
    case noSpeech
    case failed(String)
}

public enum DictationState: Equatable, Sendable {
    case idle
    case recording
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
        case .recording, .transcribing, .inserting: return true
        }
    }

    public mutating func beginRecording() -> Bool {
        guard !isBusy else { return false }
        state = .recording
        return true
    }

    public mutating func beginTranscribing() { state = .transcribing }
    public mutating func beginInserting() { state = .inserting }
    public mutating func finish(_ outcome: DictationOutcome) { state = .finished(outcome) }
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
