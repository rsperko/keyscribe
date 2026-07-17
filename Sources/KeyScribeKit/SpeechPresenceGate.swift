import Foundation

public enum SpeechPresence: Equatable, Sendable {
    case speech
    case noSpeech
}

public struct SpeechPresenceGate: Sendable {
    public static let gateThreshold: Float = 0.30
    public static let silenceFloor: Float = 1e-4
    // FluidAudio VAD chunking: 4,096 samples at 16 kHz (256 ms). SDK-version-dependent, so it lives here
    // once and is pinned against the SDK's own constants by a test.
    public static let chunkSamples = 4096
    public static let chunkSampleRate = 16000
    public static let chunkSeconds = Double(chunkSamples) / Double(chunkSampleRate)

    public static func evaluate(chunkProbabilities: [Float], peak: Float) -> SpeechPresence {
        if peak < silenceFloor { return .noSpeech }
        guard !chunkProbabilities.isEmpty else { return .speech }
        return chunkProbabilities.contains { $0 >= gateThreshold } ? .speech : .noSpeech
    }

    // Start time of the first chunk that clears the same gate the take was admitted by — the proof of leading
    // silence the empty-transcript recovery needs. Nil when no chunk qualifies, or when speech starts in
    // chunk zero: there is no leading silence to remove, so nothing to retry on.
    public static func speechStart(chunkProbabilities: [Float]) -> TimeInterval? {
        guard let index = chunkProbabilities.firstIndex(where: { $0 >= gateThreshold }), index > 0 else {
            return nil
        }
        return Double(index) * chunkSeconds
    }

    // "Nothing heard" ⇔ the take's peak magnitude never cleared the digital-silence floor: a hardware/mute
    // problem, distinct from real audio with no speech. Splits the HUD's two no-speech states (UX2 phase 6d).
    public static func isNothingHeard(peak: Float) -> Bool {
        peak < silenceFloor
    }
}
