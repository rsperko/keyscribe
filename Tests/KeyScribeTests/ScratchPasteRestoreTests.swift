import AppKit
import KeyScribeKit
import Foundation
import Testing
@testable import KeyScribeApp

// A paste that detaches its clipboard-restore (awaitSettle: false, the fast dictation path) must not let
// the next paste snapshot its still-present scratch text as the user's clipboard — otherwise that scratch
// text (which can hold a just-restored redacted span) gets restored back and persists. Runs against a
// PRIVATE pasteboard (no real clipboard, no synthesized ⌘V). Serialized because the coordinator keeps
// process-wide pending-restore state the dictation state machine only ever touches one at a time.
@MainActor
@Suite(.serialized)
struct ScratchPasteRestoreTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("keyscribe-test-\(UUID().uuidString)"))
    }

    @Test func detachedRestoreIsDrainedBeforeTheNextPasteSnapshots() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let first = await TextInserter.beginScratchPaste("dictationA", on: pb)
        #expect(first != nil)
        #expect(pb.string(forType: .string) == "dictationA")
        await TextInserter.settleScratch(first!, awaitSettle: false)

        // Begins while A's restore is still pending; must drain A first, or it would snapshot "dictationA".
        let second = await TextInserter.beginScratchPaste("dictationB", on: pb)
        #expect(second != nil)
        await TextInserter.settleScratch(second!, awaitSettle: true)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    // awaitSettle: true still restores detached, so drain before asserting the clipboard is back.
    @Test func aSubmitSettleRestoresTheUserClipboardInTheBackground() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func aCopyLandingDuringCaptureIsPreservedNotClobbered() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        var fired = false
        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, afterCapture: {
            if !fired { fired = true; pb.clearContents(); pb.setString("USER_COPIED_LATE", forType: .string) }
        })
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "USER_COPIED_LATE")
    }

    // The stabilize loop re-captures across successive mid-capture copies, so a second or third copy
    // racing the recovery snapshot is not lost either.
    @Test func repeatedCopiesDuringCaptureStabilizeToTheLatest() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let values = ["COPY_1", "COPY_2"]
        var i = 0
        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, afterCapture: {
            if i < values.count { pb.clearContents(); pb.setString(values[i], forType: .string); i += 1 }
        })
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "COPY_2")
    }

    // With no next interaction to drain it, the backstop must restore the user's clipboard on its own —
    // and at the mode's own restore delay, not a fixed one. The hold is the window in which a user ⌘V
    // pastes the dictation a second time, so its length is the behavior under test.
    @Test func theBackstopRestoresAtTheConfiguredDelay() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false)
        #expect(pb.string(forType: .string) == "dictation")

        #expect(await restores(pb, to: "USER_ORIGINAL", withinMs: 900))
    }

    // A target that needs longer can buy it back; the default must not be the only option.
    @Test func aLongerConfiguredDelayHoldsTheScratchLonger() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 3000)

        try? await Task.sleep(for: .milliseconds(700))
        #expect(pb.string(forType: .string) == "dictation")
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    // IH-1: the spoken "insert clipboard contents" command read the pending scratch — the previous
    // dictation — instead of the user's clipboard, because it never drained.
    @Test func readingTheClipboardDrainsAPendingRestore() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false)

        #expect(TextInserter.currentClipboardText(on: pb) == "USER_ORIGINAL")
    }

    private func restores(_ pb: NSPasteboard, to expected: String, withinMs: Int) async -> Bool {
        var waited = 0
        while waited < withinMs {
            if pb.string(forType: .string) == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        return pb.string(forType: .string) == expected
    }

    // ── Consumption-driven restore (Feature.consumptionDrivenRestore) ────────────────────────────────
    // The scratch is published as a LAZY `.string` flavor, so the target reading it is observable and the
    // clipboard can come back as soon as the paste has actually been served, instead of after a fixed
    // guess. The read through this pasteboard handle stands in for the target app's read. These live in
    // this suite rather than their own because the pending-restore state is process-wide and suites run
    // in parallel.

    @Test func aReadServesTheDictationAndRestoresWellBeforeTheBackstop() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 5000)

        #expect(pb.string(forType: .string) == "dictation")     // the target's paste is served the dictation
        #expect(await restores(pb, to: "USER_ORIGINAL", withinMs: 1000))
    }

    // A target may read the pasteboard more than once per ⌘V (reported of Chromium and Electron, not yet
    // measured here); restoring on the first read would hand a second one the user's old clipboard.
    @Test func aSecondReadInsideTheGraceStillGetsTheDictation() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 5000)

        #expect(pb.string(forType: .string) == "dictation")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pb.string(forType: .string) == "dictation")
    }

    // A clipboard manager inspecting the scratch before the ⌘V is not the paste, and must not start the
    // grace — that would restore out from under the target's own read.
    @Test func aReadBeforeThePasteDoesNotShortenTheHold() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        #expect(pb.string(forType: .string) == "dictation")     // the pre-⌘V inspection

        await TextInserter.settleScratch(
            scratch!, awaitSettle: false, restoreMs: 5000,
            pastedAt: ContinuousClock.now.advanced(by: .milliseconds(400)))

        try? await Task.sleep(for: .milliseconds(300))
        #expect(pb.string(forType: .string) == "dictation")
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    // A target that never reads (the ⌘V went nowhere) still has to get the clipboard back. The pasteboard
    // is not touched until the backstop has had time to fire: any read here would serve the lazy flavor
    // ourselves and turn this into the read-triggered path.
    @Test func noReadFallsBackToTheConfiguredBackstop() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 250)

        try? await Task.sleep(for: .milliseconds(600))
        #expect(scratch!.provider?.firstReadAt == nil)
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    // The changeCount no-clobber guard is unchanged by laziness: a copy landing before the restore wins.
    @Test func aCopyBeforeTheRestoreIsPreserved() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 5000)

        pb.clearContents()
        pb.setString("USER_COPIED", forType: .string)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "USER_COPIED")
    }

    // With the flag off nothing is published lazily, so the fixed window is the only thing that restores.
    @Test func withoutTheFlagTheScratchIsEagerAndTimerDriven() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 3000)

        #expect(pb.string(forType: .string) == "dictation")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(pb.string(forType: .string) == "dictation")     // a read did not shorten it
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    // Never stabilizes; the paste must fail closed rather than write scratch over the churning copy.
    @Test func aPersistentlyUnstableClipboardFailsClosedWithoutClobbering() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("CHURN_0", forType: .string)

        var n = 0
        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, afterCapture: {
            n += 1; pb.clearContents(); pb.setString("CHURN_\(n)", forType: .string)
        })
        #expect(scratch == nil)
        #expect(pb.string(forType: .string)?.hasPrefix("CHURN_") == true)
    }

    // ── A paste chord the active layout cannot post ──────────────────────────────────────────

    private func unpostable() throws -> ClipboardPaste {
        ClipboardPaste(keystroke: try ClipboardKeystroke(parsing: "control+☃"))
    }

    @Test func aPasteChordThatCannotBePostedReportsFailure() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let landed = await TextInserter.insertViaPaste("dictated", paste: try unpostable(), on: pb)
        #expect(!landed)
    }

    @Test func aFailedPasteRestoresTheUserClipboard() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        _ = await TextInserter.insertViaPaste("dictated", paste: try unpostable(), on: pb)
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }
}
