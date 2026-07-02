import AppKit
import ApplicationServices
import CoreGraphics
import KeyScribeKit

@MainActor
enum TextInserter {
    private static let vKeyCode: CGKeyCode = 9
    private static let cKeyCode: CGKeyCode = 8
    private static let returnKeyCode: CGKeyCode = 36

    // Captures the target app's current selection via ⌘C, then restores the user's clipboard only if
    // that copy actually changed the pasteboard.
    static func captureSelection(modifier: Mode.ClipboardModifier = .command) async -> String? {
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture()
        postKey(cKeyCode, flags: eventFlags(modifier))
        guard await waitForChange(since: snapshot.changeCount) else { return nil }
        let copied = pb.string(forType: .string)
        snapshot.restore()
        return copied
    }

    // The user's current clipboard as text, for the "insert clipboard contents" live edit. Read at
    // pipeline time — before any ⌘C/⌘V machinery stages a value — so it is the real clipboard the user
    // copied. The plain-text flavor covers plain text and the plain rendering of rich text (formatting
    // is dropped — dictation inserts plain text); the NSAttributedString fallback recovers text from
    // apps that put only RTF/HTML with no plain flavor. Non-text clipboards (images, copied files) and
    // an empty clipboard yield nil, which leaves the spoken phrase as literal text (ClipboardTokenizer).
    static func currentClipboardText() -> String? {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty { return s }
        if let attributed = pb.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first
            as? NSAttributedString, !attributed.string.isEmpty {
            return attributed.string
        }
        return nil
    }

    // Returns whether the chosen insertion path actually acted. A false paste result means nothing was
    // inserted, so the caller must not report success or fire a submit keystroke.
    @discardableResult
    static func perform(_ decision: InsertionDecision, method: Mode.Insertion, modifier: Mode.ClipboardModifier, text: String) async -> Bool {
        switch insertionAction(decision: decision, method: method) {
        case .paste: return await insertViaPaste(text, modifier: modifier)
        case .ax: return await insertViaAX(text, modifier: modifier)
        case .type: return await insertViaTyping(text)
        case .clipboard:
            // A secure-field divert conceals the copy so clipboard managers do not retain the password;
            // every other fallback is a normal copy the user can paste back.
            if case .clipboardFallback(.secureField) = decision {
                return copyToClipboard(text, concealed: true)
            }
            return copyToClipboard(text)
        }
    }

    @discardableResult
    static func insertViaPaste(_ text: String, modifier: Mode.ClipboardModifier = .command) async -> Bool {
        guard !text.isEmpty else { return true }
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture()
        // Never synthesize ⌘V unless the scratch write is visible; otherwise stale clipboard content
        // could be pasted into the target.
        guard writeScratchVerified(text) else {
            snapshot.restore()
            Log.insertion.error("paste: pasteboard write unverified; skipped ⌘V to avoid pasting stale clipboard")
            return false
        }
        let stamp = pb.changeCount
        postKey(vKeyCode, flags: eventFlags(modifier))
        // Give the target a bounded window to consume ⌘V; if anything else writes to the pasteboard,
        // leave it alone.
        if await scratchSurvived(stamp, timeoutMs: 250, stepMs: 25) { snapshot.restore() }
        return true
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

    // AX can report success while doing nothing in some targets, so use it only when a read-back proves
    // the value changed.
    @discardableResult
    static func insertViaAX(_ text: String, modifier: Mode.ClipboardModifier = .command) async -> Bool {
        if axInsertVerified(text) {
            Log.insertion.notice("ax-insert: succeeded")
            return true
        }
        Log.insertion.notice("ax-insert: unverified here, falling back to paste")
        return await insertViaPaste(text, modifier: modifier)
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

    // Best-effort Unicode key events; there is no acceptance signal to drive fallback.
    @discardableResult
    static func insertViaTyping(_ text: String) async -> Bool {
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
        return true
    }

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
    @discardableResult
    static func copyToClipboard(_ text: String, concealed: Bool = false, to pb: NSPasteboard = .general) -> Bool {
        pb.clearContents()
        guard concealed else {
            return pb.setString(text, forType: .string) && pb.string(forType: .string) == text
        }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
              item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        else { return false }
        return pb.writeObjects([item]) && pb.string(forType: .string) == text
    }

    // Captures all pasteboard item types up to a size cap; oversized clipboards fall back to plain text
    // so image/file-heavy clipboards do not stall the main actor.
    struct PasteboardSnapshot {
        let changeCount: Int
        private let storage: Storage
        private static let maxSnapshotBytes = 8 * 1024 * 1024

        private enum Storage {
            case full([[NSPasteboard.PasteboardType: Data]])
            case plainText(String?)
        }

        static func capture(from pb: NSPasteboard = .general) -> PasteboardSnapshot {
            var total = 0
            var items: [[NSPasteboard.PasteboardType: Data]] = []
            for item in pb.pasteboardItems ?? [] {
                var byType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        total += data.count
                        if total > maxSnapshotBytes {
                            return PasteboardSnapshot(
                                changeCount: pb.changeCount,
                                storage: .plainText(pb.string(forType: .string)))
                        }
                        byType[type] = data
                    }
                }
                items.append(byType)
            }
            return PasteboardSnapshot(changeCount: pb.changeCount, storage: .full(items))
        }

        func restore(to pb: NSPasteboard = .general) {
            switch storage {
            case .full(let items):
                restoreFull(items, to: pb)
            case .plainText(let text):
                guard let text else { return }
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }

        private func restoreFull(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
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
