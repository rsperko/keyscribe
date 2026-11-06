import Foundation
import KeyScribeKit
import os

@MainActor
final class Transcriber {
    private let log = Logger(subsystem: "com.keyscribe.app", category: "dictation")
    private(set) var gate = SingleFlightDeadline()
    private var busyStreak = 0
    private var busyStreakStartedAt: Double?
    private static let busyStreakLimit = 3
    private static let busyBackstopSeconds: Double = 600
    var timeoutOverride: Double?

    func transcribe(
        audioSeconds: Double, biasTerms: [String], engine: any SpeechEngine, url: URL, samples: [Float]?,
        reading: SpeechPresenceReading?, recovery: RecoveryProgress
    ) async throws -> String {
        let timeout = timeoutOverride ?? max(30, audioSeconds * 20)
        let result = try await gate.run(seconds: timeout) { () async throws -> TranscribeResult in
            let firstStart = DispatchTime.now()
            // Prefer the in-memory PCM when the engine accepts it; fall back to the WAV otherwise.
            let first: String
            if engine.supportsSampleInput, let samples {
                first = try await engine.transcribe(
                    samples: samples, sampleRate: engine.captureSampleRate, biasTerms: biasTerms)
            } else {
                first = try await engine.transcribe(wavURL: url, biasTerms: biasTerms)
            }
            guard first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return TranscribeResult(text: first)
            }
            // "No output, some sound" — the engine returned nothing on a take VAD heard speech in, after
            // provable leading silence. Parakeet TDT v3 collapses to all-blank on exactly that shape,
            // but nothing here is engine-specific: the gate is the
            // declared sample capability, never an identity. A nonempty engine annotation (`[BLANK_AUDIO]`) is
            // the engine asserting blank audio, not a silent failure — it is nonempty here, so it never
            // retries. Streamed transcripts never reach this call.
            func skip(_ reason: String) -> TranscribeResult {
                TranscribeResult(text: first, decision: RecoveryDecision(attempted: false, outcome: reason))
            }
            guard reading?.modelUsed == true else { return skip("skipped-vad-fail-open") }
            guard let speechStart = reading?.speechStart else { return skip("skipped-speech-in-first-chunk") }
            guard engine.supportsSampleInput else { return skip("skipped-wav-only-engine") }
            guard let samples else { return skip("skipped-no-pcm") }
            // Trim BEFORE committing to the retry: speechStart can sit exactly one chunk in, where the 256 ms
            // pre-roll reaches back to the take's start and the "trim" is the original PCM. Re-running the
            // engine on identical input can only burn the deadline for the same answer.
            let trimmed = LeadingSilenceTrim.trimming(
                samples: samples, sampleRate: engine.captureSampleRate, speechStart: speechStart)
            guard trimmed.count < samples.count else { return skip("skipped-trim-removed-nothing") }
            // The two attempts share ONE deadline — extending it would weaken the wedge protection it exists
            // for. The trimmed input is strictly shorter, so the first attempt's cost is an upper bound on the
            // retry's: skip rather than risk spending the deadline and reporting a spurious timeout.
            let firstElapsed = Self.seconds(since: firstStart)
            guard timeout - firstElapsed >= firstElapsed * Self.retryBudgetMargin else {
                return skip("skipped-deadline-budget")
            }
            let removed = Double(samples.count - trimmed.count) / Double(engine.captureSampleRate)
            recovery.noteRetryStarted(trimmedSeconds: removed)
            let second: String
            do {
                second = try await engine.transcribe(
                    samples: trimmed, sampleRate: engine.captureSampleRate, biasTerms: biasTerms)
            } catch {
                // The engine already returned nothing once; a failed repair does not make that a different,
                // generic failure. Report it as what it is — the model produced no text — via the empty
                // response the caller already knows how to name.
                return TranscribeResult(
                    text: "",
                    decision: RecoveryDecision(attempted: true, outcome: "retry-error: \(error)", trimmedSeconds: removed))
            }
            return TranscribeResult(
                text: second,
                decision: RecoveryDecision(
                    attempted: true,
                    outcome: second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "retry-still-empty" : "recovered",
                    trimmedSeconds: removed))
        }
        // Only a result the GATE ACCEPTED is the dictation's outcome, so the decision is logged here and never
        // from inside the closure. A closure abandoned at the deadline keeps running and can still return
        // `recovered` — logging in there would race the deadline's terminal and could record a success for a
        // dictation the user saw fail. An abandoned closure never reaches this line; the deadline catch in
        // the caller owns that line instead.
        if let decision = result.decision {
            logRecovery(engine: engine, audioSeconds: audioSeconds, reading: reading, decision: decision)
        }
        return result.text
    }

    func noteBusyRejection() {
        let now = ProcessInfo.processInfo.systemUptime
        let streakStart = busyStreakStartedAt ?? now
        busyStreakStartedAt = streakStart
        busyStreak += 1
        let backstopElapsed = now - streakStart >= Self.busyBackstopSeconds
        guard busyStreak >= Self.busyStreakLimit || backstopElapsed else { return }
        log.error("transcribe gate wedged for \(now - streakStart, privacy: .public)s after \(self.busyStreak, privacy: .public) rejection(s) — rebuilding the gate")
        gate = SingleFlightDeadline()
        resetBusyStreak()
    }

    func resetBusyStreak() {
        busyStreak = 0
        busyStreakStartedAt = nil
    }

    // Load jitter headroom on the retry's budget check: the retry should cost no more than the first attempt,
    // but a machine under load can make the same work take somewhat longer.
    nonisolated static let retryBudgetMargin = 1.25

    nonisolated static func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    // What the recovery decided, carried OUT of the gate closure as a value instead of logged from inside it.
    struct RecoveryDecision: Sendable {
        let attempted: Bool
        let outcome: String
        var trimmedSeconds: Double = 0
    }

    private struct TranscribeResult: Sendable {
        let text: String
        // nil ⇔ the first pass produced text, so no recovery decision was ever reached.
        var decision: RecoveryDecision?
    }

    // Whether a retry BEGAN — the one fact the caller cannot learn from a return value, because the gate
    // abandons its closure at the deadline. It is what separates an initial-attempt deadline (a plain
    // timeout) from a deadline that landed mid-retry (the engine failing to produce text on speech).
    final class RecoveryProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var trimmedSeconds: Double?
        // Non-nil ⇔ a retry began, carrying what it trimmed for the deadline's log line.
        var retryTrimmedSeconds: Double? { lock.withLock { trimmedSeconds } }
        func noteRetryStarted(trimmedSeconds: Double) { lock.withLock { self.trimmedSeconds = trimmedSeconds } }
    }

    // Test seam: sees each recovery decision line as it is emitted. Production leaves it nil and the line goes
    // only to Log.audio, which tests cannot read back (see AGENTS.md — `log show` is unreliable here).
    var recoveryObserver: ((String) -> Void)?

    // One line per dictation that reached a recovery decision: what the engine and VAD saw, whether the retry
    // ran, and how it ended. Diagnostics only — never transcript text. Every caller is on the main actor and
    // owns the dictation's authoritative outcome, so the line always matches the terminal the user saw.
    func logRecovery(
        engine: any SpeechEngine, audioSeconds: Double, reading: SpeechPresenceReading?, decision: RecoveryDecision
    ) {
        let speechStart = reading?.speechStart.map { String(format: "%.3fs", $0) } ?? "none"
        let line = "engine=\(engine.id) audio=\(String(format: "%.2f", audioSeconds))s vad-model=\(reading?.modelUsed == true) speechStart=\(speechStart) attempted=\(decision.attempted) trimmed=\(String(format: "%.3f", decision.trimmedSeconds))s outcome=\(decision.outcome)"
        Log.audio.notice("empty-transcript recovery: \(line, privacy: .public)")
        recoveryObserver?(line)
    }
}
