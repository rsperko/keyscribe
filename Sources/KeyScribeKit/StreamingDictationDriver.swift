import Foundation

// Orchestrates one dictation's deferred-start streaming (P3-1), independent of the OS capture path: the
// controller feeds it decoded PCM chunks (`ingest`), then asks for the result at commit (`finish`) or
// aborts (`cancel`). Pure enough to unit-test with a fake session — no audio, no engine SDK.
//
// Deferred start (Fable adj. #1): no session is opened until enough audio has accumulated to be worth it
// (StreamingStartPolicy). Below the threshold the common short utterance costs no streaming inference and
// never pins the engine's exclusive lock; at the crossing the buffered chunks are replayed into the fresh
// session and every later chunk streams live. Any streaming failure (build throw, finalize throw) degrades
// to `.fallBackToBatch`, so the controller transcribes the committed audio exactly as it does today — a
// partial transcript is never surfaced.
public actor StreamingDictationDriver {
    public enum Outcome: Equatable, Sendable {
        case streamed(String)      // the session finalized; use this transcript
        case fallBackToBatch       // short clip, or streaming failed — the caller runs batch on the WAV/PCM
    }

    private let policy: StreamingStartPolicy
    private let makeSession: @Sendable () async throws -> any StreamingSpeechSession
    // Monotonic seconds, injectable so the fell-behind trip is testable without wall-clock waits.
    private let now: @Sendable () -> Double
    // If ingested audio-seconds fall this far behind wall-clock (a session's append can't keep up with
    // real-time capture), stop streaming and degrade to batch rather than silently losing the latency win
    // and doubling memory. Theoretical for Apple (append is a convert + yield); it exists for a future
    // slower streaming engine.
    private let maxLagSeconds: Double

    private var session: (any StreamingSpeechSession)?
    private var accumulatedFrames = 0
    private var pending: [[Float]] = []   // chunks buffered before the threshold is crossed
    private var failed = false            // a build/stream failure; from here on, batch owns the result
    private var cancelled = false
    private var finished = false          // finalize ran; a later defensive cancel() must not re-touch it
    private var firstIngestAt: Double?
    private var fellBehindFlag = false    // the fall-back was specifically the fell-behind trip (for logging)

    public init(policy: StreamingStartPolicy,
                maxLagSeconds: Double = 5,
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                makeSession: @escaping @Sendable () async throws -> any StreamingSpeechSession) {
        self.policy = policy
        self.maxLagSeconds = maxLagSeconds
        self.now = now
        self.makeSession = makeSession
    }

    public var didCreateSession: Bool { session != nil }
    // True only when a fall-back-to-batch was caused by the fell-behind trip; the controller logs it.
    public var fellBehind: Bool { fellBehindFlag }

    public func ingest(_ samples: [Float]) async {
        guard !failed, !cancelled, !finished else { return }
        if firstIngestAt == nil { firstIngestAt = now() }
        accumulatedFrames += samples.count

        if let session {
            do { try await session.append(samples: samples) }
            catch { await failStreaming(session) ; return }
            if laggedBehindRealtime() { fellBehindFlag = true; await failStreaming(session) }
            return
        }

        pending.append(samples)
        guard policy.shouldStartSession(accumulatedFrames: accumulatedFrames) else { return }
        do {
            let opened = try await makeSession()
            do {
                for chunk in pending { try await opened.append(samples: chunk) }
            } catch {
                await opened.cancel()   // a replayed chunk failed to resample — release the lock
                failed = true
                pending.removeAll()
                return
            }
            pending.removeAll()
            session = opened
        } catch {
            failed = true
            pending.removeAll()   // batch will transcribe the committed audio; free the buffer
        }
    }

    // The controller's writer→feed buffer overflowed: session.append can't drain chunks as fast as capture
    // produces them, so the bounded feed buffer dropped one. Streaming has already lost the latency win and
    // would only grow memory, so trip the same fall-back-to-batch as the time-based fell-behind check. Runs
    // via actor reentrancy while an ingest may be suspended inside a slow append — that's the point: it does
    // not wait for the wedged append to return. Batch re-transcribes the committed audio in full.
    public func noteBackpressureDrop() async {
        guard !failed, !cancelled, !finished else { return }
        fellBehindFlag = true
        if let session {
            await failStreaming(session)
        } else {
            failed = true
            pending.removeAll()
        }
    }

    // Cancel the live session and route the rest of the dictation to batch. The accumulated audio is intact
    // on disk/in PCM, so accuracy is fully preserved — only the latency win is lost.
    private func failStreaming(_ session: any StreamingSpeechSession) async {
        failed = true
        await session.cancel()
        self.session = nil
    }

    // Wall-clock has advanced more than maxLagSeconds beyond the audio we've actually ingested — the
    // session isn't keeping up with real time, so streaming has already lost its point.
    private func laggedBehindRealtime() -> Bool {
        guard let firstIngestAt, policy.sampleRate > 0 else { return false }
        let audioSeconds = Double(accumulatedFrames) / Double(policy.sampleRate)
        return (now() - firstIngestAt) - audioSeconds > maxLagSeconds
    }

    public func finish() async -> Outcome {
        finished = true
        guard !cancelled, !failed, let session else { return .fallBackToBatch }
        do {
            return .streamed(try await session.finalizeTranscript())
        } catch {
            return .fallBackToBatch
        }
    }

    public func cancel() async {
        guard !cancelled, !finished else { return }
        cancelled = true
        pending.removeAll()
        if let session {
            await session.cancel()
            self.session = nil
        }
    }
}
