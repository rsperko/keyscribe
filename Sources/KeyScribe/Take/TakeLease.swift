import Foundation

@MainActor
final class TakeLease {
    private let wanted: @MainActor () -> Bool
    private let acting: @MainActor () -> Bool
    let abortsActuation: @Sendable () -> Bool

    init(
        stillWanted: @escaping @MainActor () -> Bool, beginActing: @escaping @MainActor () -> Bool,
        abortsActuation: @escaping @Sendable () -> Bool
    ) {
        self.wanted = stillWanted
        self.acting = beginActing
        self.abortsActuation = abortsActuation
    }

    private var acted = false

    func stillWanted() -> Bool { wanted() }

    func beginActing() -> Bool {
        acted = acting()
        return acted
    }

    func keepActing() -> Bool {
        guard stillWanted() else { return false }
        return acted || beginActing()
    }
}
