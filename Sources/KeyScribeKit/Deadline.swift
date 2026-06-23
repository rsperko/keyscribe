import Foundation

public struct DeadlineExceeded: Error, Sendable {}

// One-shot continuation guarded across the racing tasks. set() and resume() can arrive in either
// order (an early cancel can resume before the continuation is installed), so a pending result is
// stashed and applied when the continuation lands.
private final class DeadlineContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if !done, let pending {
            done = true
            lock.unlock()
            c.resume(with: pending)
            return
        }
        continuation = c
        lock.unlock()
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        if let c = continuation {
            done = true
            continuation = nil
            lock.unlock()
            c.resume(with: result)
            return
        }
        pending = result
        lock.unlock()
    }
}

// Run `operation` but return (throw `DeadlineExceeded`) once `seconds` elapse, even if `operation`
// ignores cancellation. Structured task groups await every child at scope exit, so a wedged
// CoreML/MLX call that never observes cancellation would keep the group suspended past the deadline.
// Here the operation runs as an UNSTRUCTURED task: at the deadline we cancel it (best-effort) and
// return immediately, abandoning the task to finish in the background, its result discarded. Parent
// cancellation propagates through onCancel. The losing timer is cancelled on the happy path so no
// long timer lingers after a fast success.
public func runWithDeadline<T: Sendable>(
    seconds: Double, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let work = Task<T, Error> { try await operation() }
    let gate = DeadlineContinuation<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            gate.set(cont)
            let timeout = Task {
                try? await Task.sleep(for: .seconds(seconds))
                work.cancel()
                gate.resume(.failure(DeadlineExceeded()))
            }
            Task {
                let result: Result<T, Error>
                do { result = .success(try await work.value) }
                catch { result = .failure(error) }
                timeout.cancel()
                gate.resume(result)
            }
        }
    } onCancel: {
        work.cancel()
        gate.resume(.failure(CancellationError()))
    }
}
