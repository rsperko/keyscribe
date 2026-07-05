import AppKit
import ApplicationServices
import CoreGraphics
import KeyScribeKit
import UniformTypeIdentifiers

@MainActor
enum TextInserter {
    private static let vKeyCode: CGKeyCode = 9
    private static let cKeyCode: CGKeyCode = 8
    private static let returnKeyCode: CGKeyCode = 36

    private static var pendingRestore: Task<Void, Never>?
    private static var pendingRestoreGeneration = 0

    // Reads the target app's current selection. Native apps expose it through Accessibility, so we read
    // it directly — no clipboard, no synthetic ⌘C — which means an empty selection can neither beep nor
    // grab the current line. Only when AX is unavailable (Electron/Chromium) do we fall back to a ⌘C
    // copy, muted so an empty-selection copy cannot beep, and we trust that copy only if it came from a
    // real selection: VS Code-family editors copy the whole line on an empty ⌘C but flag it in
    // `vscode-editor-data.isFromEmptySelection`; a copy without that flag (Obsidian, Chrome, …) is
    // discarded rather than risk inserting a line the user never selected. Drains any in-flight detached
    // restore first so the snapshot is the user's real clipboard, never a prior paste's scratch text.
    static func captureSelection(modifier: Mode.ClipboardModifier = .command) async -> String? {
        if case .text(let selection) = axSelectedText() {
            return selection.isEmpty ? nil : selection
        }
        return await withMutedAlertVolume {
            await drainPendingRestore()
            let pb = NSPasteboard.general
            let snapshot = PasteboardSnapshot.capture()
            postKey(cKeyCode, flags: eventFlags(modifier))
            guard await waitForChange(since: snapshot.changeCount) else { return nil }
            let copied = pb.string(forType: .string)
            let editorData = pb.pasteboardItems?.first?.data(forType: webCustomDataType)
            snapshot.restore()
            guard WebCustomData.vscodeIsFromEmptySelection(editorData) == false else {
                Log.insertion.debug("captureSelection: discarding non-AX copy with no real-selection flag")
                return nil
            }
            return copied
        }
    }

    private static let webCustomDataType = NSPasteboard.PasteboardType("org.chromium.web-custom-data")

    private enum AXSelection { case text(String); case unsupported }

    // `.text` (including empty) when the focused element reports a selection — native apps do, so an
    // empty string means "nothing selected". `.unsupported` when there is no readable selection
    // attribute (Electron/Chromium web areas), which routes to the ⌘C fallback.
    private static func axSelectedText() -> AXSelection {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return .unsupported }
        let element = focusedRef as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return .unsupported }
        return .text(text)
    }

    // Mutes the system alert volume for the duration of `body` so a synthetic ⌘C that lands on an app
    // with nothing to copy cannot beep. Best-effort: if the volume cannot be read/set, the copy still
    // runs (it may beep). The volume is global, so it is muted only for the brief copy window.
    private static func withMutedAlertVolume<T>(_ body: () async -> T) async -> T {
        let saved = alertVolume()
        if saved != nil { setAlertVolume(0) }
        defer { if let saved { setAlertVolume(saved) } }
        return await body()
    }

    private static func alertVolume() -> Int? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: "alert volume of (get volume settings)")?
            .executeAndReturnError(&error), error == nil else { return nil }
        return Int(result.int32Value)
    }

    private static func setAlertVolume(_ volume: Int) {
        var error: NSDictionary?
        _ = NSAppleScript(source: "set volume alert volume \(volume)")?.executeAndReturnError(&error)
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
    static func perform(_ decision: InsertionDecision, method: Mode.Insertion, modifier: Mode.ClipboardModifier, text: String, awaitSettle: Bool = true) async -> Bool {
        switch insertionAction(decision: decision, method: method) {
        case .paste: return await insertViaPaste(text, modifier: modifier, awaitSettle: awaitSettle)
        case .ax: return await insertViaAX(text, modifier: modifier, awaitSettle: awaitSettle)
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
    static func insertViaPaste(_ text: String, modifier: Mode.ClipboardModifier = .command, awaitSettle: Bool = true) async -> Bool {
        guard !text.isEmpty else { return true }
        guard let scratch = await beginScratchPaste(text, on: .general) else {
            Log.insertion.error("paste: pasteboard write unverified; skipped ⌘V to avoid pasting stale clipboard")
            return false
        }
        postKey(vKeyCode, flags: eventFlags(modifier))
        await settleScratch(scratch, awaitSettle: awaitSettle)
        return true
    }

    struct ScratchPaste {
        let pb: NSPasteboard
        let snapshot: PasteboardSnapshot
        let stamp: Int
    }

    // Snapshots the clipboard and writes the scratch value ⌘V will paste. Drains any in-flight detached
    // restore first, so the snapshot is the user's real clipboard and never a prior paste's still-present
    // scratch text (restoring that would leak dictated content into the user's clipboard). nil ⇒ the
    // scratch write was unverified and the caller must not ⌘V.
    static func beginScratchPaste(_ text: String, on pb: NSPasteboard) async -> ScratchPaste? {
        await drainPendingRestore()
        let snapshot = PasteboardSnapshot.capture(from: pb)
        guard writeScratchVerified(text, to: pb) else {
            snapshot.restore(to: pb)
            return nil
        }
        return ScratchPaste(pb: pb, snapshot: snapshot, stamp: pb.changeCount)
    }

    // Restores the user's clipboard once the scratch survived the settle window. Inline when a submit
    // Return must land after ⌘V; otherwise detached so the completion cue is not delayed — the next
    // paste drains it before snapshotting.
    static func settleScratch(_ scratch: ScratchPaste, awaitSettle: Bool) async {
        if awaitSettle {
            if await scratchSurvived(scratch.stamp, on: scratch.pb, timeoutMs: 250, stepMs: 25) {
                scratch.snapshot.restore(to: scratch.pb)
            }
            return
        }
        pendingRestoreGeneration &+= 1
        pendingRestore = Task {
            if await scratchSurvived(scratch.stamp, on: scratch.pb, timeoutMs: 250, stepMs: 25) {
                scratch.snapshot.restore(to: scratch.pb)
            }
        }
    }

    private static func drainPendingRestore() async {
        while let pending = pendingRestore {
            let generation = pendingRestoreGeneration
            await pending.value
            if pendingRestoreGeneration == generation {
                pendingRestore = nil
                break
            }
        }
    }

    private static func scratchSurvived(_ stamp: Int, on pb: NSPasteboard = .general, timeoutMs: Int, stepMs: Int) async -> Bool {
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
    private static func writeScratchVerified(_ text: String, to pb: NSPasteboard = .general, attempts: Int = 3) -> Bool {
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

    static func waitUntilFrontmost(_ target: NSRunningApplication, timeoutMs: Int = 600, stepMs: Int = 50) async -> Bool {
        await poll(timeoutMs: timeoutMs, stepMs: stepMs) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        }
    }

    // Hand focus back to `target` and paste `text` there via the shared safe insertion path (single ⌘Z
    // undo). The caller orders its own window out and owns the fallback: returns false without pasting
    // if focus could not be handed back, so History can copy-to-clipboard while the correction panel
    // reports the selection unchanged. The 120 ms after frontmost confirmation lets the target's key
    // window become ready before ⌘V.
    static func pasteReturning(to target: NSRunningApplication, text: String) async -> Bool {
        target.activate()
        guard await waitUntilFrontmost(target) else { return false }
        try? await Task.sleep(for: .milliseconds(120))
        return await insertViaPaste(text)
    }

    static func poll(timeoutMs: Int, stepMs: Int, condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(stepMs))
            waited += stepMs
        }
        return condition()
    }

    // AX can report success while doing nothing in some targets, so use it only when a read-back proves
    // the value changed.
    @discardableResult
    static func insertViaAX(_ text: String, modifier: Mode.ClipboardModifier = .command, awaitSettle: Bool = true) async -> Bool {
        if axInsertVerified(text) {
            Log.insertion.notice("ax-insert: succeeded")
            return true
        }
        Log.insertion.notice("ax-insert: unverified here, falling back to paste")
        return await insertViaPaste(text, modifier: modifier, awaitSettle: awaitSettle)
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
            let pbItems = pb.pasteboardItems ?? []
            // Materializing a flavor with `data(forType:)` renders any promised/lazy representation in
            // full (a Preview TIFF can be 50–100 MB) — the size cap below only stops *storing*, not the
            // render that already stalled the main actor. Pre-scan types and divert heavyweight
            // clipboards (image/PDF/media/file-URL) straight to the plain-text snapshot before touching
            // their data, so we never render a flavor we would only discard.
            if pbItems.contains(where: { $0.types.contains(where: isHeavyweight) }) {
                return PasteboardSnapshot(
                    changeCount: pb.changeCount, storage: .plainText(pb.string(forType: .string)))
            }
            var total = 0
            var items: [[NSPasteboard.PasteboardType: Data]] = []
            for item in pbItems {
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

        private static func isHeavyweight(_ type: NSPasteboard.PasteboardType) -> Bool {
            guard let ut = UTType(type.rawValue) else { return false }
            return ut.conforms(to: .image) || ut.conforms(to: .pdf)
                || ut.conforms(to: .movie) || ut.conforms(to: .audio)
                || ut.conforms(to: .fileURL)
        }

        func restore(to pb: NSPasteboard = .general) {
            switch storage {
            case .full(let items):
                restoreFull(items, to: pb)
            case .plainText(let text):
                // Always clear first (like restoreFull) so a nil snapshot — a heavyweight or oversized
                // clipboard we could not preserve, captured with no `.string` flavor — removes the scratch
                // paste rather than leaving dictated text (incl. restored redacted spans) on the clipboard.
                pb.clearContents()
                if let text { pb.setString(text, forType: .string) }
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
