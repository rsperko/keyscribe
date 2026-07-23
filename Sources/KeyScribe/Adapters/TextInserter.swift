import AppKit
import ApplicationServices
import CoreGraphics
import KeyScribeKit

@MainActor
enum TextInserter {
    private static let vKeyCode: CGKeyCode = 9
    private static let cKeyCode: CGKeyCode = 8
    private static let returnKeyCode: CGKeyCode = 36

    private static var pendingRestore: ScratchPaste?
    private static var pendingRestoreBackstop: Task<Void, Never>?
    private static var pendingRestoreGeneration = 0

    // Reads the target app's current selection. Native apps expose it via AX, read directly (no ⌘C, so an
    // empty selection can't beep or grab the current line). AX-unavailable (Electron/Chromium) falls back to
    // a muted ⌘C, the universal selection capture (design.md §4.3), trusted per `copyIsTrustworthySelection`.
    // Drains any in-flight detached restore first so the snapshot is the user's real clipboard, not a prior
    // paste's scratch text.
    static func captureSelection(modifier: Mode.ClipboardModifier = .command, requirePerfectRestore: Bool = false) async -> String? {
        if case .text(let selection) = axSelectedText() {
            return selection.isEmpty ? nil : selection
        }
        // Drain first so the guard below sees the user's real clipboard, not a prior paste's scratch text.
        await drainPendingRestore()
        let pb = NSPasteboard.general
        // The AX-unavailable ⌘C restores byte-perfect only for a plain-text/empty clipboard. Convenience callers
        // (Add-to-Vocabulary prefill) pass requirePerfectRestore so a rich/image clipboard is never risked for a
        // non-essential copy — they just get no prefill in that app.
        if requirePerfectRestore, !clipboardRestoresPerfectly(pb) { return nil }
        return await withMutedAlertVolume {
            let snapshot = PasteboardSnapshot.capture(from: pb)
            postKey(cKeyCode, flags: eventFlags(modifier))
            guard await waitForChange(since: snapshot.changeCount) else { return nil }
            let copied = pb.string(forType: .string)
            let editorData = pb.pasteboardItems?.first?.data(forType: webCustomDataType)
            snapshot.restore()
            guard WebCustomData.copyIsTrustworthySelection(editorData) else {
                Log.insertion.debug("captureSelection: discarding VS Code empty-selection whole-line copy")
                return nil
            }
            return copied
        }
    }

    // True when the clipboard is empty or plain-text only (plus our transient markers), so a ⌘C round-trip
    // restores it byte-perfect. Any image/file/rich flavor risks the plain-text fallback → false. Allowlist, so
    // an unknown flavor is treated as unsafe.
    static func clipboardRestoresPerfectly(_ pb: NSPasteboard = .general) -> Bool {
        let restorable: Set<String> = [
            "public.utf8-plain-text",           // NSPasteboard.PasteboardType.string
            "public.utf16-external-plain-text",
            "public.text",
            "NSStringPboardType",               // legacy plain-text flavor some apps still add
            "org.nspasteboard.TransientType",
            "org.nspasteboard.ConcealedType",
        ]
        for item in pb.pasteboardItems ?? [] {
            for type in item.types where !restorable.contains(type.rawValue) { return false }
        }
        return true
    }

    private static let webCustomDataType = NSPasteboard.PasteboardType("org.chromium.web-custom-data")

    private enum AXSelection { case text(String); case unsupported }

    // `.text` (incl. empty) when the focused element reports a selection; `.unsupported` (no readable
    // selection attribute — Electron/Chromium) routes to the ⌘C fallback.
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

    // Mutes the global alert volume for `body` so a synthetic ⌘C with nothing to copy can't beep.
    // Best-effort: if the volume can't be read/set, the copy still runs (it may beep).
    private static func withMutedAlertVolume<T>(_ body: () async -> T) async -> T {
        let saved = alertVolume()
        if saved != nil { setAlertVolume(0) }
        defer { if let saved { setAlertVolume(saved) } }
        return await body()
    }

    private static func alertVolume() -> Int? {
        var error: NSDictionary?
        guard let result = cachedScript("alert volume of (get volume settings)")?
            .executeAndReturnError(&error), error == nil else { return nil }
        return Int(result.int32Value)
    }

    private static func setAlertVolume(_ volume: Int) {
        var error: NSDictionary?
        _ = cachedScript("set volume alert volume \(volume)")?.executeAndReturnError(&error)
    }

    // Reuse compiled scripts so the muted ⌘C fallback doesn't recompile per call; bounded (read + volume 0...100).
    private static var scriptCache: [String: NSAppleScript] = [:]
    private static func cachedScript(_ source: String) -> NSAppleScript? {
        if let cached = scriptCache[source] { return cached }
        let script = NSAppleScript(source: source)
        scriptCache[source] = script
        return script
    }

    // The user's clipboard as text, for "insert clipboard contents". Read at pipeline time (before any
    // ⌘C/⌘V machinery stages a value). Formatting is dropped (dictation inserts plain text); the
    // NSAttributedString fallback recovers text from apps that put only RTF/HTML. Non-text/empty clipboards
    // yield nil, leaving the spoken phrase as literal text (ClipboardTokenizer).
    static func currentClipboardText() -> String? {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty { return s }
        if let attributed = pb.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first
            as? NSAttributedString, !attributed.string.isEmpty {
            return attributed.string
        }
        return nil
    }

    // Returns whether the insertion path actually acted. False ⇒ nothing inserted, so the caller must not
    // report success or fire a submit keystroke.
    @discardableResult
    static func perform(_ decision: InsertionDecision, method: Mode.Insertion, paste: ClipboardPaste, text: String, awaitSettle: Bool = true) async -> Bool {
        switch insertionAction(decision: decision, method: method) {
        case .paste: return await insertViaPaste(text, modifier: paste.modifier, settleMs: paste.settleMs, awaitSettle: awaitSettle)
        case .ax: return await insertViaAX(text, modifier: paste.modifier, settleMs: paste.settleMs, awaitSettle: awaitSettle)
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
    static func insertViaPaste(_ text: String, modifier: Mode.ClipboardModifier = .command, settleMs: Int = 0, awaitSettle: Bool = true) async -> Bool {
        guard !text.isEmpty else { return true }
        guard let scratch = await beginScratchPaste(text, on: .general, concealed: modifier != .control) else {
            Log.insertion.error("paste: pasteboard write unverified; skipped ⌘V to avoid pasting stale clipboard")
            return false
        }
        if settleMs > 0 {
            try? await Task.sleep(for: .milliseconds(settleMs))
        }
        postKey(vKeyCode, flags: eventFlags(modifier))
        if modifier == .control {
            return true
        }
        await settleScratch(scratch, awaitSettle: awaitSettle)
        return true
    }

    struct ScratchPaste {
        let pb: NSPasteboard
        let snapshot: PasteboardSnapshot
        let stamp: Int
    }

    // Snapshots the clipboard and writes the scratch value ⌘V will paste. Drains any in-flight detached
    // restore first so the snapshot is the user's real clipboard, not a prior paste's scratch text
    // (restoring that would leak dictated content). nil ⇒ scratch write unverified, caller must not ⌘V.
    static func beginScratchPaste(_ text: String, on pb: NSPasteboard, concealed: Bool = true, afterCapture: (() -> Void)? = nil) async -> ScratchPaste? {
        await drainPendingRestore()
        // ONE deadline across every capture below: each renders on the main thread, so a per-capture budget
        // would let a promised-flavor clipboard stall main for up to 4x the bound. A retry that finds it spent
        // degrades to a plain-text snapshot, which is the safe direction — restore still clears the scratch.
        let renderDeadline = PasteboardSnapshot.renderDeadline()
        var snapshot = PasteboardSnapshot.capture(from: pb, renderDeadline: renderDeadline)
        afterCapture?()
        // Re-capture until a snapshot spans no concurrent copy, so the scratch write can't clobber a copy
        // that landed mid-capture. If it never stabilizes within the cap, fail closed below rather than
        // clobber an actively-changing clipboard.
        var stabilizeAttempts = 0
        while pb.changeCount != snapshot.changeCount && stabilizeAttempts < maxSnapshotStabilizeAttempts {
            snapshot = PasteboardSnapshot.capture(from: pb, renderDeadline: renderDeadline)
            afterCapture?()
            stabilizeAttempts += 1
        }
        // A still-unstable clipboard means a copy is landing right now; skip the paste (recoverable via Paste
        // Last) rather than write scratch over that copy and later restore a stale snapshot.
        guard pb.changeCount == snapshot.changeCount else { return nil }
        guard writeScratchVerified(text, to: pb, concealed: concealed) else {
            snapshot.restore(to: pb)
            return nil
        }
        return ScratchPaste(pb: pb, snapshot: snapshot, stamp: pb.changeCount)
    }

    private static let maxSnapshotStabilizeAttempts = 3
    private static let submitSettleMs = 120
    private static let restoreBackstopMs = 1500

    // The clipboard restore runs off the user-felt path; awaitSettle only holds a short window inline so a
    // following submit Return lands after the target consumed ⌘V.
    static func settleScratch(_ scratch: ScratchPaste, awaitSettle: Bool) async {
        detachRestore(scratch)
        if awaitSettle {
            try? await Task.sleep(for: .milliseconds(submitSettleMs))
        }
    }

    // Not on a short fixed timer: the concealed scratch stays until the next clipboard interaction
    // (drainPendingRestore) or, failing that, a backstop — giving a lagging target time to consume ⌘V
    // before the restore. A target that stalls past the backstop can still read the restored clipboard.
    private static func detachRestore(_ scratch: ScratchPaste) {
        pendingRestoreGeneration &+= 1
        let generation = pendingRestoreGeneration
        pendingRestore = scratch
        pendingRestoreBackstop = Task {
            try? await Task.sleep(for: .milliseconds(restoreBackstopMs))
            guard !Task.isCancelled, pendingRestoreGeneration == generation else { return }
            restoreIfScratchIntact(scratch)
            pendingRestore = nil
            pendingRestoreBackstop = nil
        }
    }

    // Restores immediately unless a later copy replaced the scratch (changeCount moved), preserving that copy.
    private static func restoreIfScratchIntact(_ scratch: ScratchPaste) {
        if scratch.pb.changeCount == scratch.stamp {
            scratch.snapshot.restore(to: scratch.pb)
        }
    }

    static func drainPendingRestore() async {
        guard let scratch = pendingRestore else { return }
        pendingRestoreGeneration &+= 1
        pendingRestoreBackstop?.cancel()
        pendingRestoreBackstop = nil
        pendingRestore = nil
        restoreIfScratchIntact(scratch)
    }

    // Temporary clipboard write for the paste, read-back verified. Transient + concealed so clipboard
    // managers don't capture the dictated text (may contain just-restored sensitive spans). Returns false
    // if after a few attempts the string isn't the dictated text, so the caller refuses to ⌘V stale content.
    private static func writeScratchVerified(_ text: String, to pb: NSPasteboard = .general, concealed: Bool = true, attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if concealed {
                item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            }
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

    // Hand focus back to `target` and paste `text` there via the shared paste path (single ⌘Z undo).
    // Returns false without pasting if focus couldn't be handed back (caller owns the fallback). The 120 ms
    // after frontmost confirmation lets the target's key window become ready before ⌘V.
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

    // AX can report success while doing nothing, so trust it only when a read-back proves the value changed.
    @discardableResult
    static func insertViaAX(_ text: String, modifier: Mode.ClipboardModifier = .command, settleMs: Int = 0, awaitSettle: Bool = true) async -> Bool {
        if axInsertVerified(text) {
            Log.insertion.notice("ax-insert: succeeded")
            return true
        }
        Log.insertion.notice("ax-insert: unverified here, falling back to paste")
        return await insertViaPaste(text, modifier: modifier, settleMs: settleMs, awaitSettle: awaitSettle)
    }

    private static func axInsertVerified(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return false }
        let element = focusedRef as! AXUIElement
        guard let before = axValue(element) else { return false }
        let selectedBefore = axSelectedTextValue(element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        return axInsertLandedInPlace(before: before, after: axValue(element), selectedBefore: selectedBefore,
                                     selectedAfter: axSelectedTextValue(element), inserted: text)
    }

    static func axInsertLandedInPlace(before: String, after: String?, selectedBefore: String?,
                                      selectedAfter: String?, inserted: String) -> Bool {
        if let after, after != before { return true }
        guard !inserted.isEmpty, selectedBefore == inserted, let selectedAfter else { return false }
        return selectedAfter != inserted
    }

    private static func axValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axSelectedTextValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
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

    // `concealed` marks the item transient + concealed so clipboard managers don't capture it (secure-field
    // divert, where the copied text is a password).
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

    // Captures all pasteboard item types up to a size cap; oversized clipboards fall back to plain text so
    // image/file-heavy clipboards don't stall the main actor.
    struct PasteboardSnapshot {
        let changeCount: Int
        private let storage: Storage
        private static let maxSnapshotBytes = 8 * 1024 * 1024
        // Bounds the render ACROSS flavors, checked between them (see capture): eager images render fully, a
        // clipboard whose lazy/promised payloads blow through it falls back to plain text.
        static let renderBudgetSeconds = 0.25

        private enum Storage {
            case full([[NSPasteboard.PasteboardType: Data]])
            case plainText(String?)
        }

        static func renderDeadline() -> ContinuousClock.Instant {
            ContinuousClock.now.advanced(by: .seconds(renderBudgetSeconds))
        }

        @MainActor
        static func capture(from pb: NSPasteboard = .general) -> PasteboardSnapshot {
            capture(from: pb, renderDeadline: renderDeadline())
        }

        // Snapshot every flavor so restore returns the user's exact clipboard. NSPasteboard/NSPasteboardItem are
        // main-thread-only (an off-main render PAC-trapped in CFPasteboard's XPC bridge), so this is deliberately
        // synchronous main-actor code: no suspension point means nothing can rewrite the pasteboard between two
        // flavors, and no render outlives the call. `data(forType:)` fully renders a promised/lazy flavor (a
        // cross-process TIFF can be 50–100 MB) and macOS exposes no bounded pasteboard read, so the budget is
        // checked BEFORE each one — the aggregate is bounded, but one wedged flavor blocks main for its render.
        // A spent budget, the 8 MB cap, or nothing renderable fall back to the plain-text snapshot, which still
        // clears the scratch on restore so no dictated/redacted text leaks. changeCount guards a concurrent copy.
        @MainActor
        static func capture(from pb: NSPasteboard, renderDeadline: ContinuousClock.Instant) -> PasteboardSnapshot {
            let changeCount = pb.changeCount
            let plainText = pb.string(forType: .string)
            var total = 0
            var items: [[NSPasteboard.PasteboardType: Data]] = []
            for item in pb.pasteboardItems ?? [] {
                var byType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard ContinuousClock.now < renderDeadline else {
                        return PasteboardSnapshot(changeCount: changeCount, storage: .plainText(plainText))
                    }
                    guard let data = item.data(forType: type) else { continue }
                    total += data.count
                    guard total <= maxSnapshotBytes else {
                        return PasteboardSnapshot(changeCount: changeCount, storage: .plainText(plainText))
                    }
                    byType[type] = data
                }
                items.append(byType)
            }
            return PasteboardSnapshot(changeCount: changeCount, storage: .full(items))
        }

        // Main-actor for the same reason as capture: the write side touches NSPasteboard too. Nested types do
        // NOT inherit the enclosing @MainActor, so this must be stated, not assumed from `enum TextInserter`.
        @MainActor
        func restore(to pb: NSPasteboard = .general) {
            switch storage {
            case .full(let items):
                restoreFull(items, to: pb)
            case .plainText(let text):
                // Always clear first so a nil snapshot (a heavyweight/oversized clipboard we couldn't
                // preserve, no `.string` flavor) removes the scratch paste rather than leaving dictated text
                // (incl. restored redacted spans) on the clipboard.
                pb.clearContents()
                if let text { pb.setString(text, forType: .string) }
            }
        }

        @MainActor
        private func restoreFull(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
            pb.clearContents()
            guard !items.isEmpty else { return }
            let objects = items.map { byType -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in byType { item.setData(data, forType: type) }
                return item
            }
            if pb.writeObjects(objects) { return }
            // Some multi-representation clipboards reject a full round-trip write; fall back to the
            // plain-text representation rather than leave the clipboard empty.
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

    private static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, 55),
        (.maskShift, 56),
        (.maskAlternate, 58),
        (.maskControl, 59),
    ]

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let held = flags.contains(.maskControl) ? modifierKeys.filter { flags.contains($0.0) } : []
        var active: CGEventFlags = []
        for (mask, code) in held {
            active.insert(mask)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
                down.flags = active
                down.post(tap: .cghidEventTap)
            }
        }
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
        for (mask, code) in held.reversed() {
            active.remove(mask)
            if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
                up.flags = active
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
