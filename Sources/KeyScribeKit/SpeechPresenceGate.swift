public enum SpeechPresence: Equatable, Sendable {
    case speech
    case noSpeech
}

public struct SpeechPresenceGate: Sendable {
    public static let gateThreshold: Float = 0.30
    public static let silenceFloor: Float = 1e-4

    public static func evaluate(chunkProbabilities: [Float], peak: Float) -> SpeechPresence {
        if peak < silenceFloor { return .noSpeech }
        guard !chunkProbabilities.isEmpty else { return .speech }
        return chunkProbabilities.contains { $0 >= gateThreshold } ? .speech : .noSpeech
    }
}
