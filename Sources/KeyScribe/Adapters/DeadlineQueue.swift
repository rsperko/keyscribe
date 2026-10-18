import Foundation

enum DeadlineResult<T: Sendable>: Sendable {
    case finished(T)
    case expired
}

final class DeadlineQueue: Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T: Sendable>(within seconds: TimeInterval, _ work: @escaping @Sendable () -> T) async -> DeadlineResult<T> {
        await run(within: seconds) { _ in work() }
    }

    func run<T: Sendable>(
        within seconds: TimeInterval, _ work: @escaping @Sendable (_ isCurrent: () -> Bool) -> T
    ) async -> DeadlineResult<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<DeadlineResult<T>, Never>) in
            let gate = Gate()
            queue.async {
                guard gate.isOpen else { return }
                let value = work { gate.isOpen }
                if gate.close() { continuation.resume(returning: .finished(value)) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                if gate.close() { continuation.resume(returning: .expired) }
            }
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false

        var isOpen: Bool { lock.withLock { !closed } }

        func close() -> Bool {
            lock.withLock {
                guard !closed else { return false }
                closed = true
                return true
            }
        }
    }
}
