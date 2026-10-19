import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AXWindowID {
    nonisolated static func of(_ window: AXUIElement) -> CGWindowID? {
        var windowID = CGWindowID(0)
        return _AXUIElementGetWindow(window, &windowID) == .success && windowID != 0 ? windowID : nil
    }
}
