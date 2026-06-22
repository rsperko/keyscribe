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

    public static func outcomeForTranscript(_ transcript: String, decision: InsertionDecision) -> DictationOutcome {
        guard transcript.contains(where: { !$0.isWhitespace }) else { return .noSpeech }
        return outcome(for: decision)
    }
}
