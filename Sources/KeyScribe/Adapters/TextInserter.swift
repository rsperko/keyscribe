import AppKit
import ApplicationServices
import CoreGraphics
import KeyScribeKit

@MainActor
enum TextInserter {
    private static let vKeyCode: CGKeyCode = 9
    private static let cKeyCode: CGKeyCode = 8
    private static let returnKeyCode: CGKeyCode = 36

    // Capture the target app's current selection via a synthesized ⌘C, then restore the user's
    // clipboard. Universal (spike-verified across native/Electron/Chromium). Returns nil if nothing
    // was copied (no selection). The selection stays highlighted, so a later paste replaces it.
    //
    // The full pasteboard (every item type — images, RTF, file URLs, not just plain text) is snapshot
    // and restored, so a dictation never destroys a non-text clipboard. The ⌘C settle is polled on
    // the changeCount instead of a blind sleep (the M0 survey hit a settle race that dropped a leading
    // character). We only restore once our ⌘C has actually overwritten the clipboard — if nothing was
    // copied (no selection) the clipboard is untouched, so an unconditional restore would be a redundant
    // rewrite that could clobber whatever another app wrote during the settle window.
    static func captureSelection(modifier: Mode.ClipboardModifier = .command) async -> String? {
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture()
        postKey(cKeyCode, flags: eventFlags(modifier))
        guard await waitForChange(since: snapshot.changeCount) else { return nil }
        let copied = pb.string(forType: .string)
        snapshot.restore()
        return copied
    }

    // Paste is the spike-confirmed default (lands across native/Electron/Chromium with a single ⌘Z
    // undo). AX-insert and synthesized typing are opt-in per mode (mode.insertion) for the few
    // targets that prefer them; both proved unreliable in the M0 survey, so each degrades to paste
    // when it can't act. The focus-race safety decision is authoritative — a clipboardFallback
    // diverts to the clipboard regardless of the mode's preferred method.
    static func perform(_ decision: InsertionDecision, method: Mode.Insertion, modifier: Mode.ClipboardModifier, text: String) async {
        switch insertionAction(decision: decision, method: method) {
        case .paste: await insertViaPaste(text, modifier: modifier)
        case .ax: await insertViaAX(text, modifier: modifier)
        case .type: await insertViaTyping(text)
        case .clipboard:
            // A secure-field divert conceals the copy so clipboard managers do not retain the password;
            // every other fallback is a normal copy the user can paste back.
            if case .clipboardFallback(.secureField) = decision { copyToClipboard(text, concealed: true) }
            else { copyToClipboard(text) }
        }
    }

    static func insertViaPaste(_ text: String, modifier: Mode.ClipboardModifier = .command) async {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture()
        // Confirm the dictated text is actually the pasteboard's string before synthesizing ⌘V. Without
        // this, a failed or raced write (writeObjects returning false, or a clipboard manager re-owning the
        // board) left the user's PREVIOUS clipboard in place and ⌘V pasted that instead of the dictation.
        // If we cannot verify the write, restore the user's clipboard and fire nothing — never paste stale
        // data. The dictation is still recoverable via "Paste last dictation".
        guard writeScratchVerified(text) else {
            snapshot.restore()
            Log.insertion.error("paste: pasteboard write unverified; skipped ⌘V to avoid pasting stale clipboard")
            return
        }
        // clearContents()/writeObjects() bump changeCount synchronously, so the verified write is already
        // reflected here — stamp it now. The old fixed 30ms sleep added latency and risked stamping a
        // pre-write count (then scratchSurvived misreads our own write as a foreign one and skips the
        // restore, leaving the dictated text on the clipboard).
        let stamp = pb.changeCount
        postKey(vKeyCode, flags: eventFlags(modifier))
        // Give the target time to consume ⌘V before we touch the clipboard again — restoring too early
        // clobbers the paste (M0 proved ~200ms is needed; restore is best-effort). A paste produces no
        // observable pasteboard event, so we wait out a bounded window, but bail early if anything wrote
        // after our scratch (target or clipboard manager) — then we must not restore over it.
        if await scratchSurvived(stamp, timeoutMs: 250, stepMs: 25) { snapshot.restore() }
    }

    private static func scratchSurvived(_ stamp: Int, timeoutMs: Int, stepMs: Int) async -> Bool {
        let pb = NSPasteboard.general
        var waited = 0
        while waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(stepMs))
            waited += stepMs
            if pb.changeCount != stamp { return false }
        }
        return pb.changeCount == stamp
    }

    // Our temporary clipboard write for the paste, read-back verified. Marked transient + concealed so
    // clipboard managers do not capture the dictated text (it can contain just-redacted-then-restored
    // sensitive spans). Returns false if, after a few attempts, the pasteboard's string is not the
    // dictated text — so the caller refuses to ⌘V rather than paste whatever stale content is there.
    private static func writeScratchVerified(_ text: String, attempts: Int = 3) -> Bool {
        let pb = NSPasteboard.general
        for _ in 0..<attempts {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            pb.clearContents()
            if pb.writeObjects([item]) && pb.string(forType: .string) == text { return true }
        }
        return false
    }

    // Polls the general pasteboard's changeCount until it bumps past `since`, up to ~500ms. A
    // synthesized ⌘C settles asynchronously; the M0 survey saw a fixed sleep miss it and drop a
    // leading character, so we wait for the actual change instead of guessing a duration.
    private static func waitForChange(since: Int, timeoutMs: Int = 500, stepMs: Int = 10) async -> Bool {
        let pb = NSPasteboard.general
        var waited = 0
        while waited < timeoutMs {
            if pb.changeCount != since { return true }
            try? await Task.sleep(for: .milliseconds(stepMs))
            waited += stepMs
        }
        return pb.changeCount != since
    }

    // AX-insert: set the focused element's selected text, which replaces the selection or inserts at
    // the cursor. We do NOT trust the set's `.success` return — Chromium/Electron return success but
    // no-op it, silently dropping the text. Instead we only take the AX path when we can read the
    // field's value back and confirm it actually changed; otherwise we fall back to paste, which
    // lands everywhere. So `insert` uses AX on native fields and paste on web/Electron, never losing text.
    static func insertViaAX(_ text: String, modifier: Mode.ClipboardModifier = .command) async {
        if axInsertVerified(text) {
            Log.insertion.notice("ax-insert: succeeded")
            return
        }
        Log.insertion.notice("ax-insert: unverified here, falling back to paste")
        await insertViaPaste(text, modifier: modifier)
    }

    private static func axInsertVerified(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return false }
        let element = focusedRef as! AXUIElement
        guard let before = axValue(element) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        return axValue(element).map { $0 != before } ?? false
    }

    private static func axValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // Synthesized typing: post each character as a Unicode key event (no keycode mapping, so it
    // covers any glyph). Unlike AX, posting always "succeeds" — there is no signal that the target
    // accepted it — so there is no automatic fallback; a mode opts into this knowing it is best-effort.
    static func insertViaTyping(_ text: String) async {
        let src = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            let units = Array(String(character).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: keyDown) else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // A mode's post-insert `submit` keystroke: a synthesized Return (optionally with ⇧ or ⌘) that
    // submits/sends in the target. The caller only invokes this after a VERIFIED insert — never on a
    // clipboard fallback — so the keystroke always reaches the app that received the text.
    static func submit(_ submit: Mode.Submit) async {
        let flags: CGEventFlags
        switch submit {
        case .none: return
        case .return: flags = []
        case .shiftReturn: flags = .maskShift
        case .cmdReturn: flags = .maskCommand
        }
        postKey(returnKeyCode, flags: flags)
    }

    // `concealed` marks the item transient + concealed so clipboard managers do not capture it — used
    // for the secure-field divert, where the copied text is a password.
    static func copyToClipboard(_ text: String, concealed: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard concealed else {
            pb.setString(text, forType: .string)
            return
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.writeObjects([item])
    }

    // A full snapshot of every pasteboard item and type, so restore reproduces images / RTF / file
    // lists, not just plain text (the prior code saved only `.string` and silently destroyed the rest).
    struct PasteboardSnapshot {
        let changeCount: Int
        let items: [[NSPasteboard.PasteboardType: Data]]

        static func capture(from pb: NSPasteboard = .general) -> PasteboardSnapshot {
            let items = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
                var byType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { byType[type] = data }
                }
                return byType
            }
            return PasteboardSnapshot(changeCount: pb.changeCount, items: items)
        }

        func restore(to pb: NSPasteboard = .general) {
            pb.clearContents()
            guard !items.isEmpty else { return }
            let objects = items.map { byType -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in byType { item.setData(data, forType: type) }
                return item
            }
            if pb.writeObjects(objects) { return }
            // Some exotic multi-representation clipboards reject a full round-trip write; rather than
            // leave the clipboard empty, fall back to restoring the plain-text representation if any.
            pb.clearContents()
            if let stringData = items.first?[.string], let text = String(data: stringData, encoding: .utf8) {
                pb.setString(text, forType: .string)
            }
        }
    }

    private static func eventFlags(_ modifier: Mode.ClipboardModifier) -> CGEventFlags {
        switch modifier {
        case .command: return .maskCommand
        case .control: return .maskControl
        }
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}
