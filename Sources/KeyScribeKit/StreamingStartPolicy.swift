import Foundation

// Deferred-start decision for streaming transcription (P3-1). Streaming only pays off past a minimum
// dictation length: below it, opening a session that's immediately replayed-then-finalized wastes inference
// on the common short utterance and pins the engine's exclusive lock, so batch transcribe at commit is
// cheaper. Maps a threshold (seconds) to a frame count and answers "enough audio to open a session yet?".
public struct StreamingStartPolicy: Equatable, Sendable {
    // Load-bearing: the deferred start must sit above the press-time prepare/prewarm latency so a session
    // never opens while those hold the engine's exclusive lock. Floor clamps a mis-set threshold so it can't
    // collapse the deferral and reorder session creation ahead of prepare.
    public static let minimumThresholdSeconds: Double = 2

    public let thresholdSeconds: Double
    public let sampleRate: Int

    public init(thresholdSeconds: Double, sampleRate: Int) {
        self.thresholdSeconds = max(Self.minimumThresholdSeconds, thresholdSeconds)
        self.sampleRate = sampleRate
    }

    // Frames that must accumulate before a session is worth opening. A non-positive sample rate reports an
    // unreachable threshold (never start).
    public var thresholdFrames: Int {
        guard sampleRate > 0 else { return .max }
        return Int((thresholdSeconds * Double(sampleRate)).rounded())
    }

    public func shouldStartSession(accumulatedFrames: Int) -> Bool {
        accumulatedFrames >= thresholdFrames
    }
}
