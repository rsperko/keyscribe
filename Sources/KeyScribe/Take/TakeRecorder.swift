import Foundation
import KeyScribeKit

@MainActor
final class TakeRecorder {
    private static let levelPollInterval: Duration = .milliseconds(33)

    private var limitTask: Task<Void, Never>?
    private(set) var limitSeconds: Double?
    private(set) var deadline: ContinuousClock.Instant?
    private var levelTask: Task<Void, Never>?

    nonisolated init() {}

    func startLimit(seconds: Double, stillRecording: @escaping @MainActor () -> Bool, reached: @escaping @MainActor () -> Void) {
        limitTask?.cancel()
        limitSeconds = seconds
        deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        limitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, stillRecording() else { return }
            reached()
        }
    }

    func stopLimit() {
        limitTask?.cancel()
    }

    func pollLevel(_ tick: @escaping @MainActor () -> Bool) {
        levelTask?.cancel()
        levelTask = Task { @MainActor in
            while !Task.isCancelled {
                guard tick() else { return }
                try? await Task.sleep(for: Self.levelPollInterval)
            }
        }
    }

    func tearDown() {
        limitTask?.cancel()
        levelTask?.cancel()
    }
}
