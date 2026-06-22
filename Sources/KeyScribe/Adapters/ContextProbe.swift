import AppKit
import ApplicationServices
import KeyScribeKit

@MainActor
enum ContextProbe {
    static func snapshot() -> TargetSnapshot {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return TargetSnapshot(bundleId: bundleId, focusedElementId: nil)
    }

    static func appName(forBundleId bundleId: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.localizedName
    }

    // Visible on-screen text for a mode that opted into visible-text context (design.md §4.4).
    // Reads the Accessibility tree (no screenshot/OCR — verified sufficient across native/WebKit/
    // Chrome/Electron). Runs off the main actor with a messaging timeout + wall-clock deadline so a
    // slow app (some native AX trees take ~1s) never blocks the dictation flow. Best-effort: nil
    // when AX exposes nothing.
    static func visibleText(forBundleId bundleId: String, maxChars: Int = 8000) async -> String? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first?.processIdentifier else { return nil }
        return await Task.detached { AXVisibleText.capture(pid: pid, maxChars: maxChars) }.value
    }

    // Bounded text immediately before the caret in the focused field, for a mode that opted into
    // preceding-text context (design.md §4.4). Read straight from the focused element's selected range
    // via AX — precise and native-only: Chromium/Electron expose no caret range, so this returns nil
    // there (best-effort, like visible text). Privacy mode forces the opt-in off upstream
    // (Mode.effectiveContext), so this is never called when redaction is active.
    static func precedingText(maxChars: Int = 600) async -> String? {
        await Task.detached { precedingTextSync(maxChars: maxChars) }.value
    }

    // Synchronous AX walk, run off the main actor (each AXUIElementCopy… is cross-process IPC; a slow
    // target must never stall the dictation flow on the main thread). A per-element messaging timeout
    // bounds a wedged AX server.
    nonisolated private static func precedingTextSync(maxChars: Int) -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
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

    // Browser URL for URL-constrained modes (design.md §4.4): AppleScript/Apple Events, never AX
    // (AX returns nil on Chromium — M0 fact). "Is it a browser" comes from Launch Services (any app
    // registered to open https), so no bundle-id list. The URL itself uses one of two AppleScript
    // dialects (WebKit document- vs Chromium tab-based); we try both against the same app rather
    // than map which one it speaks. A non-browser sends no Apple event, so the Automation prompt
    // only appears for an actual browser, and only once (permission is per source→target pair).
    static func browserURL(forBundleId bundleId: String) -> String? {
        guard handlesHTTPS(bundleId) else { return nil }
        for property in ["URL of active tab of front window", "URL of front document"] {
            let source = "tell application id \"\(bundleId)\" to return \(property)"
            guard let script = compiledScript(source) else { continue }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error == nil, let url = result.stringValue, !url.isEmpty { return url }
        }
        return nil
    }

    // NSAppleScript compiles its source on first execution; reusing the same object across dictations
    // avoids recompiling the (per-bundle) script every time a URL-constrained mode runs.
    private static var compiledScripts: [String: NSAppleScript] = [:]
    private static func compiledScript(_ source: String) -> NSAppleScript? {
        if let cached = compiledScripts[source] { return cached }
        guard let script = NSAppleScript(source: source) else { return nil }
        compiledScripts[source] = script
        return script
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

// Off-main Accessibility-tree walk. Scopes to the largest scrollable content region (the message
// pane / article / note body / document), preferring the one holding the focused element, so the
// sidebar / nav / file-tree chrome is excluded; falls back to the whole focused window. Bounded by
// a per-call messaging timeout, a wall-clock deadline, and node/depth caps.
enum AXVisibleText {
    private static let messagingTimeout: Float = 0.3
    private static let deadline: TimeInterval = 0.7
    private static let wakeDeadline: TimeInterval = 1.0
    private static let maxNodes = 4000
    private static let maxDepth = 60
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXTextView"]
    private static let regionRoles: Set<String> = ["AXScrollArea", "AXWebArea"]

    static func capture(pid: pid_t, maxChars: Int) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        if let text = read(app: app, deadline: deadline, maxChars: maxChars) { return text }
        // Empty tree — the case for lazy-AX Electron apps (VS Code, Claude desktop) that only expose
        // their AX tree once an assistive technology asks. Set Electron's documented
        // AXManualAccessibility wake on the app element and retry. Strictly safe: only runs when the
        // cold read already yielded nothing, so apps that read cold (browsers/native/Antigravity) are
        // never touched; a harmless no-op (-25205 unsupported) on non-Electron. The wake persists, so
        // even if this first read is too early for the tree to build, the next dictation reads cold.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return read(app: app, deadline: wakeDeadline, maxChars: maxChars)
    }

    // `maxChars` stops the walk once enough text is gathered — the downstream context budget caps the
    // result anyway, so a large window's tree need not be fully traversed or its strings retained.
    private static func read(app: AXUIElement, deadline: TimeInterval, maxChars: Int) -> String? {
        guard let window = focusedWindow(of: app) else { return nil }
        let windowFrame = frame(window)
        let stopAt = Date().addingTimeInterval(deadline)
        let root = contentRegion(in: window, focused: focusedElement(of: app), windowFrame: windowFrame, stopAt: stopAt) ?? window

        var texts: [String] = []
        var seen = Set<AXKey>()
        var nodes = 0
        var chars = 0

        func collect(_ el: AXUIElement, _ depth: Int) {
            if nodes >= maxNodes || depth > maxDepth || chars >= maxChars || Date() >= stopAt { return }
            let key = AXKey(el)
            if seen.contains(key) { return }
            seen.insert(key)
            nodes += 1
            let role = string(el, kAXRoleAttribute as String) ?? ""
            if textRoles.contains(role), onScreen(el, clip: windowFrame), let s = visibleString(el, role: role) {
                texts.append(s)
                chars += s.count
            }
            for child in children(el) { collect(child, depth + 1) }
        }
        collect(root, 0)

        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func contentRegion(in window: AXUIElement, focused: AXUIElement?,
                                      windowFrame: CGRect?, stopAt: Date) -> AXUIElement? {
        let focusedFrame = focused.flatMap { frame($0) }
        let windowArea = windowFrame.map { $0.width * $0.height } ?? 0
        guard windowArea > 0 else { return nil }
        var best: (el: AXUIElement, area: CGFloat)?
        var bestContainingFocus: (el: AXUIElement, area: CGFloat)?
        var nodes = 0
        func visit(_ el: AXUIElement, _ depth: Int) {
            if nodes >= maxNodes || depth > maxDepth || Date() >= stopAt { return }
            nodes += 1
            if regionRoles.contains(string(el, kAXRoleAttribute as String) ?? ""), let f = frame(el) {
                let area = f.width * f.height
                if area > (best?.area ?? 0) { best = (el, area) }
                if let ff = focusedFrame, f.intersects(ff), area > (bestContainingFocus?.area ?? 0) {
                    bestContainingFocus = (el, area)
                }
            }
            for child in children(el) { visit(child, depth + 1) }
        }
        visit(window, 0)
        guard let chosen = bestContainingFocus ?? best, chosen.area >= 0.2 * windowArea else { return nil }
        return chosen.el
    }

    private static func visibleString(_ el: AXUIElement, role: String) -> String? {
        if role == "AXTextArea" || role == "AXTextView",
           let rangeV = copy(el, "AXVisibleCharacterRange"), CFGetTypeID(rangeV) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue((rangeV as! AXValue), .cfRange, &range), range.length > 0, range.length < 200_000,
               let rv = AXValueCreate(.cfRange, &range) {
                var out: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(el, "AXStringForRange" as CFString, rv, &out) == .success,
                   let s = out as? String, !s.isEmpty { return s }
            }
        }
        for attr in [kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
            if let s = string(el, attr), !s.isEmpty { return s }
        }
        return nil
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        if let v = copy(app, kAXFocusedWindowAttribute as String) { return (v as! AXUIElement) }
        if let v = copy(app, kAXMainWindowAttribute as String) { return (v as! AXUIElement) }
        return nil
    }

    private static func focusedElement(of app: AXUIElement) -> AXUIElement? {
        copy(app, kAXFocusedUIElementAttribute as String).map { ($0 as! AXUIElement) }
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        guard let v = copy(el, kAXChildrenAttribute as String) else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posV = copy(el, kAXPositionAttribute as String),
              let sizeV = copy(el, kAXSizeAttribute as String),
              CFGetTypeID(posV) == AXValueGetTypeID(), CFGetTypeID(sizeV) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue((posV as! AXValue), .cgPoint, &pt)
        AXValueGetValue((sizeV as! AXValue), .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    private static func onScreen(_ el: AXUIElement, clip: CGRect?) -> Bool {
        guard let clip, let f = frame(el) else { return true }
        return clip.intersects(f)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? { copy(el, attr) as? String }

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private struct AXKey: Hashable {
        let el: AXUIElement
        init(_ el: AXUIElement) { self.el = el }
        static func == (l: AXKey, r: AXKey) -> Bool { CFEqual(l.el, r.el) }
        func hash(into h: inout Hasher) { h.combine(CFHash(el)) }
    }
}
