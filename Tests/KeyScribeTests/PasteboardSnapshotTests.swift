import AppKit
import Testing
@testable import KeyScribe

// Stands in for a cross-process image the source app re-renders on demand: a promised/lazy pasteboard
// flavor whose data materializes slowly. The provider is invoked synchronously on the requesting thread.
private final class SlowDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        Thread.sleep(forTimeInterval: 1.0)
        item.setData(Data(repeating: 9, count: 1024), forType: type)
    }
}

// Regression tests for three bugs in the TextInserter pasteboard guard: restore once saved only
// `.string` (destroying images/RTF/file lists), a failed round-trip write once left the clipboard
// EMPTY (a late ⌘V pasted nothing), and the fix for that then over-corrected by dropping even a SMALL
// image/rich clipboard (now `capture` renders every flavor off the main actor under a byte cap, so
// small images survive while a 50–100 MB TIFF never stalls the main thread). Runs against an isolated
// pasteboard (withUniqueName), so no GUI and no touching the user's real clipboard. The 250ms restore
// delay is a timing constant tuned to real paste latency — not unit-testable, verified by hand.
@MainActor
struct PasteboardSnapshotTests {
    @Test func restoresAllTypesNotJustString() async {
        let pb = NSPasteboard.withUniqueName()
        let binaryType = NSPasteboard.PasteboardType("com.keyscribe.test.binary")
        let item = NSPasteboardItem()
        item.setString("the user's note", forType: .string)
        item.setData(Data([0xDE, 0xAD, 0xBE, 0xEF]), forType: binaryType)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = await TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch dictation text", forType: .string)

        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "the user's note")
        #expect(pb.data(forType: binaryType) == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func restoreNeverLeavesAContentfulSnapshotEmpty() async {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("keepme", forType: .string)
        let snapshot = await TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "keepme")
    }

    @Test func emptySnapshotRestoresToEmpty() async {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let snapshot = await TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == nil)
    }

    @Test func oversizedSnapshotFallsBackToPlainText() async {
        let pb = NSPasteboard.withUniqueName()
        let binaryType = NSPasteboard.PasteboardType("com.keyscribe.test.large")
        let item = NSPasteboardItem()
        item.setString("plain fallback", forType: .string)
        item.setData(Data(repeating: 7, count: 9 * 1024 * 1024), forType: binaryType)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = await TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: binaryType) == nil)
    }

    // Reversal of the old heavyweight divert that wiped even a tiny screenshot on every dictation.
    @Test func smallImageClipboardIsPreservedNotDropped() async {
        let pb = NSPasteboard.withUniqueName()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        #expect(tiff.count < 8 * 1024 * 1024)  // well under the byte cap

        let item = NSPasteboardItem()
        item.setString("plain fallback", forType: .string)
        item.setData(tiff, forType: .tiff)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = await TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: .tiff) == tiff)
    }

    // The full restore replaces the scratch entirely, so the dictated text (which can include restored
    // redacted spans) is never left behind alongside the restored image.
    @Test func imageOnlyClipboardIsRestoredWithoutLeakingScratch() async {
        let pb = NSPasteboard.withUniqueName()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = await TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch dictation text", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.data(forType: .tiff) == tiff)
        #expect(pb.string(forType: .string) == nil)
    }

    // A provider sleeping past the deadline must not hang the paste: capture returns on the deadline and
    // falls back to plain text. The sub-second elapsed also proves the render ran off the main actor.
    @Test func lazyFlavorThatMissesTheDeadlineFallsBackToPlainTextWithoutHanging() async {
        let pb = NSPasteboard.withUniqueName()
        let slowType = NSPasteboard.PasteboardType("com.keyscribe.test.slow")
        let item = NSPasteboardItem()
        item.setString("plain fallback", forType: .string)
        item.setDataProvider(SlowDataProvider(), forTypes: [slowType])
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = await TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: slowType) == nil)
    }

    // The gate behind the Add-to-Vocabulary prefill: an image/rich flavor is left untouched.
    @Test func emptyAndPlainTextClipboardsRestorePerfectly() {
        let empty = NSPasteboard.withUniqueName()
        empty.clearContents()
        #expect(TextInserter.clipboardRestoresPerfectly(empty))

        let text = NSPasteboard.withUniqueName()
        text.clearContents()
        text.setString("just a word", forType: .string)
        #expect(TextInserter.clipboardRestoresPerfectly(text))
    }

    @Test func imageOrRichClipboardDoesNotRestorePerfectly() {
        let img = NSPasteboard.withUniqueName()
        let item = NSPasteboardItem()
        item.setString("caption", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .tiff)
        img.clearContents()
        img.writeObjects([item])
        #expect(!TextInserter.clipboardRestoresPerfectly(img))

        let rtf = NSPasteboard.withUniqueName()
        let rtfItem = NSPasteboardItem()
        rtfItem.setData(Data([0x7B, 0x5C, 0x72]), forType: .rtf)
        rtf.clearContents()
        rtf.writeObjects([rtfItem])
        #expect(!TextInserter.clipboardRestoresPerfectly(rtf))
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
