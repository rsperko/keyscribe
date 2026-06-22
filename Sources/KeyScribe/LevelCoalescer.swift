import Foundation

// Bridges the per-buffer audio level callback (background thread) to a main-actor render closure
// without unbounded task fan-out: a burst of buffers overwrites a single pending level, and only one
// drain task runs at a time. The newest level always wins, which is what the HUD wants.
final class LevelCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Float?
    private var draining = false
    var onLevel: (@MainActor @Sendable (Float) -> Void)?

    func submit(_ level: Float) {
        let startDrain: Bool = lock.withLock {
            latest = level
            guard !draining else { return false }
            draining = true
            return true
        }
        guard startDrain else { return }
        Task { @MainActor in
            while let next = takeLatest() { onLevel?(next) }
        }
    }

    private func takeLatest() -> Float? {
        lock.withLock {
            guard let next = latest else { draining = false; return nil }
            latest = nil
            return next
        }
    }
}
