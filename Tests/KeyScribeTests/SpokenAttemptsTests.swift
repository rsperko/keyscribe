import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct SpokenAttemptsTests {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test func anEntrysLinkGoesWhenItsAttemptExpires() {
        let clock = Clock()
        let attempts = SpokenAttempts(now: { clock.now })
        let linked = attempts.begin(text: "docs: Done.", voice: "af_heart")
        attempts.link(linked, to: "e1")
        #expect(attempts.linkedEntries == 1)
        clock.now += SpokenAttemptLog.keptFor + 1
        _ = attempts.begin(text: "docs: Next.", voice: "af_heart")
        #expect(attempts.attempt(forEntry: "e1") == nil)
        #expect(attempts.linkedEntries == 0)
    }

    @Test func anEntrysLinkGoesWhenNewerAttemptsPushItsAttemptOut() {
        let attempts = SpokenAttempts()
        for index in 0...SpokenAttemptLog.maxAttempts {
            attempts.link(attempts.begin(text: "reply \(index)", voice: "af_heart"), to: "e\(index)")
        }
        #expect(attempts.attempt(forEntry: "e0") == nil)
        #expect(attempts.linkedEntries == SpokenAttemptLog.maxAttempts)
    }

    @Test func aReplyNothingPlayedForSaysTheOutputWasNotReadAndEveryReportNamesTheVoiceLibrary() {
        let unplayed = SpokenAttempts.environment(includingOutput: false)
        #expect(unplayed.contains(.init(label: "Output", value: "not read: the natural voice\u{2019}s audio didn\u{2019}t play")))
        #expect(unplayed.contains { $0.label == "FluidAudio" })
        #expect(SpokenAttempts.environment(includingOutput: true).contains { $0.label == "FluidAudio" })
    }

    @Test func anAttemptNothingSavedIsDroppedWhenItsPlaybackEnds() {
        let attempts = SpokenAttempts()
        let replay = attempts.begin(text: "docs: Done.", voice: "af_heart")
        attempts.ended(replay)
        #expect(attempts.attempt(replay) == nil)
    }

    @Test func anAttemptWaitingOnItsHistoryWriteOutlivesItsPlaybackUntilTheWriteAnswers() {
        let attempts = SpokenAttempts()
        let saved = attempts.begin(text: "docs: Done.", voice: "af_heart")
        attempts.awaitLink(saved)
        attempts.ended(saved)
        _ = attempts.begin(text: "a notice", voice: "af_heart")
        #expect(attempts.attempt(saved) != nil)
        attempts.link(saved, to: "e1")
        #expect(attempts.attempt(forEntry: "e1")?.id == saved)

        let failed = attempts.begin(text: "docs: Again.", voice: "af_heart")
        attempts.awaitLink(failed)
        attempts.ended(failed)
        attempts.link(failed, to: nil)
        #expect(attempts.attempt(failed) == nil)

        let stillPlaying = attempts.begin(text: "docs: Later.", voice: "af_heart")
        attempts.awaitLink(stillPlaying)
        attempts.link(stillPlaying, to: nil)
        #expect(attempts.attempt(stillPlaying) != nil)
        attempts.ended(stillPlaying)
        #expect(attempts.attempt(stillPlaying) == nil)
    }

    @Test func heldAudioIsRemovedFromMemoryWhenItExpiresWithoutAnyOtherActivity() async {
        let clock = Clock()
        let attempts = SpokenAttempts(now: { clock.now }, wait: { delay in
            await MainActor.run { clock.now += Double(delay.components.seconds) }
        })
        var changes = 0
        attempts.onChange = { changes += 1 }
        let held = attempts.begin(text: "docs: Done.", voice: "af_heart")
        attempts.awaitLink(held)
        attempts.link(held, to: "e1")
        for _ in 0..<200 where attempts.heldCount > 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(attempts.heldCount == 0)
        #expect(attempts.linkedEntries == 0)
        #expect(changes >= 3)
    }
}
