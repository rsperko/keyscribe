import AppKit
import ApplicationServices

@MainActor
enum AppActivation {
    static func bringForward(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        if app.isHidden { app.unhide() }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, AppWindows.messagingTimeout)
        if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success { return true }
        return app.activate()
    }

    static func bringForwardApp(pid: Int) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.activationPolicy == .regular,
              bringForward(pid: pid_t(pid))
        else { return nil }
        return app.localizedName ?? app.bundleIdentifier ?? "the terminal"
    }
}
