import ApplicationServices
import CoreGraphics
import Foundation
import KeyScribeKit
import os

private let mouseLog = Logger(subsystem: "com.keyscribe.app", category: "hotkey")

// A consuming tap for non-primary mouse buttons.
@MainActor
protocol MouseTapping: AnyObject {
    var onEdge: ((Int, TriggerEdge) -> Void)? { get set }
    func setConsumedButtons(_ buttons: Set<Int>)
    func stop()
}

// An active (`.defaultTap`) session tap on `otherMouseDown`/`otherMouseUp`, so a bound mouse button is
// swallowed before the focused app sees it (else its normal action — e.g. browser back/forward — fires too).
//
// FOOTGUN: an active tap is synchronous (the window server blocks until the callback returns), so it MUST
// run on a dedicated run-loop thread, never the main run loop — a wedged main thread would hold global input
// hostage. The callback reads a lock-guarded button set and hands the edge to main async; it never touches
// audio, AX, SwiftUI, or AppleScript.
//
// The callback finds the instance via the tap's `userInfo` pointer; `self` is held alive on the tap thread's
// stack for the whole run loop, so the unretained pointer is valid while callbacks can fire. The CFMachPort
// is created, re-enabled, and disposed only on the tap thread.
@MainActor
final class MouseEventTap: MouseTapping {
    var onEdge: ((Int, TriggerEdge) -> Void)?

    // Read on the tap thread, written on main. Thread-safe by construction.
    fileprivate let consumed = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    // Created, re-enabled, and disposed only on the tap thread.
    nonisolated(unsafe) fileprivate var tap: CFMachPort?

    // The only state shared between main and the tap thread for teardown. stop() sets `stopRequested` and
    // stops the published loop; the tap thread publishes its loop, or skips running it if stop() already
    // fired (closing the start-vs-stop race). Lock-guarded both ways.
    private struct Control { var runLoop: CFRunLoop?; var stopRequested = false }
    private let control = OSAllocatedUnfairLock(uncheckedState: Control())

    private var thread: Thread?

    func setConsumedButtons(_ buttons: Set<Int>) {
        consumed.withLock { $0 = buttons }
        if !buttons.isEmpty { ensureRunning() }
    }

    // The thread is created at most once and lives for the app's lifetime — reloads and suspend/resume only
    // swap the lock-guarded set. stop() is TERMINAL teardown (app exit / test seam); clearing stopRequested
    // here lets a later restart spawn a live tap instead of one that self-tears-down.
    //
    // FOOTGUN: the mouse tap needs Accessibility. Don't spawn untrusted — tapCreate would fail and leave
    // `thread` non-nil (its run loop already returned), permanently deaf even after a mid-run grant. Gating
    // on AXIsProcessTrusted lets the post-grant retry spawn a live tap instead of no-op'ing.
    private func ensureRunning() {
        guard thread == nil, AXIsProcessTrusted() else { return }
        control.withLockUnchecked { $0.stopRequested = false }
        let t = Thread { [weak self] in self?.runTapLoop() }
        t.name = "com.keyscribe.mousetap"
        t.start()
        thread = t
    }

    private nonisolated func runTapLoop() {
        let mask = CGEventMask(
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue))
        // `self` is held on this stack frame for the whole CFRunLoopRun() below, and callbacks only fire
        // while that loop runs, so the unretained `self` in userInfo is valid.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            mouseLog.error("mouse event tap not created; Accessibility verdict is likely cached as denied from launch — relaunch needed")
            // Clear `thread` so a later ensureRunning() can respawn (the run loop below never ran).
            Task { @MainActor [weak self] in self?.thread = nil }
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let rl = CFRunLoopGetCurrent()
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Publish the loop for stop(), unless stop() already fired. withLockUnchecked because CFRunLoop is
        // not Sendable; access is still lock-serialized, only the compile-time Sendable check is waived.
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

    // macOS disables the tap if the callback is slow or under certain input conditions; re-enable or it goes
    // permanently deaf. Called from the tap thread.
    fileprivate nonisolated func reEnable() {
        guard let tap else { return }
        mouseLog.error("mouse event tap disabled; re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Hand the edge to main, where the real gesture work belongs. The consume decision already happened
    // synchronously on the tap thread — only the side effect defers.
    fileprivate nonisolated func deliver(button: Int, edge: TriggerEdge) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onEdge?(button, edge) }
        }
    }

    func stop() {
        consumed.withLock { $0 = [] }
        // Signal the tap thread to exit; it disables and disposes the tap on that same thread.
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
