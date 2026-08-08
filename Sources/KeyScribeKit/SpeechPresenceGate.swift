import Foundation

// The raw values ARE the corpus vocabulary: what `--vad-probe` prints and what a manifest's
// `checks.vad.presence` must say are the same strings by construction, not by coincidence.
public enum SpeechPresence: String, Equatable, Sendable, CaseIterable {
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

    // Admission is a minimum speech duration, not a take-level max, and an empty vector suppresses
    // rather than failing open. Both are load-bearing — see AGENTS.md "Silence / no-speech behavior"
    // and corpus/blips/README.md for the measured evidence pinning this at 2.
    public static let minSpeechChunks = 2

    public static func evaluate(chunkProbabilities: [Float], peak: Float) -> SpeechPresence {
        if peak < silenceFloor { return .noSpeech }
        return chunksClearingGate(chunkProbabilities) >= minSpeechChunks ? .speech : .noSpeech
    }

    public static func chunksClearingGate(_ chunkProbabilities: [Float]) -> Int {
        chunkProbabilities.count { $0 >= gateThreshold }
    }

    public static func longestRunClearingGate(_ chunkProbabilities: [Float]) -> Int {
        var longest = 0
        var current = 0
        for p in chunkProbabilities {
            current = p >= gateThreshold ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
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
