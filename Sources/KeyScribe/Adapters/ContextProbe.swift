import AppKit
import ApplicationServices
import KeyScribeKit

// Private AX SPI: the CGWindowID backing an AXUIElement window, stable for the window's lifetime.
// Used to tell two windows of the same app apart so a focus move during an LLM round-trip diverts to
// the clipboard instead of pasting into the wrong window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
enum ContextProbe {
    static func initialSnapshot() -> TargetSnapshot {
        TargetSnapshot(bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    static func snapshot() -> TargetSnapshot {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return TargetSnapshot(
            bundleId: bundleId,
            focusedWindowId: bundleId.flatMap(focusedWindowId(bundleId:)),
            isSecureField: focusedIsSecure())
    }

    // Best-effort secure-field detection. AX failures return false, and some browser password inputs do
    // not expose the AXSecureTextField subrole, so this is a guard rather than a guarantee.
    static func focusedIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              let subrole = subroleRef as? String else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    // A stable id for the frontmost app's focused window, so decideInsertion can catch a same-app window
    // switch between capture and insertion. Best-effort: a nil id never blocks insertion.
    //
    // Synchronous on purpose: snapshot() is read on the hot key-down path (handleStart) and again at
    // insertion, both @MainActor, so it cannot await. A tight per-element messaging timeout (mirrors
    // precedingTextSync, ContextProbe.swift) bounds a wedged AX server so it never stalls the dictation
    // flow. Preferred id is the CGWindowID via the _AXUIElementGetWindow SPI; falls back to a
    // title+position+size composite when the SPI is unavailable.
    static func focusedWindowId(bundleId: String) -> String? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let window = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.1)

        var windowID = CGWindowID(0)
        if _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 {
            return "cg:\(windowID)"
        }

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

    // The focused window's title for a window-title-constrained mode. Best-effort: nil if AX exposes no
    // title.
    static func focusedWindowTitle(bundleId: String) -> String? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let window = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.1)
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    // Bounded text immediately before the caret in the focused field. Chromium/Electron expose no caret
    // range through AX, so this returns nil there.
    static func precedingText(forBundleId bundleId: String, maxChars: Int = 600) async -> String? {
        // Scope to the captured app. precedingText is read at rewrite time — after STT
        // and partway into the LLM round trip — so resolving the live system-wide focused element would
        // read whatever the user has since switched to, feeding the wrong field's (possibly sensitive)
        // text to the LLM. Read only when the captured app is still frontmost, via that app's own focused
        // element, so a switch away yields nil rather than another app's text.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                  .first?.processIdentifier else { return nil }
        return await Task.detached { precedingTextSync(pid: pid, maxChars: maxChars) }.value
    }

    // Synchronous AX walk, run off the main actor (each AXUIElementCopy… is cross-process IPC; a slow
    // target must never stall the dictation flow on the main thread). A per-element messaging timeout
    // bounds a wedged AX server.
    nonisolated private static func precedingTextSync(pid: pid_t, maxChars: Int) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)

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
        return text
    }

    // Browser URL for URL-constrained modes: AppleScript/Apple Events, never AX. Browser identity comes
    // from Launch Services rather than a bundle-id list, and the URL read tries both common script dialects.
    //
    // The Apple Event is a synchronous cross-process round trip with no per-call timeout (NSAppleScript
    // uses kAEDefaultTimeout, ~2 min), so it runs off the main actor. The serial AppleScript queue avoids
    // starving the cooperative pool; whichever of the fetch or the 0.6s timeout fires first wins.
    static func browserURLAsync(forBundleId bundleId: String) async -> String? {
        guard handlesHTTPS(bundleId) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = OnceResume()
            appleScriptQueue.async {
                let url = fetchBrowserURL(bundleId)
                if once.claim() { continuation.resume(returning: url) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
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
