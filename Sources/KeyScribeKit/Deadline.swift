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
//
// `onSettled` fires when the operation TRULY finishes (returns or throws) — which on a wedged op is
// long after the deadline already threw. It is the only honest signal that the operation's resources
// (engine/model/decoded PCM) are actually released; callers that must not start concurrent work use
// it to gate, since a returned `DeadlineExceeded` does NOT mean the work stopped (see SingleFlightDeadline).
public func runWithDeadline<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T,
    onSettled: (@Sendable () -> Void)? = nil
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
                onSettled?()
            }
        }
    } onCancel: {
        work.cancel()
        gate.resume(.failure(CancellationError()))
    }
}

// Single-flight wrapper over runWithDeadline: at most one operation runs at a time. A deadline only
// abandons the in-flight operation (it may keep running on a wedged engine), so the gate stays closed
// until the operation TRULY settles — a second call while one is abandoned-but-alive throws `Busy`
// instead of starting a concurrent transcribe that would double the engine/model/PCM footprint.
public actor SingleFlightDeadline {
    public struct Busy: Error, Sendable {}
    private var inFlight = false

    public init() {}

    private func release() { inFlight = false }

    // `onSettled` fires when the operation TRULY finishes — on a deadline overrun that is long after `run`
    // already threw `DeadlineExceeded`, so it is the only place to observe the real duration of an
    // abandoned (slow-or-wedged) call. Fires on both the happy path and the overrun path.
    public func run<T: Sendable>(
        seconds: Double, operation: @escaping @Sendable () async throws -> T,
        onSettled: (@Sendable () -> Void)? = nil
    ) async throws -> T {
        if inFlight { throw Busy() }
        inFlight = true
        return try await runWithDeadline(seconds: seconds, operation: operation) {
            onSettled?()
            Task { await self.release() }
        }
    }
}
