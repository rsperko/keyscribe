import Foundation
import KeyScribeKit

@MainActor
final class TakeRecorder {
    enum Finalized {
        case streamed(String, milliseconds: Double)
        case fellBackToBatch(fellBehind: Bool)
        case busy
        case timedOut
        case cancelled
    }

    // Audio must exceed this before a streaming session opens, so a short utterance never pays streaming
    // inference or pins the engine lock. Above the press-time prepare/prewarm latency, so session creation
    // never races those on the lock.
    nonisolated static let streamingStartThresholdSeconds: Double = 4

    // Cap on the writer→feed backlog of undelivered PCM chunks. The healthy path stays near-empty; this
    // bounds memory for a future slow/wedged engine whose append can't keep up — overflow is dropped and the
    // driver degrades to batch. ~1024 chunks (writer polls ~5 ms) is many seconds of backlog, past the point
    // streaming has lost its latency win.
    nonisolated static let streamingBackpressureMaxChunks = 1024

    private static let levelPollInterval: Duration = .milliseconds(33)

    private var limitTask: Task<Void, Never>?
    private(set) var limitSeconds: Double?
    private(set) var deadline: ContinuousClock.Instant?
    private var levelTask: Task<Void, Never>?
    private var driver: StreamingDictationDriver?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var feedTask: Task<Void, Never>?

    nonisolated init() {}

    var isStreaming: Bool { driver != nil }

    func startStreaming(
        sampleRate: Int, makeSession: @escaping @Sendable () async throws -> any StreamingSpeechSession
    ) -> @Sendable ([Float]) -> Void {
        let policy = StreamingStartPolicy(thresholdSeconds: Self.streamingStartThresholdSeconds, sampleRate: sampleRate)
        let driver = StreamingDictationDriver(policy: policy, makeSession: makeSession)
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self, bufferingPolicy: .bufferingNewest(Self.streamingBackpressureMaxChunks))
        self.driver = driver
        self.continuation = continuation
        feedTask = Task { for await chunk in stream { await driver.ingest(chunk) } }
        return { [weak driver] chunk in
            // Writer-thread sink (off-RT, non-blocking). A dropped chunk means the feed loop fell behind (a
            // wedged/slow append), so trip the driver to batch rather than let memory grow. Off-RT, so a Task
            // here is fine; no-ops once the driver already fell back.
            if case .dropped = continuation.yield(chunk), let driver {
                Task { await driver.noteBackpressureDrop() }
            }
        }
    }

    // Wrapping the WHOLE thing — the feed-drain await AND driver.finish() — under the gate is load-bearing: a
    // wedged append hangs at `await feedTask?.value` before finalize, so bounding finalize alone wouldn't save
    // the commit. On deadline/Busy the finalize is terminal (never a same-engine batch fallback: the abandoned
    // session holds the engine's exclusive lock forever).
    func finalizeStreaming(gate: SingleFlightDeadline, timeout: Double) async -> Finalized? {
        guard let driver else { return nil }
        let continuation = continuation
        let feedTask = feedTask
        let start = DispatchTime.now()
        let outcome: StreamingDictationDriver.Outcome
        do {
            outcome = try await gate.run(seconds: timeout) {
                continuation?.finish()
                await feedTask?.value
                return await driver.finish()
            }
        } catch is SingleFlightDeadline.Busy {
            return .busy
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .timedOut
        }
        switch outcome {
        case .streamed(let text):
            return .streamed(text, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
        case .fallBackToBatch:
            return .fellBackToBatch(fellBehind: await driver.fellBehind)
        }
    }

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

    // Every terminal tears streaming down: a session still holding the engine's exclusive lock releases it.
    // Idempotent: a finalized driver's cancel is a no-op.
    func tearDown() -> Task<Void, Never>? {
        limitTask?.cancel()
        levelTask?.cancel()
        continuation?.finish()
        feedTask?.cancel()
        guard let driver else { return nil }
        return Task { await driver.cancel() }
    }
}
