import CoreGraphics
import Foundation
import KeyScribeKit
import os

private let mouseLog = Logger(subsystem: "com.keyscribe.app", category: "hotkey")

// A consuming tap for non-primary mouse buttons. The seam lets `HotkeyMonitor` be unit-tested without
// the OS, the same way `ChordRegistering` does for Carbon chords.
@MainActor
protocol MouseTapping: AnyObject {
    var onEdge: ((Int, TriggerEdge) -> Void)? { get set }
    func setConsumedButtons(_ buttons: Set<Int>)
    func stop()
}

// An ACTIVE (`.defaultTap`) session tap on `otherMouseDown`/`otherMouseUp`, so a bound mouse button is
// swallowed before the focused app sees it (otherwise the button's normal action — e.g. browser
// back/forward — would fire alongside dictation). Mouse-button events, unlike `keyDown`, are delivered
// under Accessibility alone — no Input Monitoring — so this stays within keyscribe's permission stance.
//
// Footgun: an active tap is SYNCHRONOUS — the window server blocks until the callback returns. The
// modifier `HotkeyMonitor` tap is `.listenOnly` precisely so a wedged main thread can never hold global
// input hostage. We cannot do that here (a listen-only tap can't consume), so the tap instead runs on a
// DEDICATED run-loop thread, never the main run loop. The callback only reads a lock-guarded button set
// and hands the edge to main asynchronously; it touches no audio/AX/SwiftUI/AppleScript, so nothing it
// does can stall for seconds, and a wedged MAIN thread is a different thread that cannot block it. This
// is the same isolation every mouse utility (SensibleSideButtons, Scroll Reverser, Mos) relies on.
@MainActor
final class MouseEventTap: MouseTapping {
    var onEdge: ((Int, TriggerEdge) -> Void)?

    // Read on the tap thread, written on main. The ONLY cross-thread state, behind one lock.
    fileprivate let consumed = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    // Set on the tap thread in `runTapLoop`, torn down on main in `stop`.
    nonisolated(unsafe) fileprivate var tap: CFMachPort?
    nonisolated(unsafe) private var runLoop: CFRunLoop?
    private var thread: Thread?

    func setConsumedButtons(_ buttons: Set<Int>) {
        consumed.withLock { $0 = buttons }
        if !buttons.isEmpty { ensureRunning() }
    }

    // The thread is created at most once and lives for the app's lifetime — config reloads and
    // suspend/resume only swap the lock-guarded set, never spawn or kill the thread, so there is no
    // per-change lifecycle to race on.
    private func ensureRunning() {
        guard thread == nil else { return }
        activeMouseEventTap = self
        let t = Thread { [weak self] in self?.runTapLoop() }
        t.name = "com.keyscribe.mousetap"
        t.start()
        thread = t
    }

    private nonisolated func runTapLoop() {
        let mask = CGEventMask(
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: mouseTapCallback, userInfo: nil)
        else {
            mouseLog.error("mouse event tap not created; Accessibility verdict is likely cached as denied from launch — relaunch needed")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let rl = CFRunLoopGetCurrent()
        self.runLoop = rl
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        mouseLog.info("mouse event tap active on dedicated thread")
        CFRunLoopRun()
        CFRunLoopRemoveSource(rl, source, .commonModes)
    }

    // macOS disables the tap (emitting one of these) if the callback is slow or under certain input
    // conditions; re-enable or the tap goes permanently deaf. Called from the tap thread.
    fileprivate nonisolated func reEnable() {
        guard let tap else { return }
        mouseLog.error("mouse event tap disabled; re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Hand the edge to main; the real gesture work (engine resolve, audio, HUD) belongs there. The
    // consume decision already happened synchronously on the tap thread — only the side effect defers.
    fileprivate nonisolated func deliver(button: Int, edge: TriggerEdge) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onEdge?(button, edge) }
        }
    }

    func stop() {
        consumed.withLock { $0 = [] }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
        activeMouseEventTap = nil
    }
}

nonisolated(unsafe) private weak var activeMouseEventTap: MouseEventTap?

private func mouseTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        activeMouseEventTap?.reEnable()
        return Unmanaged.passUnretained(event)
    }
    guard let inst = activeMouseEventTap else { return Unmanaged.passUnretained(event) }
    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
    guard inst.consumed.withLock({ $0.contains(button) }) else { return Unmanaged.passUnretained(event) }
    inst.deliver(button: button, edge: type == .otherMouseDown ? .down : .up)
    return nil
}
