import Foundation

// Deferred-start decision for streaming transcription (P3-1). Streaming only pays off past a minimum
// dictation length: below it, opening a session that would immediately be replayed-then-finalized wastes
// inference on the common short utterance and needlessly pins the engine's exclusive lock, so the batch
// transcribe at commit is cheaper. This pure value type maps a threshold (seconds) to a frame count and
// answers "has enough audio accumulated to open a session yet?" — the controller holds off creating any
// session until it flips, then replays the accumulated frames into the fresh session and continues live.
public struct StreamingStartPolicy: Equatable, Sendable {
    // The deferred start is load-bearing: it must sit above the press-time prepare/prewarm latency so a
    // session never opens while those still hold the engine's exclusive lock. Clamp a floor so a mis-set
    // threshold can't collapse the deferral and reorder session creation ahead of prepare.
    public static let minimumThresholdSeconds: Double = 2

    public let thresholdSeconds: Double
    public let sampleRate: Int

    public init(thresholdSeconds: Double, sampleRate: Int) {
        self.thresholdSeconds = max(Self.minimumThresholdSeconds, thresholdSeconds)
        self.sampleRate = sampleRate
    }

    // Frames of accumulated audio that must arrive before a session is worth opening. A non-positive
    // sample rate can never accumulate meaningfully, so it reports an unreachable threshold (never start).
    public var thresholdFrames: Int {
        guard sampleRate > 0 else { return .max }
        return Int((thresholdSeconds * Double(sampleRate)).rounded())
    }

    public func shouldStartSession(accumulatedFrames: Int) -> Bool {
        accumulatedFrames >= thresholdFrames
    }
}
