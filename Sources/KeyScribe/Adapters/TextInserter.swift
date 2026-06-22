import AppKit
import ApplicationServices
import CoreGraphics
import KeyScribeKit

@MainActor
enum TextInserter {
    private static let vKeyCode: CGKeyCode = 9
    private static let cKeyCode: CGKeyCode = 8

    // Capture the target app's current selection via a synthesized ⌘C, then restore the user's
    // clipboard. Universal (spike-verified across native/Electron/Chromium). Returns nil if nothing
    // was copied (no selection). The selection stays highlighted, so a later paste replaces it.
    static func captureSelection() async -> String? {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let before = pb.changeCount
        postCommand(cKeyCode)
        try? await Task.sleep(for: .milliseconds(120))
        let copied = pb.changeCount != before ? pb.string(forType: .string) : nil
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
        return copied
    }

    // Paste is the spike-confirmed default (lands across native/Electron/Chromium with a single ⌘Z
    // undo). AX-insert and synthesized typing are opt-in per mode (mode.insertion) for the few
    // targets that prefer them; both proved unreliable in the M0 survey, so each degrades to paste
    // when it can't act. The focus-race safety decision is authoritative — a clipboardFallback
    // diverts to the clipboard regardless of the mode's preferred method.
    static func perform(_ decision: InsertionDecision, method: Mode.Insertion, text: String) async {
        switch insertionAction(decision: decision, method: method) {
        case .paste: await insertViaPaste(text)
        case .ax: await insertViaAX(text)
        case .type: await insertViaTyping(text)
        case .clipboard: copyToClipboard(text)
        }
    }

    static func insertViaPaste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        try? await Task.sleep(for: .milliseconds(30))
        postCommand(vKeyCode)
        try? await Task.sleep(for: .milliseconds(200))
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
    }

    // AX-insert: set the focused element's selected text, which replaces the selection or inserts at
    // the cursor. We do NOT trust the set's `.success` return — Chromium/Electron return success but
    // no-op it, silently dropping the text. Instead we only take the AX path when we can read the
    // field's value back and confirm it actually changed; otherwise we fall back to paste, which
    // lands everywhere. So `insert` uses AX on native fields and paste on web/Electron, never losing text.
    static func insertViaAX(_ text: String) async {
        if axInsertVerified(text) {
            Log.insertion.notice("ax-insert: succeeded")
            return
        }
        Log.insertion.notice("ax-insert: unverified here, falling back to paste")
        await insertViaPaste(text)
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

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func postCommand(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
    }
}
