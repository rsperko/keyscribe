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

    // "Nothing heard" ⇔ the take's peak magnitude never cleared the digital-silence floor: a hardware/mute
    // problem, distinct from real audio with no speech. Splits the HUD's two no-speech states (UX2 phase 6d).
    public static func isNothingHeard(peak: Float) -> Bool {
        peak < silenceFloor
    }
}
