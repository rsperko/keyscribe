import Foundation

// Removes the leading silence an engine choked on, keeping one VAD chunk of pre-roll so the first word's
// onset survives. Trimming harder degrades sharply (agent_notes/parakeet_silent_bug_recovery: 0.512 s of
// pre-roll still recovers the repro, 0.768 s turns it into a different word). Trailing audio is untouched.
public enum LeadingSilenceTrim {
    public static let preRollSeconds = SpeechPresenceGate.chunkSeconds

    // `speechStart` is held as time, not a sample index: the VAD always chunks at 16 kHz while capture can be
    // 24 kHz (Qwen3), so the boundary only converts at the engine's own rate.
    public static func trimming(samples: [Float], sampleRate: Int, speechStart: TimeInterval) -> [Float] {
        let boundary = max(0, speechStart - preRollSeconds)
        let index = min(Int(boundary * Double(sampleRate)), samples.count)
        return Array(samples[index...])
    }
}
