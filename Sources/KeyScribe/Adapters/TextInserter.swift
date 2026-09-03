import AppKit
import ApplicationServices
import CoreGraphics
import KeyScribeKit

@MainActor
enum TextInserter {
    private static let returnKeyCode: CGKeyCode = 36

    private static var pendingRestore: ScratchPaste?
    private static var pendingRestoreBackstop: Task<Void, Never>?
    private static var pendingRestoreGeneration = 0

    // Reads the target app's current selection. Native apps expose it via AX, read directly (no ⌘C, so an
    // empty selection can't beep or grab the current line). AX-unavailable (Electron/Chromium) falls back to
    // a muted ⌘C, the universal selection capture (design.md §4.3), trusted per `copyIsTrustworthySelection`.
    // Drains any in-flight detached restore first so the snapshot is the user's real clipboard, not a prior
    // paste's scratch text.
    static func captureSelection(keystroke: ClipboardKeystroke = .copy, requirePerfectRestore: Bool = false) async -> String? {
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
            guard postKey(keystroke) else { return nil }
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
        currentClipboardText(on: .general)
    }

    static func currentClipboardText(on pb: NSPasteboard) -> String? {
        drainPendingRestoreNow()
        if let s = pb.string(forType: .string), !s.isEmpty { return s }
        if let attributed = pb.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first
            as? NSAttributedString, !attributed.string.isEmpty {
            return attributed.string
        }
        return nil
    }

    // Consulted immediately before each irreversible event — the ⌘V post and every typed character — since
    // both suspend after the caller's own gate. TaskLocal, not a stored property: a static would be shared
    // with Paste Last and the correction panel, and reentrancy lets one task clobber another's closure.
    @TaskLocal static var shouldAbortInsertion: (@Sendable () -> Bool)?

    private static var insertionAborted: Bool { shouldAbortInsertion?() ?? false }

    // Test seam. Typed insertion posts to `.cghidEventTap`, which is system-wide input — a test driving it
    // types into whatever app the user has focused. When this is set the characters are recorded instead.
    @TaskLocal static var typedCharacterSink: (@Sendable (Character) -> Void)?

    // Returns whether the insertion path actually acted. False ⇒ nothing inserted, so the caller must not
    // report success or fire a submit keystroke.
    @discardableResult
    static func perform(_ decision: InsertionDecision, method: Mode.Insertion, paste: ClipboardPaste, text: String, awaitSettle: Bool = true) async -> Bool {
        // Covers the paths with no suspension of their own to check at — AX insertion and the clipboard
        // fallback both act synchronously once entered. Paste and typing keep their deeper checks.
        if insertionAborted {
            Log.insertion.notice("insertion skipped — the capture this text came from was lost")
            return false
        }
        switch insertionAction(decision: decision, method: method) {
        case .paste: return await insertViaPaste(text, paste: paste, awaitSettle: awaitSettle)
        case .ax: return await insertViaAX(text, paste: paste, awaitSettle: awaitSettle)
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

    // A syncing target (VM guest, remote session) reads the clipboard through its own agent, so the scratch
    // is left un-concealed for that agent to pick up and is never restored: a remote paste can fetch the
    // clipboard back across the wire AFTER the keystroke, and a restore racing that fetch would hand it the
    // user's previous clipboard. The dictated text staying on the clipboard is the accepted cost.
    @discardableResult
    static func insertViaPaste(
        _ text: String, paste: ClipboardPaste = .init(), awaitSettle: Bool = true,
        on pb: NSPasteboard = .general
    ) async -> Bool {
        guard !text.isEmpty else { return true }
        guard let scratch = await beginScratchPaste(
            text, on: pb, concealed: !paste.syncsClipboard, lazy: paste.restoreOnRead && !paste.syncsClipboard
        ) else {
            Log.insertion.error("paste: pasteboard write unverified; skipped ⌘V to avoid pasting stale clipboard")
            return false
        }
        if paste.settleMs > 0 {
            try? await Task.sleep(for: .milliseconds(paste.settleMs))
        }
        // Last point before the text lands: the scratch write and the settle above are both suspensions.
        if insertionAborted {
            // Restore NOW, not through settleScratch's post-paste window: that window exists to let a
            // lagging target consume a ⌘V that, here, never happened. Leaving the dictated text on the
            // clipboard meanwhile would be a needless exposure.
            Log.insertion.notice("paste: aborted before ⌘V — the capture this text came from was lost")
            restoreIfScratchIntact(scratch)
            return false
        }
        guard postKey(paste.keystroke) else {
            restoreIfScratchIntact(scratch)
            return false
        }
        let pastedAt = ContinuousClock.now
        if paste.syncsClipboard {
            return true
        }
        await settleScratch(scratch, awaitSettle: awaitSettle, restoreMs: paste.restoreMs, pastedAt: pastedAt)
        return true
    }

    struct ScratchPaste {
        let pb: NSPasteboard
        let snapshot: PasteboardSnapshot
        let stamp: Int
        let provider: ScratchProvider?
    }

    // Snapshots the clipboard and writes the scratch value ⌘V will paste. Drains any in-flight detached
    // restore first so the snapshot is the user's real clipboard, not a prior paste's scratch text
    // (restoring that would leak dictated content). nil ⇒ scratch write unverified, caller must not ⌘V.
    static func beginScratchPaste(_ text: String, on pb: NSPasteboard, concealed: Bool = true, lazy: Bool = false, afterCapture: (() -> Void)? = nil) async -> ScratchPaste? {
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
        let provider = lazy ? ScratchProvider(text: text) : nil
        guard writeScratchVerified(text, to: pb, concealed: concealed, provider: provider) else {
            snapshot.restore(to: pb)
            return nil
        }
        return ScratchPaste(pb: pb, snapshot: snapshot, stamp: pb.changeCount, provider: provider)
    }

    private static let maxSnapshotStabilizeAttempts = 3
    private static let submitSettleMs = 120
    // A target may read the pasteboard more than once per ⌘V (reported of Chromium and Electron, not measured).
    private static let restoreGraceMs = 100
    private static let consumptionPollMs = 10

    // The clipboard restore runs off the user-felt path; awaitSettle only holds a short window inline so a
    // following submit Return lands after the target consumed ⌘V.
    static func settleScratch(
        _ scratch: ScratchPaste, awaitSettle: Bool,
        restoreMs: Int = Settings.Insertion.defaultClipboardRestoreMs, pastedAt: ContinuousClock.Instant = .now
    ) async {
        detachRestore(scratch, restoreMs: restoreMs, pastedAt: pastedAt)
        if awaitSettle {
            try? await Task.sleep(for: .milliseconds(submitSettleMs))
        }
    }

    private enum RestoreTrigger: String { case read, backstop, drain }

    // Restores at the earliest of: the first read after the ⌘V (lazy scratch only), `restoreMs`, or the next
    // clipboard interaction (drainPendingRestore).
    private static func detachRestore(_ scratch: ScratchPaste, restoreMs: Int, pastedAt: ContinuousClock.Instant) {
        pendingRestoreGeneration &+= 1
        let generation = pendingRestoreGeneration
        pendingRestore = scratch
        pendingRestoreBackstop = Task {
            let trigger = await awaitConsumption(scratch, restoreMs: restoreMs, pastedAt: pastedAt)
            guard !Task.isCancelled, pendingRestoreGeneration == generation else { return }
            let restored = restoreIfScratchIntact(scratch)
            pendingRestore = nil
            pendingRestoreBackstop = nil
            logRestore(trigger, restored: restored, since: pastedAt)
        }
    }

    private static func awaitConsumption(
        _ scratch: ScratchPaste, restoreMs: Int, pastedAt: ContinuousClock.Instant
    ) async -> RestoreTrigger {
        guard let provider = scratch.provider else {
            try? await Task.sleep(for: .milliseconds(restoreMs))
            return .backstop
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(restoreMs))
        while ContinuousClock.now < deadline {
            if let readAt = provider.firstReadAt, readAt >= pastedAt {
                try? await Task.sleep(for: .milliseconds(restoreGraceMs))
                return .read
            }
            try? await Task.sleep(for: .milliseconds(consumptionPollMs))
            if Task.isCancelled { return .drain }
        }
        return .backstop
    }

    private static func logRestore(_ trigger: RestoreTrigger, restored: Bool, since pastedAt: ContinuousClock.Instant) {
        let heldMs = Int((ContinuousClock.now - pastedAt) / .milliseconds(1))
        let outcome = restored ? "clipboard restored" : "restore skipped, a newer copy replaced the scratch"
        Log.insertion.debug("paste: \(outcome, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) held=\(heldMs, privacy: .public)ms")
    }

    // Restores immediately unless a later copy replaced the scratch (changeCount moved), preserving that copy.
    @discardableResult
    private static func restoreIfScratchIntact(_ scratch: ScratchPaste) -> Bool {
        guard scratch.pb.changeCount == scratch.stamp else { return false }
        scratch.snapshot.restore(to: scratch.pb)
        return true
    }

    static func drainPendingRestore() async {
        drainPendingRestoreNow()
    }

    // Synchronous so a main-actor read of the clipboard (the "insert clipboard contents" command) can drain
    // ahead of itself with no suspension for a pending restore to slip through.
    static func drainPendingRestoreNow() {
        guard let scratch = pendingRestore else { return }
        pendingRestoreGeneration &+= 1
        pendingRestoreBackstop?.cancel()
        pendingRestoreBackstop = nil
        pendingRestore = nil
        restoreIfScratchIntact(scratch)
    }

    // Temporary clipboard write for the paste, verified before the caller is allowed to ⌘V. Transient +
    // concealed so clipboard managers don't capture the dictated text (may contain just-restored sensitive
    // spans). Returns false if after a few attempts the scratch isn't there, so the caller refuses to ⌘V
    // stale content. A lazy `.string` is verified by its advertised type: reading it back would fire our
    // own provider and count as the target's paste.
    private static func writeScratchVerified(
        _ text: String, to pb: NSPasteboard = .general, concealed: Bool = true,
        provider: ScratchProvider? = nil, attempts: Int = 3
    ) -> Bool {
        for _ in 0..<attempts {
            let item = NSPasteboardItem()
            if let provider {
                item.setDataProvider(provider, forTypes: [.string])
            } else {
                item.setString(text, forType: .string)
            }
            if concealed {
                item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            }
            pb.clearContents()
            guard pb.writeObjects([item]) else { continue }
            if provider != nil {
                if pb.pasteboardItems?.first?.types.contains(.string) == true { return true }
            } else if pb.string(forType: .string) == text {
                return true
            }
        }
        return false
    }

    // Fulfils the lazy `.string` flavor and stamps the first request. Measured 2026-09-03: only the FIRST
    // read is observed (the pasteboard then caches the string and releases the provider); nothing identifies
    // the reader, so a clipboard manager that reads the string is indistinguishable from the target's paste;
    // and a cross-process read is fulfilled on THIS process's main run loop, so the target's ⌘V blocks until
    // it turns. An in-process read fulfils on the reading thread, hence the lock.
    final class ScratchProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
        private let text: String
        private let lock = NSLock()
        private var readAt: ContinuousClock.Instant?

        init(text: String) {
            self.text = text
        }

        var firstReadAt: ContinuousClock.Instant? {
            lock.lock()
            defer { lock.unlock() }
            return readAt
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString(text, forType: type)
            lock.lock()
            if readAt == nil { readAt = ContinuousClock.now }
            lock.unlock()
        }
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
    static func pasteReturning(to target: NSRunningApplication, text: String, paste: ClipboardPaste = .init()) async -> Bool {
        target.activate()
        guard await waitUntilFrontmost(target) else { return false }
        try? await Task.sleep(for: .milliseconds(120))
        return await insertViaPaste(text, paste: paste)
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
    static func insertViaAX(_ text: String, paste: ClipboardPaste = .init(), awaitSettle: Bool = true) async -> Bool {
        if axInsertVerified(text) {
            Log.insertion.notice("ax-insert: succeeded")
            return true
        }
        Log.insertion.notice("ax-insert: unverified here, falling back to paste")
        return await insertViaPaste(text, paste: paste, awaitSettle: awaitSettle)
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

    // Best-effort typed keystrokes; there is no acceptance signal to drive fallback. The targets this path
    // exists for (a VM hypervisor, a remote client) translate the event's VIRTUAL KEY and drop the unicode
    // payload entirely — VMware Fusion delivers keycode 0, a literal "a", even with a one-character payload —
    // so every character the active layout can produce posts as a real keycode with its modifiers as
    // physical key events. Off-layout characters (é, emoji) fall back to payload events, which land in
    // native apps only; that loss is inherent to a translating target. The cost is a long insert holding
    // .inserting for the whole run, so a trigger pressed mid-insert is dropped by beginArming
    // (DictationController.noteBusyPress).
    @discardableResult
    static func insertViaTyping(_ text: String) async -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let layout = KeyboardLayout.currentIndex()
        var typedAny = false
        for character in text {
            // Checked per character, not once up front: this loop suspends between every keystroke, so a
            // capture loss can land mid-word. Unlike a paste this is not one undo, and stopping leaves less
            // wrong text behind than typing the rest of a take the microphone never finished recording.
            if insertionAborted {
                Log.insertion.notice("typing: stopped mid-insert — the capture this text came from was lost")
                return typedAny
            }
            typedAny = true
            // The seam replaces only the event post; the per-character suspension below still runs, since
            // that is the window the abort check exists for and what a test driving this must reproduce.
            if let sink = typedCharacterSink {
                sink(character)
            } else if let stroke = layout?.stroke(for: character) {
                postKey(CGKeyCode(stroke.keyCode), flags: eventFlags(stroke.modifiers), physicalModifiers: true)
            } else {
                for chunk in TypedText.keyEventChunks(String(character)) {
                    for keyDown in [true, false] {
                        guard let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: keyDown) else { continue }
                        event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                        event.post(tap: .cghidEventTap)
                    }
                }
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

    private static func eventFlags(_ modifiers: Set<Modifier>) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            }
        }
        return flags
    }

    // A foreign target (VM guest, remote session) reads key codes off the wire rather than the CGEvent
    // flags a macOS app reads, so its modifiers must be posted as real key events around the chord.
    private static func postKey(_ keystroke: ClipboardKeystroke) -> Bool {
        guard let keyCode = keystroke.keyCode(in: KeyboardLayout.current()) else {
            Log.insertion.error(
                "clipboard chord \(keystroke.canonical, privacy: .public) is absent from the active keyboard layout")
            return false
        }
        postKey(CGKeyCode(keyCode), flags: eventFlags(keystroke.modifiers),
                physicalModifiers: keystroke.isForeignTarget)
        return true
    }

    private static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, 55),
        (.maskShift, 56),
        (.maskAlternate, 58),
        (.maskControl, 59),
    ]

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, physicalModifiers: Bool = false) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let held = physicalModifiers ? modifierKeys.filter { flags.contains($0.0) } : []
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
