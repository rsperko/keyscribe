import Foundation
import Testing
@testable import KeyScribeKit

struct SpokenAttemptLogTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func attempt(_ id: String, at offset: TimeInterval = 0, bytes: Int = 10) -> SpokenAttempt {
        var attempt = SpokenAttempt(id: id, at: start + offset, text: "docs: Done.", voice: "af_heart")
        attempt.audio = Data(count: bytes)
        return attempt
    }

    @Test func anAttemptNoReplyKeptIsGoneWhenTheNextBegins() {
        var log = SpokenAttemptLog()
        log.begin(attempt("a"))
        #expect(log.attempt("a", now: start) != nil)
        log.begin(attempt("b", at: 1))
        #expect(log.attempt("a", now: start + 1) == nil)
        #expect(log.attempt("b", now: start + 1) != nil)
    }

    @Test func aKeptAttemptSurvivesLaterOnesIncludingARepeat() {
        var log = SpokenAttemptLog()
        log.begin(attempt("original"))
        log.keep("original")
        log.begin(attempt("repeat", at: 1))
        log.begin(attempt("next", at: 2))
        #expect(log.attempt("original", now: start + 2)?.audio == Data(count: 10))
    }

    @Test func updatesChangeOnlyTheirOwnAttempt() {
        var log = SpokenAttemptLog()
        log.begin(attempt("a"))
        log.keep("a")
        log.begin(attempt("b", at: 1))
        log.update("b", now: start + 1) { $0.playback = .interrupted }
        #expect(log.attempt("a", now: start + 1)?.playback == .preparing)
        #expect(log.attempt("b", now: start + 1)?.playback == .interrupted)
    }

    @Test func attemptsExpireAfterTheirAge() {
        var log = SpokenAttemptLog()
        log.begin(attempt("a"))
        log.keep("a")
        #expect(log.attempt("a", now: start + SpokenAttemptLog.keptFor - 1) != nil)
        #expect(log.attempt("a", now: start + SpokenAttemptLog.keptFor) == nil)
        #expect(log.nextExpiry == start + SpokenAttemptLog.keptFor)
        log.expire(now: start + SpokenAttemptLog.keptFor)
        #expect(log.attempts.isEmpty)
        #expect(log.nextExpiry == nil)
    }

    @Test func aReleasedAttemptIsNoLongerKept() {
        var log = SpokenAttemptLog()
        log.begin(attempt("a"))
        log.keep("a")
        log.release("a")
        log.begin(attempt("b", at: 1))
        #expect(log.attempts.map(\.id) == ["b"])
    }

    @Test func theOldestKeptAttemptsGoFirstPastTheCountOrTheBytes() {
        var log = SpokenAttemptLog()
        for index in 0...SpokenAttemptLog.maxAttempts {
            log.begin(attempt("\(index)", at: Double(index)))
            log.keep("\(index)")
        }
        #expect(log.attempts.count == SpokenAttemptLog.maxAttempts)
        #expect(log.attempts.first?.id == "1")

        var heavy = SpokenAttemptLog()
        let half = SpokenAttemptLog.maxAudioBytes / 2 + 1
        heavy.begin(attempt("a", bytes: half))
        heavy.keep("a")
        heavy.begin(attempt("b", at: 1, bytes: half))
        #expect(heavy.attempts.map(\.id) == ["b"])
    }

    @Test func discardingAnAttemptForgetsIt() {
        var log = SpokenAttemptLog()
        log.begin(attempt("a"))
        log.keep("a")
        log.discard(["a"])
        #expect(log.attempt("a", now: start) == nil)
        log.keep("a")
        log.begin(attempt("b", at: 1))
        #expect(log.attempts.map(\.id) == ["b"])
    }

    @Test func theReportSaysWhatWasReadAndThatTheAudioIsWhatWasGenerated() {
        var spoken = attempt("a")
        spoken.reader = .macOS
        spoken.macOSReason = "silent audio"
        spoken.playback = .finished
        spoken.details = [.init(label: "Output", value: "USB DAC, 48000 Hz")]
        spoken.segments = [.init(text: "docs: Done.", synthesis: .init(
            normalizedText: "docs done", phonemes: "dˈɑks dˈʌn", predictedDurations: [1, 4, 2], stageMilliseconds: [.init(label: "tail", value: "12.5")],
            sampleRate: 24000, measurements: .init(seconds: 1.5, peak: 0.5, rms: 0.1, clippedSamples: 0)))]
        let report = spoken.report(appName: "KeyScribe")
        for line in [
            "Text read: docs: Done.", "Voice: af_heart", "Read by: macOS voice (silent audio)", "Playback: finished",
            "Output: USB DAC, 48000 Hz", "Normalized text: docs done", "Phonemes: dˈɑks dˈʌn", "Predicted durations: 1 4 2",
            "tail 12.5", "1.50 s", "what KeyScribe generated",
        ] {
            #expect(report.contains(line), "\(line) missing from \(report)")
        }
    }

    @Test func aDiagnosticLineCarriesWhatHappenedButNoText() {
        var spoken = attempt("a")
        spoken.reader = .macOS
        spoken.macOSReason = "the natural voice took too long"
        spoken.playback = .finished
        spoken.details = [.init(label: "Voice route", value: "noise on CPU"), .init(label: "Output", value: "USB DAC, 48000 Hz"),
                          .init(label: "FluidAudio", value: "503b4bd")]
        let line = spoken.diagnosticLine
        for part in ["read-by=macos", "reason=the natural voice took too long", "playback=finished", "voice=af_heart",
                     "route=noise on CPU", "output=USB DAC, 48000 Hz", "fluidaudio=503b4bd"] {
            #expect(line.contains(part), "\(part) missing from \(line)")
        }
        #expect(!line.contains("docs"))
    }
}
