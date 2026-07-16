import AppKit
import Testing
@testable import KeyScribe

// Stands in for a cross-process image the source app re-renders on demand: a promised/lazy pasteboard
// flavor whose data materializes slowly. The provider is invoked synchronously on the requesting thread.
// `delay` only needs to exceed renderBudgetSeconds (0.25) to blow the budget — keep it just over, never
// seconds: capture now renders on the MAIN thread, so every millisecond here stalls the main actor for the
// whole suite (a 1s delay starved a timing-sensitive HUD test in another file).
private final class SlowDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    static let delay: TimeInterval = 0.3

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        Thread.sleep(forTimeInterval: Self.delay)
        item.setData(Data(repeating: 9, count: 1024), forType: type)
    }
}

// Records the thread a promised flavor actually rendered on. NSPasteboard/NSPasteboardItem are
// main-thread-only, and driving CFPasteboard's XPC bridge off-main PAC-trapped in production — a defect no
// other assertion here can see, since an off-main render still returns the right bytes.
private final class ThreadProbeDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var rendered: Bool?

    var renderedOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return rendered
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock()
        rendered = Thread.isMainThread
        lock.unlock()
        item.setData(Data([1]), forType: type)
    }
}

// Regression tests for four bugs in the TextInserter pasteboard guard: restore once saved only
// `.string` (destroying images/RTF/file lists), a failed round-trip write once left the clipboard
// EMPTY (a late ⌘V pasted nothing), the fix for that then over-corrected by dropping even a SMALL
// image/rich clipboard, and the fix for THAT rendered flavors off the main actor — which PAC-trapped in
// production on a promised/lazy flavor. `capture` now renders every flavor on the main actor,
// synchronously, under a byte cap and a render budget: small images survive, a 50–100 MB or wedged TIFF
// falls back to plain text. Runs against an isolated pasteboard (withUniqueName), so no GUI and no
// touching the user's real clipboard. The 250ms restore delay is a timing constant tuned to real paste
// latency — not unit-testable, verified by hand.
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

        pb.clearContents()
        pb.setString("scratch dictation text", forType: .string)

        snapshot.restore(to: pb)

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

    // Reversal of the old heavyweight divert that wiped even a tiny screenshot on every dictation.
    @Test func smallImageClipboardIsPreservedNotDropped() {
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

        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: .tiff) == tiff)
    }

    // The full restore replaces the scratch entirely, so the dictated text (which can include restored
    // redacted spans) is never left behind alongside the restored image.
    @Test func imageOnlyClipboardIsRestoredWithoutLeakingScratch() {
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

        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("scratch dictation text", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.data(forType: .tiff) == tiff)
        #expect(pb.string(forType: .string) == nil)
    }

    // The budget bounds the render ACROSS flavors, not within one: it is only checked between
    // `data(forType:)` calls. Two slow flavors, so the bound holds whichever order `types` reports — the
    // first render spends the budget, the second never starts and capture falls back to plain text.
    @Test func lazyFlavorsThatBlowTheBudgetFallBackToPlainText() {
        let pb = NSPasteboard.withUniqueName()
        let slowA = NSPasteboard.PasteboardType("com.keyscribe.test.slowA")
        let slowB = NSPasteboard.PasteboardType("com.keyscribe.test.slowB")
        let item = NSPasteboardItem()
        item.setString("plain fallback", forType: .string)
        item.setDataProvider(SlowDataProvider(), forTypes: [slowA, slowB])
        pb.clearContents()
        pb.writeObjects([item])

        let started = Date()
        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)
        let elapsed = Date().timeIntervalSince(started)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        // Two slow flavors, so the outcome holds whichever order `types` reports: the first render spends the
        // budget and every later flavor bails.
        #expect(elapsed < SlowDataProvider.delay * 2)
        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: slowA) == nil)
        #expect(pb.data(forType: slowB) == nil)
    }

    // The accepted cost of rendering on the main actor: macOS exposes no bounded pasteboard read, so a flavor
    // already rendering cannot be interrupted — it runs to completion and IS captured even though it outlasts
    // the budget. Pins the trade deliberately, so a future change can't quietly "fix" the stall by moving the
    // render back off-main. Sole flavor, so no other type's budget check can bail this to plain text first.
    @Test func aSlowFlavorOutlastingTheBudgetStillRendersToCompletion() {
        let pb = NSPasteboard.withUniqueName()
        let slowType = NSPasteboard.PasteboardType("com.keyscribe.test.slowOnly")
        let item = NSPasteboardItem()
        item.setDataProvider(SlowDataProvider(), forTypes: [slowType])
        pb.clearContents()
        pb.writeObjects([item])

        let started = Date()
        let snapshot = TextInserter.PasteboardSnapshot.capture(from: pb)
        let elapsed = Date().timeIntervalSince(started)

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)

        #expect(elapsed >= SlowDataProvider.delay)
        #expect(elapsed > TextInserter.PasteboardSnapshot.renderBudgetSeconds)
        #expect(pb.data(forType: slowType) == Data(repeating: 9, count: 1024))
    }

    // Regression lock for the PAC trap: NSPasteboardItem is main-thread-only, so the flavor render must run
    // on the main thread. Nothing else here can catch this — an off-main render returns correct bytes and
    // only traps on a promised flavor, which is why it reached production.
    @Test func promisedFlavorRendersOnTheMainThread() {
        let pb = NSPasteboard.withUniqueName()
        let probeType = NSPasteboard.PasteboardType("com.keyscribe.test.probe")
        let provider = ThreadProbeDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [probeType])
        pb.clearContents()
        pb.writeObjects([item])

        _ = TextInserter.PasteboardSnapshot.capture(from: pb)

        #expect(provider.renderedOnMainThread == true)
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
