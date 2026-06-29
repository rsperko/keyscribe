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
//
// Cross-thread discipline (the tap thread runs concurrently with main, so this is load-bearing): the
// callback finds the instance through the tap's `userInfo` pointer (set when the tap is created), NOT a
// shared global — `self` is held alive on the tap thread's stack for the entire run loop, so an unretained
// pointer is safe and there is no global weak to race. The CFMachPort tap is created, re-enabled, and
// disposed ONLY on the tap thread — main never touches it. The single piece main reaches is the tap
// thread's run loop, handed off under a lock, used only to signal teardown.
@MainActor
final class MouseEventTap: MouseTapping {
    var onEdge: ((Int, TriggerEdge) -> Void)?

    // Read on the tap thread, written on main. Thread-safe by construction.
    fileprivate let consumed = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    // The CFMachPort tap: created, re-enabled (reEnable), and disposed ONLY on the tap thread, so its
    // access needs no cross-thread synchronization. main no longer touches it (teardown goes via `control`).
    nonisolated(unsafe) fileprivate var tap: CFMachPort?

    // The only state shared between main and the tap thread for teardown. main's stop() sets `stopRequested`
    // and stops the published loop; the tap thread publishes its loop here, or — if stop() already fired —
    // sees the request and skips running the loop (closing the start-vs-stop race). Lock-guarded both ways.
    private struct Control { var runLoop: CFRunLoop?; var stopRequested = false }
    private let control = OSAllocatedUnfairLock(uncheckedState: Control())

    private var thread: Thread?

    func setConsumedButtons(_ buttons: Set<Int>) {
        consumed.withLock { $0 = buttons }
        if !buttons.isEmpty { ensureRunning() }
    }

    // The thread is created at most once and lives for the app's lifetime — config reloads and
    // suspend/resume only swap the lock-guarded set, never spawn or kill the thread, so there is no
    // per-change lifecycle to race on. stop() is a TERMINAL teardown (app exit / test seam), not designed
    // to be followed by a restart.
    private func ensureRunning() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.runTapLoop() }
        t.name = "com.keyscribe.mousetap"
        t.start()
        thread = t
    }

    private nonisolated func runTapLoop() {
        let mask = CGEventMask(
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue))
        // `self` is strongly held on this stack frame for the whole CFRunLoopRun() below, and the OS fires
        // the callback only while that loop runs — so passing `self` UNRETAINED via userInfo is safe and
        // lets the callback reach the instance without a cross-thread global weak (the prior data race).
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            mouseLog.error("mouse event tap not created; Accessibility verdict is likely cached as denied from launch — relaunch needed")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let rl = CFRunLoopGetCurrent()
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Publish the loop for stop(), unless stop() already fired before we got here — then skip running
        // the loop and fall straight to teardown, so a stop() that raced startup never leaves it spinning.
        // withLockUnchecked: CFRunLoop is not Sendable, so it cannot cross the @Sendable `withLock` closure
        // boundary. Access is still serialized by the lock; only the compile-time Sendable check is waived.
        let run = control.withLockUnchecked { c -> Bool in
            guard !c.stopRequested else { return false }
            c.runLoop = rl
            return true
        }
        if run {
            mouseLog.info("mouse event tap active on dedicated thread")
            CFRunLoopRun()
            control.withLockUnchecked { $0.runLoop = nil }
        }
        CFRunLoopRemoveSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    // macOS disables the tap (emitting one of these) if the callback is slow or under certain input
    // conditions; re-enable or the tap goes permanently deaf. Called from the tap thread (the callback).
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
        // Signal the tap thread to exit; it disables + disposes the tap on its OWN thread (runTapLoop
        // teardown), so main never touches `tap`. Setting stopRequested also covers the case where the tap
        // thread has not yet published its run loop.
        control.withLockUnchecked { c in
            c.stopRequested = true
            if let rl = c.runLoop { CFRunLoopStop(rl) }
        }
        thread = nil
    }
}

private func mouseTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let inst = Unmanaged<MouseEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        inst.reEnable()
        return Unmanaged.passUnretained(event)
    }
    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
    guard inst.consumed.withLock({ $0.contains(button) }) else { return Unmanaged.passUnretained(event) }
    inst.deliver(button: button, edge: type == .otherMouseDown ? .down : .up)
    return nil
}
