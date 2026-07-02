// Decides when a commit-on-release dictation may stop the audio engine without clipping the tail.
//
// An AVAudioEngine input tap accumulates `bufferSize` frames before each callback, so at the moment
// the trigger is released the buffer holding the final word is still filling and has not been
// delivered. Stopping the engine then drops it. The gate keeps the engine running until a delivered
// buffer's audio is known to cover the release instant, then signals stop.
//
// Buffers carry the mach host time of their first sample. The release instant is sampled with the
// same clock. The first buffer whose start is at or after release is delivered strictly after the
// buffer that contained release, so seeing it proves the release-containing buffer already reached
// disk. When the tap supplies no valid host time, a buffer count bounds the wait instead.
public struct TailDrainGate: Sendable {
    public enum Outcome: Equatable, Sendable { case keepDraining, stop }

    private let releaseHostTime: UInt64
    private let maxBuffersBeforeStop: Int
    private var buffersSeen = 0

    public init(releaseHostTime: UInt64, maxBuffersBeforeStop: Int = 4) {
        self.releaseHostTime = releaseHostTime
        self.maxBuffersBeforeStop = max(1, maxBuffersBeforeStop)
    }

    public mutating func observe(bufferStartHostTime: UInt64?) -> Outcome {
        guard let start = bufferStartHostTime else {
            buffersSeen += 1
            return buffersSeen >= maxBuffersBeforeStop ? .stop : .keepDraining
        }
        return start >= releaseHostTime ? .stop : .keepDraining
    }
}
