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

// Run `operation` but throw `DeadlineExceeded` once `seconds` elapse, even if `operation` ignores
// cancellation. A structured task group awaits its children at scope exit, so a wedged CoreML/MLX call
// that never observes cancellation would suspend the group past the deadline. Instead the operation runs
// as an UNSTRUCTURED task: at the deadline we cancel it (best-effort) and return immediately, abandoning
// it to finish in the background with its result discarded. Parent cancellation propagates through
// onCancel; the losing timer is cancelled on the happy path.
//
// `onSettled` fires when the operation TRULY finishes — on a wedged op, long after the deadline threw.
// It is the only honest signal that its resources (engine/model/decoded PCM) are released; callers that
// must not start concurrent work gate on it, since `DeadlineExceeded` does NOT mean the work stopped
// (see SingleFlightDeadline).
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
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
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
    // Distinguishes an operation's own throw (settled) from the deadline/cancel machinery's throws by origin,
    // not type, so an op that itself throws Cancellation/Deadline still releases synchronously.
    private struct OperationFailure: Error, @unchecked Sendable { let underlying: any Error }
    private var inFlight = false
    private var generation = 0

    public init() {}

    // True while an operation runs AND while a deadline-abandoned one has not yet truly settled — a
    // wedged call still holds the gate even after its deadline throws.
    public var isBusy: Bool { inFlight }

    private func release(generation gen: Int) {
        if gen == generation { inFlight = false }
    }

    public func run<T: Sendable>(
        seconds: Double, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // A cancel that lands between the caller deciding to transcribe and this gate entry must not start
        // the operation: it runs as an unstructured task that holds the gate until it TRULY settles, so a
        // doomed transcribe/finalize for an already-cancelled dictation would wedge the next one Busy.
        try Task.checkCancellation()
        if inFlight { throw Busy() }
        inFlight = true
        generation += 1
        let gen = generation
        do {
            let result = try await runWithDeadline(seconds: seconds, operation: {
                do { return try await operation() }
                catch { throw OperationFailure(underlying: error) }
            }) {
                Task { await self.release(generation: gen) }
            }
            release(generation: gen)
            return result
        } catch let failure as OperationFailure {
            release(generation: gen)
            throw failure.underlying
        } catch {
            throw error
        }
    }
}
