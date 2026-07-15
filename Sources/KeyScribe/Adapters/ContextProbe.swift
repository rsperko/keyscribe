import AppKit
import ApplicationServices
import KeyScribeKit

// Private AX SPI for the CGWindowID backing an AXUIElement window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
enum ContextProbe {
    static func initialSnapshot() -> TargetSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        guard let pid = front?.processIdentifier else {
            return TargetSnapshot(bundleId: front?.bundleIdentifier, pid: nil)
        }
        // Capture the secure-field flag synchronously at press so a dictation begun in a password field is
        // protected immediately — before, and independent of, the async full snapshot, which could otherwise
        // read a non-secure field if focus moved within the same process before it ran (secure is sticky:
        // adoption OR-s this with the full read, KS-01). Bounded by the AX messaging timeout; the window id
        // is left to the async snapshot, which carries the HUD exclusion this hot path doesn't.
        return TargetSnapshot(bundleId: front?.bundleIdentifier, pid: pid, isSecureField: focusedIsSecure(pid: pid))
    }

    // Pid-scoped secure-field check (focused element's subrole), no window walk — for the synchronous press
    // path where only the secure flag is needed and latency matters.
    nonisolated static func focusedIsSecure(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let focused = axChild(app, attribute: kAXFocusedUIElementAttribute) else { return false }
        return subrole(of: focused) == (kAXSecureTextFieldSubrole as String)
    }

    // Exclude our HUD when dictating into KeyScribe itself, where the HUD can become the key window.
    static func snapshot(excludingWindow excluded: CGWindowID? = nil) -> TargetSnapshot {
        // Read the frontmost app once and use its own pid, so every AX probe queries the exact process that
        // supplied the bundle id — not an arbitrary same-bundle instance a bundle-id lookup might resolve to,
        // and not whichever process happens to own system-wide focus at read time.
        let front = NSWorkspace.shared.frontmostApplication
        guard let pid = front?.processIdentifier else {
            return TargetSnapshot(bundleId: front?.bundleIdentifier, pid: nil)
        }
        let state = focusedState(pid: pid, excluding: excluded)
        return TargetSnapshot(
            bundleId: front?.bundleIdentifier, pid: pid,
            focusedWindowId: state.windowId, isSecureField: state.isSecure)
    }

    // Off-main variant of `snapshot`: the frontmost-app identity is read on the main actor, then the AX
    // round trips (each bounded by a 0.1s messaging timeout, but able to stall on an unresponsive target)
    // run on a detached task so an arming or insert never blocks the main actor. Mirrors `precedingText`.
    static func snapshotAsync(excludingWindow excluded: CGWindowID? = nil) async -> TargetSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        let bundleId = front?.bundleIdentifier
        let pid = front?.processIdentifier
        let snapshot: TargetSnapshot = await Task.detached {
            guard let pid else { return TargetSnapshot(bundleId: bundleId, pid: nil) }
            let state = focusedState(pid: pid, excluding: excluded)
            return TargetSnapshot(bundleId: bundleId, pid: pid,
                                  focusedWindowId: state.windowId, isSecureField: state.isSecure)
        }.value
        // Focus can move during the (potentially stalling) detached AX walk. If the frontmost process is no
        // longer the one we walked, the window/secure fields describe a stale target — report the CURRENT
        // identity instead, so snapshot adoption bails conservatively and insertion diverts (KS-01).
        let now = NSWorkspace.shared.frontmostApplication
        if now?.processIdentifier != pid {
            return TargetSnapshot(bundleId: now?.bundleIdentifier, pid: now?.processIdentifier)
        }
        return snapshot
    }

    // One AX walk from the captured pid's focused element, so the window id and secure-field flag describe
    // the SAME focused element — a field/window switch between two independent reads can't pair one window
    // with another field's secure status (KS-01). AX failures degrade to a best-effort window id and
    // non-secure; a nil window never blocks insertion.
    nonisolated static func focusedState(pid: pid_t, excluding excluded: CGWindowID? = nil) -> (windowId: String?, isSecure: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let focused = axChild(app, attribute: kAXFocusedUIElementAttribute) else {
            return (appFocusedWindowId(app: app, excluding: excluded), false)
        }
        let isSecure = subrole(of: focused) == (kAXSecureTextFieldSubrole as String)
        return (windowId(ofElement: focused, app: app, excluding: excluded), isSecure)
    }

    // The window id string for a given element's containing window, honoring the HUD exclusion. Falls back to
    // the app's focused window when the element exposes no window attribute.
    nonisolated private static func windowId(ofElement element: AXUIElement, app: AXUIElement, excluding excluded: CGWindowID?) -> String? {
        guard let window = axChild(element, attribute: kAXWindowAttribute) else {
            return appFocusedWindowId(app: app, excluding: excluded)
        }
        if let excluded, cgWindowID(of: window) == excluded {
            guard let main = axChild(app, attribute: kAXMainWindowAttribute) else { return nil }
            return windowIdString(of: main)
        }
        return windowIdString(of: window)
    }

    nonisolated private static func appFocusedWindowId(app: AXUIElement, excluding excluded: CGWindowID?) -> String? {
        guard let focused = axChild(app, attribute: kAXFocusedWindowAttribute) else { return nil }
        if let excluded, cgWindowID(of: focused) == excluded {
            guard let main = axChild(app, attribute: kAXMainWindowAttribute) else { return nil }
            return windowIdString(of: main)
        }
        return windowIdString(of: focused)
    }

    nonisolated private static func subrole(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref) == .success,
              let subrole = ref as? String else { return nil }
        return subrole
    }

    // Generic AX child-element fetch with a bounded messaging timeout; nil when the attribute is absent or
    // isn't an element.
    nonisolated private static func axChild(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let child = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(child, 0.1)
        return child
    }

    nonisolated private static func cgWindowID(of window: AXUIElement) -> CGWindowID? {
        var windowID = CGWindowID(0)
        return _AXUIElementGetWindow(window, &windowID) == .success && windowID != 0 ? windowID : nil
    }

    nonisolated private static func windowIdString(of window: AXUIElement) -> String? {
        if let windowID = cgWindowID(of: window) { return "cg:\(windowID)" }

        var components: [String] = []
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String { components.append("t:\(title)") }
        var posRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
           let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() {
            var pt = CGPoint.zero
            AXValueGetValue((posRef as! AXValue), .cgPoint, &pt)
            components.append("p:\(Int(pt.x)),\(Int(pt.y))")
        }
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            var sz = CGSize.zero
            AXValueGetValue((sizeRef as! AXValue), .cgSize, &sz)
            components.append("s:\(Int(sz.width)),\(Int(sz.height))")
        }
        return components.isEmpty ? nil : components.joined(separator: "|")
    }

    static func appName(forBundleId bundleId: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.localizedName
    }

    // Best-effort title for window-title-constrained modes. Bound to the captured pid so routing reads the
    // title of the exact process that started the dictation, not the first process sharing its bundle id.
    // When a captured window id is supplied, the focused window must still be that window (a cg-backed
    // captured id that no longer matches routes on no title) — a same-app window switch can't route on the
    // wrong window's title. A nil captured id means none was established (best-effort, as before).
    static func focusedWindowTitle(pid: pid_t, expectedWindowId: String? = nil) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let window = axChild(app, attribute: kAXFocusedWindowAttribute) else { return nil }
        if let expectedWindowId, expectedWindowId.hasPrefix("cg:") {
            guard let current = cgWindowID(of: window), "cg:\(current)" == expectedWindowId else { return nil }
        }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    // Bounded text immediately before the caret in the focused field. Chromium/Electron expose no caret
    // range through AX, so this returns nil there. Bound to both the captured pid and window: the caller
    // passes the window id frozen at dictation start, and a same-app switch to a different document before or
    // during the read discards the context rather than sourcing it from the wrong window (KS-02).
    static func precedingText(pid: pid_t, windowId: String? = nil, maxChars: Int = 600) async -> String? {
        // Read only while the exact captured process is still frontmost — context is optional, so an
        // identity mismatch discards it silently rather than reading another process's field.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return await Task.detached { precedingTextSync(pid: pid, windowId: windowId, maxChars: maxChars) }.value
    }

    // Synchronous AX walk; caller runs it off the main actor.
    nonisolated private static func precedingTextSync(pid: pid_t, windowId expected: String?, maxChars: Int) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let element = axFocusedElement(app) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.3)

        // Confirm the focused field is still in the captured window BEFORE reading its content.
        guard elementInExpectedWindow(element, expected: expected) else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var selection = CFRange(location: 0, length: 0)
        guard AXValueGetValue((rangeRef as! AXValue), .cfRange, &selection), selection.location > 0 else { return nil }

        let start = max(0, selection.location - maxChars)
        var wanted = CFRange(location: start, length: selection.location - start)
        guard let wantedValue = AXValueCreate(.cfRange, &wanted) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, wantedValue, &out) == .success,
              let text = out as? String, !text.isEmpty else { return nil }
        // Re-confirm AFTER by re-reading the app's CURRENT focused element (not the element we captured — its
        // own window never changes): if focus moved to another window mid-read, discard the text (KS-02).
        guard let afterFocused = axFocusedElement(app),
              elementInExpectedWindow(afterFocused, expected: expected) else { return nil }
        return text
    }

    nonisolated private static func axFocusedElement(_ app: AXUIElement) -> AXUIElement? {
        axChild(app, attribute: kAXFocusedUIElementAttribute)
    }

    // Whether the element's containing window matches the captured window id. Fails CLOSED for outbound
    // context: once a window boundary was captured, an id we can't confirm (unreadable current window, or a
    // captured non-cg composite id that can't be compared against a live CGWindowID) discards the context
    // rather than sending text from a possibly-different document. A nil captured id means no boundary was
    // ever established (nothing to enforce), so it reads best-effort.
    nonisolated private static func elementInExpectedWindow(_ element: AXUIElement, expected: String?) -> Bool {
        guard let expected else { return true }
        guard expected.hasPrefix("cg:"),
              let window = axChild(element, attribute: kAXWindowAttribute),
              let current = cgWindowID(of: window) else { return false }
        return "cg:\(current)" == expected
    }

    // Browser URL for URL-constrained modes; AppleScript runs on a serial queue with a timeout race. The URL
    // selects the mode, and modes can differ in LLM connection, rewrite enablement, and context sharing — so
    // a wrong-window/wrong-process URL affects a content boundary, not just cosmetics. It is therefore bound
    // to the captured target: the captured process must be frontmost and the captured window still focused
    // BOTH immediately before AND after the AppleScript read, else the URL is discarded (the mode falls back
    // to unconstrained routing). Two residuals are irreducible with this mechanism and can't be bound tighter
    // without CGWindowID-targeted browser scripting (out of scope): the same-bundle/multiple-instance ambiguity
    // of `tell application id` (one bundle, several processes), and a tab switch WITHIN the captured window
    // (browser tabs share one AX/CGWindow identity, so there is nothing to validate a tab against).
    static func browserURLAsync(forBundleId bundleId: String, pid: pid_t?, windowId: String?) async -> String? {
        guard handlesHTTPS(bundleId) else { return nil }
        guard targetStillFocused(pid: pid, windowId: windowId) else { return nil }
        let url: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = OnceResume()
            appleScriptQueue.async {
                let url = fetchBrowserURL(bundleId)
                if once.claim() { continuation.resume(returning: url) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
        guard url != nil, targetStillFocused(pid: pid, windowId: windowId) else { return nil }
        return url
    }

    // The captured process is frontmost and (when a cg window was captured) still the focused window. A nil
    // pid or non-cg window id means no such boundary was established, so the weaker available check applies.
    private static func targetStillFocused(pid: pid_t?, windowId: String?) -> Bool {
        guard let pid else { return true }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        guard let windowId, windowId.hasPrefix("cg:") else { return true }
        return focusedState(pid: pid).windowId == windowId
    }

    private final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
    }

    private static let appleScriptQueue = DispatchQueue(label: "com.keyscribe.applescript-url", qos: .userInitiated)

    nonisolated private static func fetchBrowserURL(_ bundleId: String) -> String? {
        for property in ["URL of active tab of front window", "URL of front document"] {
            let source = "tell application id \"\(bundleId)\" to return \(property)"
            guard let script = NSAppleScript(source: source) else { continue }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error == nil, let url = result.stringValue, !url.isEmpty { return url }
        }
        return nil
    }

    private static func handlesHTTPS(_ bundleId: String) -> Bool {
        httpsHandlers.contains(bundleId)
    }

    private static let httpsHandlers: Set<String> = {
        guard let https = URL(string: "https://example.com") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: https)
            .compactMap { Bundle(url: $0)?.bundleIdentifier })
    }()
}
