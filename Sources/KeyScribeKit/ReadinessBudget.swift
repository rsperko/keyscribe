import Foundation

// How long one capture start may take to reach its first buffer. Not a constant, because the device that
// will actually deliver can change after the wait is sized: a failed bind re-reads the system default, and a
// restart can rebind onto a new route. Sizing from the initial target alone is how a Bluetooth route inherits
// a local device's short deadline.
//
// So a slower transport RAISES the window, never lowers it. Raises must land before the slow work is
// attempted, not after it succeeds — the configure/start being waited on is itself what blocks.
public final class ReadinessBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Double

    public init(allowed: Double) { self.allowed = allowed }

    public var allowedSeconds: Double { lock.withLock { allowed } }

    // A route that momentarily looked local must not shorten a Bluetooth wait already granted.
    public func allow(atLeast seconds: Double) {
        lock.withLock { allowed = max(allowed, seconds) }
    }
}
