import Foundation

// Qwen3-ASR decodes the whole take in one call, and its decoder stops at `maxTokens` without saying so:
// the SDK default of 448 silently dropped everything past about 2.5 minutes of speech. Short clips keep
// that default so their decode is unchanged; longer takes get room for fast speech in a token-dense
// language. The model's feature extractor drops audio past its input ceiling just as silently, so a take
// beyond it is refused rather than transcribed in part.
public enum Qwen3OutputBudget {
    public static let shortClipTokens = 448
    public static let tokensPerSecond = 8.0
    public static let maxAudioSeconds = 1200.0

    public static func maxTokens(audioSeconds: Double) -> Int {
        max(shortClipTokens, Int((audioSeconds * tokensPerSecond).rounded(.up)))
    }

    public static func accepts(audioSeconds: Double) -> Bool {
        audioSeconds <= maxAudioSeconds
    }
}
