import AppKit
import Testing
@testable import KeyScribe

// A promised/lazy pasteboard flavor whose data materializes slowly — stands in for a cross-process image the
// source app re-renders on demand. The provider is invoked synchronously on whatever thread requests the data.
private final class SlowDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        Thread.sleep(forTimeInterval: 1.0)
        item.setData(Data(repeating: 9, count: 1024), forType: type)
    }
}

// Regression tests for the TextInserter pasteboard guard. The bugs these lock in:
//  1. Restore saved only `.string`, silently destroying images / RTF / file lists on every dictation.
//  2. A failed round-trip write left the clipboard EMPTY, so a late ⌘V pasted nothing.
//  3. The heavyweight divert then over-corrected, dropping even a SMALL image/rich clipboard on every
//     dictation. `capture` now renders every flavor off the main actor under a byte cap, so small
//     images / webarchive survive while a 50–100 MB TIFF never stalls the main thread.
// They run against an isolated pasteboard (withUniqueName) so they need no GUI and don't touch the
// user's real clipboard. The 250ms restore delay is a timing constant tuned to a real app's paste
// latency — not unit-testable here — so it is verified by hand, not asserted.
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

        // A dictation overwrites the clipboard with its scratch text…
        pb.clearContents()
        pb.setString("scratch dictation text", forType: .string)

        snapshot.restore(to: pb)

        // …and restore brings back BOTH the text and the non-string representation.
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

    // A small image clipboard is preserved (renders off-main, fits under the cap) — the reversal of the old
    // heavyweight divert that wiped even a tiny screenshot on every dictation.
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

    // An image-only clipboard (no `.string`) is preserved, and the full restore replaces the scratch — so the
    // image returns AND the dictated text (which can include restored redacted spans) is never left behind.
    @Test func imageOnlyClipboardIsRestoredWithoutLeakingScratch() async {
        let pb = NSPasteboard.withUniqueName()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)  // no .string flavor
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = await TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch dictation text", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.data(forType: .tiff) == tiff)         // image preserved
        #expect(pb.string(forType: .string) == nil)      // scratch text not left behind
    }

    // A promised/lazy flavor that materializes slowly (a provider sleeping past the deadline) must not hang the
    // paste: capture returns on the deadline and falls back to plain text. The sub-second elapsed also proves the
    // render — and the provider it drives — ran off the main actor, so the awaiting main thread was never blocked.
    @Test func lazyFlavorThatMissesTheDeadlineFallsBackToPlainTextWithoutHanging() async {
        let pb = NSPasteboard.withUniqueName()
        let slowType = NSPasteboard.PasteboardType("com.keyscribe.test.slow")
        let item = NSPasteboardItem()
        item.setString("plain fallback", forType: .string)
        item.setDataProvider(SlowDataProvider(), forTypes: [slowType])
        pb.clearContents()
        pb.writeObjects([item])

        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = await TextInserter.PasteboardSnapshot.capture(from: pb)
        let elapsed = clock.now - start

        #expect(elapsed < .milliseconds(700))  // returned on the deadline, not after the 1s provider sleep

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: slowType) == nil)
    }

    // The gate behind the Add-to-Vocabulary prefill: empty/plain-text round-trips perfectly; any image/rich
    // flavor does not, so that clipboard is left untouched.
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
