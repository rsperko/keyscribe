import AppKit
import Foundation
import Testing
@testable import KeyScribe

// A paste that detaches its clipboard-restore (awaitSettle: false, the fast dictation path) must not let
// the next paste snapshot its still-present scratch text as the user's clipboard — otherwise that scratch
// text (which can hold a just-restored redacted span) gets restored back and persists. These drive the
// scratch/restore coordinator on a PRIVATE pasteboard, so no real clipboard is touched and no ⌘V is
// synthesized (postKey, orthogonal to the restore ordering, is skipped).
@MainActor
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

        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func anInlineSettleRestoresTheUserClipboard() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)

        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }
}
