import Foundation

enum DeadlineResult<T: Sendable>: Sendable {
    case finished(T)
    case expired
}

final class DeadlineQueue: Sendable {
    private let queue: DispatchQueue
    private let backlog: TimeInterval

    init(label: String, backlog: TimeInterval = 0) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.backlog = backlog
    }

    func run<T: Sendable>(within seconds: TimeInterval, _ work: @escaping @Sendable () -> T) async -> DeadlineResult<T> {
        await run(within: seconds) { _ in work() }
    }

    func run<T: Sendable>(
        within seconds: TimeInterval, _ work: @escaping @Sendable (_ isCurrent: () -> Bool) -> T
    ) async -> DeadlineResult<T> {
        let gate = Gate()
        let reply = Reply<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DeadlineResult<T>, Never>) in
                reply.attach(continuation)
                if Task.isCancelled, gate.close() { reply.send(.expired) }
                let backlog = backlog
                queue.async {
                    guard gate.isOpen else { return }
                    if backlog > 0 {
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                            if gate.close() { reply.send(.expired) }
                        }
                    }
                    let value = work { gate.isOpen }
                    if gate.close() { reply.send(.finished(value)) }
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds + backlog) {
                    if gate.close() { reply.send(.expired) }
                }
            }
        } onCancel: {
            if gate.close() { reply.send(.expired) }
        }
    }

    private final class Reply<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<DeadlineResult<T>, Never>?
        private var early: DeadlineResult<T>?

        func attach(_ continuation: CheckedContinuation<DeadlineResult<T>, Never>) {
            let ready: DeadlineResult<T>? = lock.withLock {
                guard let early else { self.continuation = continuation; return nil }
                return early
            }
            if let ready { continuation.resume(returning: ready) }
        }

        func send(_ result: DeadlineResult<T>) {
            let waiting: CheckedContinuation<DeadlineResult<T>, Never>? = lock.withLock {
                guard let continuation else { early = result; return nil }
                self.continuation = nil
                return continuation
            }
            waiting?.resume(returning: result)
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
