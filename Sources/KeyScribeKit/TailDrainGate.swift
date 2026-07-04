// Stops commit-on-release capture after the buffer covering the release instant has reached disk.
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
