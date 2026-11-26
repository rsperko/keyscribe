import ApplicationServices
import CoreGraphics
import Foundation
import KeyScribeKit
import os

private let mouseLog = Logger(subsystem: "com.keyscribe.app", category: "hotkey")

// A consuming tap for non-primary mouse buttons.
@MainActor
protocol MouseTapping: AnyObject {
    var onEdge: ((Int, TriggerEdge, UInt64) -> Void)? { get set }
    func setConsumedButtons(_ buttons: Set<Int>)
}

// An active (`.defaultTap`) session tap on `otherMouseDown`/`otherMouseUp`, so a bound mouse button is
// swallowed before the focused app sees it (else its normal action — e.g. browser back/forward — fires too).
//
// FOOTGUN: an active tap is synchronous (the window server blocks until the callback returns), so it MUST
// run on its own `EventTapThread`, never the main run loop — a wedged main thread would hold global input
// hostage. The callback reads a lock-guarded button set and hands the edge to main async; it never touches
// audio, AX, SwiftUI, or AppleScript.
@MainActor
final class MouseEventTap: MouseTapping {
    var onEdge: ((Int, TriggerEdge, UInt64) -> Void)?

    private nonisolated let consumed = OSAllocatedUnfairLock<Set<Int>>(initialState: [])
    private var thread: EventTapThread?
    private let isProcessTrusted: () -> Bool

    init(isProcessTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isProcessTrusted = isProcessTrusted
    }

    func setConsumedButtons(_ buttons: Set<Int>) {
        consumed.withLock { $0 = buttons }
        if !buttons.isEmpty { ensureRunning() }
    }

    // FOOTGUN: the mouse tap needs Accessibility, and `tapCreate` before the grant leaves a denied record.
    // A refused tap leaves `thread` nil, so the post-grant retry creates a live one.
    private func ensureRunning() {
        guard thread == nil, isProcessTrusted() else { return }
        let thread = EventTapThread(name: "com.keyscribe.mousetap") { [weak self] type, event in
            guard let self, self.received(type: type, event: event) else {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }
        let mask = CGEventMask(
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue))
        let created = thread.start { userInfo in
            CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: eventTapThreadCallback, userInfo: userInfo)
        }
        guard created else {
            mouseLog.error("mouse event tap not created; Accessibility verdict is likely cached as denied from launch — relaunch needed")
            return
        }
        self.thread = thread
        mouseLog.info("mouse event tap active on dedicated thread")
    }

    nonisolated func received(type: CGEventType, event: CGEvent) -> Bool {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard consumed.withLock({ $0.contains(button) }) else { return false }
        let edge: TriggerEdge = type == .otherMouseDown ? .down : .up
        let at = event.timestamp != 0 ? event.timestamp : DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onEdge?(button, edge, at) }
        }
        return true
    }
}
