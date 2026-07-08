import AppKit
import Foundation
import Testing
@testable import KeyScribe

// A paste that detaches its clipboard-restore (awaitSettle: false, the fast dictation path) must not let
// the next paste snapshot its still-present scratch text as the user's clipboard — otherwise that scratch
// text (which can hold a just-restored redacted span) gets restored back and persists. These drive the
// scratch/restore coordinator on a PRIVATE pasteboard, so no real clipboard is touched and no ⌘V is
// synthesized (postKey, orthogonal to the restore ordering, is skipped). Serialized because the coordinator
// keeps process-wide pending-restore state that the dictation state machine only ever touches one at a time.
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

        // The next paste begins while A's restore is still pending; it must drain A first, so it snapshots
        // the real USER_ORIGINAL rather than "dictationA".
        let second = await TextInserter.beginScratchPaste("dictationB", on: pb)
        #expect(second != nil)
        await TextInserter.settleScratch(second!, awaitSettle: true)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    // awaitSettle: true restores detached, so drain before asserting the clipboard is back.
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

    // A copy landing during the async snapshot must be preserved, not clobbered by the scratch write.
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

    // The bounded stabilize loop re-captures across successive mid-capture copies and preserves the last
    // one, so a second (or third) copy racing the recovery snapshot is not lost either.
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

    // With no next interaction to drain it, the scratch stays put (a stalled target still reads our ⌘V,
    // not the user's old clipboard) and the backstop restores the user's clipboard on its own.
    @Test func theBackstopRestoresWhenNothingElseDrains() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false)
        #expect(pb.string(forType: .string) == "dictation")   // held, not restored on a short timer

        var restored = false
        for _ in 0..<40 {
            if pb.string(forType: .string) == "USER_ORIGINAL" { restored = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(restored)
    }

    // A clipboard that changes on every capture never stabilizes; the paste fails closed rather than write
    // scratch over the churning copy, leaving the user's clipboard untouched.
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
}
