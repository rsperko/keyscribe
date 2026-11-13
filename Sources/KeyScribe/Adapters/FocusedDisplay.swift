import AppKit
import CoreGraphics

@MainActor
enum FocusedDisplay {
    // Reads window geometry from the window server (CGWindowList), not the target app's AX tree, so this
    // can never block on an unresponsive app. nil ⇒ the caller keeps the display it already uses.
    static func screen() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        // Front-to-back order: the first normal (layer 0) window owned by the frontmost app is its key window.
        for info in infos {
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid,
                  ((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0,
                  let boundsDict = info[kCGWindowBounds as String] else { continue }
            var quartz = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as! CFDictionary, &quartz) else { continue }
            return screen(forQuartzRect: quartz)
        }
        return nil
    }


    // CGWindowList rects are top-left-origin global (Quartz); flip to AppKit's bottom-left space against the
    // primary screen, then pick the NSScreen with the largest overlap (falling back to the one under center).
    private static func screen(forQuartzRect quartz: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? quartz.maxY
        let cocoa = CGRect(x: quartz.origin.x, y: primaryHeight - quartz.origin.y - quartz.height,
                           width: quartz.width, height: quartz.height)
        let overlap = NSScreen.screens.max { area($0.frame.intersection(cocoa)) < area($1.frame.intersection(cocoa)) }
        if let overlap, area(overlap.frame.intersection(cocoa)) > 0 { return overlap }
        let center = CGPoint(x: cocoa.midX, y: cocoa.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}

@MainActor
struct HUDDisplays {
    var focused: () -> CGDirectDisplayID?
    var holding: (NSWindow) -> CGDirectDisplayID?
    var visibleFrame: (CGDirectDisplayID) -> CGRect?
    var followsScreenChanges = true

    static var live: HUDDisplays {
        HUDDisplays(
            focused: { FocusedDisplay.screen()?.displayID },
            holding: { ($0.screen ?? NSScreen.main)?.displayID },
            visibleFrame: { id in NSScreen.screens.first { $0.displayID == id }?.visibleFrame })
    }

    func withVisibleHeight(_ height: CGFloat?) -> HUDDisplays {
        guard let height else { return self }
        var displays = self
        let frame = visibleFrame
        displays.visibleFrame = { id in frame(id).map { CGRect(origin: $0.origin, size: CGSize(width: $0.width, height: height)) } }
        return displays
    }

    func frame(pinned: CGDirectDisplayID?, panel: NSWindow?) -> CGRect? {
        if let pinned, let frame = visibleFrame(pinned) { return frame }
        return panel.flatMap(holding).flatMap(visibleFrame)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
