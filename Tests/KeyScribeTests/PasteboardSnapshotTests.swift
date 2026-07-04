import AppKit
import Testing
@testable import KeyScribe

// Regression tests for the TextInserter pasteboard guard. The bugs these lock in:
//  1. Restore saved only `.string`, silently destroying images / RTF / file lists on every dictation.
//  2. A failed round-trip write left the clipboard EMPTY, so a late ⌘V pasted nothing.
// They run against an isolated pasteboard (withUniqueName) so they need no GUI and don't touch the
// user's real clipboard. The 250ms restore delay is a timing constant tuned to a real app's paste
// latency — not unit-testable here — so it is verified by hand, not asserted.
@MainActor
struct PasteboardSnapshotTests {
    @Test func restoresAllTypesNotJustString() {
        let pb = NSPasteboard.withUniqueName()
        let binaryType = NSPasteboard.PasteboardType("com.keyscribe.test.binary")
        let item = NSPasteboardItem()
        item.setString("the user's note", forType: .string)
        item.setData(Data([0xDE, 0xAD, 0xBE, 0xEF]), forType: binaryType)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)

        // A dictation overwrites the clipboard with its scratch text…
        pb.clearContents()
        pb.setString("scratch dictation text", forType: .string)

        snapshot.restore(to: pb)

        // …and restore brings back BOTH the text and the non-string representation.
        #expect(pb.string(forType: .string) == "the user's note")
        #expect(pb.data(forType: binaryType) == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func restoreNeverLeavesAContentfulSnapshotEmpty() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("keepme", forType: .string)
        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "keepme")
    }

    @Test func emptySnapshotRestoresToEmpty() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == nil)
    }

    @Test func oversizedSnapshotFallsBackToPlainText() {
        let pb = NSPasteboard.withUniqueName()
        let binaryType = NSPasteboard.PasteboardType("com.keyscribe.test.large")
        let item = NSPasteboardItem()
        item.setString("plain fallback", forType: .string)
        item.setData(Data(repeating: 7, count: 9 * 1024 * 1024), forType: binaryType)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: binaryType) == nil)
    }

    // Even a SMALL image clipboard diverts to the plain-text snapshot: `capture` must not materialize a
    // heavyweight flavor (an image/PDF/media/file-URL) whose promised data it would only discard — the byte
    // cap can't help because the render (a 50–100 MB TIFF) already stalled the main actor before it fires.
    @Test func imageClipboardDivertsToPlainTextWithoutMaterializing() {
        let pb = NSPasteboard.withUniqueName()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        #expect(tiff.count < 8 * 1024 * 1024)  // well under the byte cap — divert is type-driven, not size-driven

        let item = NSPasteboardItem()
        item.setString("plain fallback", forType: .string)
        item.setData(tiff, forType: .tiff)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: .tiff) == nil)
    }

    // An image-only (or file-only) clipboard has no `.string` flavor, so the heavyweight divert snapshots
    // it as plain-text nil. Restore must still CLEAR the scratch paste — otherwise the dictated text (which
    // can include just-restored redacted spans) is left on the user's clipboard.
    @Test func imageOnlyClipboardRestoreClearsScratchNotLeaksIt() {
        let pb = NSPasteboard.withUniqueName()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        let item = NSPasteboardItem()
        item.setData(image.tiffRepresentation!, forType: .tiff)  // no .string flavor
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch dictation text", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == nil)
        #expect(pb.data(forType: .tiff) == nil)
    }

    @Test func copyToClipboardReportsVerifiedPlainTextWrite() {
        let pb = NSPasteboard.withUniqueName()
        #expect(TextInserter.copyToClipboard("copied", to: pb))
        #expect(pb.string(forType: .string) == "copied")
    }

    @Test func concealedCopyToClipboardReportsVerifiedPlainTextWrite() {
        let pb = NSPasteboard.withUniqueName()
        #expect(TextInserter.copyToClipboard("secret", concealed: true, to: pb))
        #expect(pb.string(forType: .string) == "secret")
        #expect(pb.pasteboardItems?.first?.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) != nil)
    }
}
