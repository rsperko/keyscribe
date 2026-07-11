import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem
import KeyScribeKit
import os

private let hotkeyLog = Logger(subsystem: "com.keyscribe.app", category: "hotkey")

@MainActor
final class HotkeyMonitor {
    // A watched key. `triggerKey` is nil for the global default (→ context-based mode resolution)
    // or a canonical key descriptor string for a mode-specific key (→ that mode via Phase A).
    struct Binding {
        let triggerKey: String?
        let descriptor: KeyDescriptor
        var gesture: PressGesture
        var hyperEngaged = false

        init(triggerKey: String?, descriptor: KeyDescriptor, style: PressStyle, tapThreshold: Double) {
            self.triggerKey = triggerKey
            self.descriptor = descriptor
            self.gesture = PressGesture(style: style, tapThreshold: tapThreshold)
        }
    }

    // A global chord that fires a one-shot action (e.g. open the Add-Dictionary panel) rather than
    // driving a dictation gesture. Only chord descriptors are accepted; a modifier-only named key
    // makes no sense as a discrete action trigger.
    struct ActionBinding {
        let id: String
        let descriptor: KeyDescriptor
    }

    private var bindings: [Binding]
    private var actionBindings: [ActionBinding]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let carbon: ChordRegistering
    private let mouseTap: MouseTapping
    private let isProcessTrusted: () -> Bool

    let onStart: (String?, PressStyle) -> Void
    let onCommit: (String?) -> Void
    let onAction: (String) -> Void

    init(
        bindings: [Binding], actionBindings: [ActionBinding] = [],
        onStart: @escaping (String?, PressStyle) -> Void, onCommit: @escaping (String?) -> Void,
        onAction: @escaping (String) -> Void = { _ in },
        carbon: ChordRegistering = CarbonHotKeys(),
        mouseTap: MouseTapping = MouseEventTap(),
        isProcessTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.bindings = bindings
        self.actionBindings = actionBindings
        self.onStart = onStart
        self.onCommit = onCommit
        self.onAction = onAction
        self.carbon = carbon
        self.mouseTap = mouseTap
        self.isProcessTrusted = isProcessTrusted
        self.mouseTap.onEdge = { [weak self] button, edge in self?.fireMouse(button: button, edge: edge) }
    }

    func update(bindings: [Binding], actionBindings: [ActionBinding] = []) {
        // Carry live gesture state across a rebuild for any binding whose descriptor + press style are
        // unchanged, so a held/latched key keeps its in-progress gesture; otherwise its release edge is
        // dropped (a tap-to-toggle "stop" misread as a new "start"), stranding the recording.
        let previous = self.bindings
        self.bindings = bindings.map { incoming in
            guard let match = previous.first(where: {
                $0.descriptor == incoming.descriptor
                    && $0.gesture.style == incoming.gesture.style
                    && $0.gesture.tapThreshold == incoming.gesture.tapThreshold
            }) else { return incoming }
            var carried = incoming
            carried.gesture = match.gesture
            carried.hyperEngaged = match.hyperEngaged
            return carried
        }
        self.actionBindings = actionBindings
        rebuildCarbon()
        rebuildMouse()
    }

    func cancelGestures() {
        for i in bindings.indices {
            bindings[i].gesture.cancel()
            bindings[i].hyperEngaged = false
        }
    }

    var hasPhysicallyDownGesture: Bool {
        bindings.contains { $0.gesture.isPhysicallyDown }
    }

    // The tap watches modifier-only triggers (Fn/right-Option/right-Command/Hyper) via `.flagsChanged`; once
    // Accessibility is granted a `.listenOnly` modifier-only tap runs on Accessibility alone — KeyScribe never
    // requests Input Monitoring. Footgun: `tapCreate` *before* the grant fails AND makes tccd write a *denied*
    // ListenEvent record that then suppresses the tap permanently, even after Accessibility is later granted,
    // until ListenEvent is reset — so `start()` gates on `isProcessTrusted()` and never touches it untrusted.
    // `.listenOnly` (not `.defaultTap`): we never consume an event, and it is delivered async, so a wedged
    // main thread can never hold global input hostage. Chords → `CarbonHotKeys`; ESC-to-cancel → the HUD.
    // isTapActive false while Accessibility reads granted means a launch-cached denied verdict or a suppressing
    // ListenEvent record, both repaired by the permission relaunch — the readiness signal AppDelegate/Settings
    // surface (live `AXIsProcessTrusted` would wrongly say "Ready").
    var isTapActive: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        defer { rebuildCarbon(); rebuildMouse() }
        if tap != nil { return true }
        // Never create the tap untrusted: it fails AND can leave a denied ListenEvent record that suppresses
        // it for good (see isTapActive). The post-grant relaunch re-invokes start() with the verdict present.
        // Carbon chords register via the defer with no permission; the mouse tap self-gates on the same trust
        // check in MouseEventTap.ensureRunning.
        guard isProcessTrusted() else {
            hotkeyLog.info("modifier-key event tap deferred until Accessibility is granted")
            return false
        }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = makeTap(mask: mask, options: .listenOnly) else {
            hotkeyLog.error("modifier-key event tap not created despite Accessibility granted; a denied ListenEvent record may be suppressing it — relaunch to repair")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        activeHotkeyMonitor = self
        hotkeyLog.info("modifier-key event tap active")
        return true
    }

    private func makeTap(mask: CGEventMask, options: CGEventTapOptions) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
            eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: nil)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        carbon.stop()
        mouseTap.stop()
        activeHotkeyMonitor = nil
    }

    // macOS disables a tap (emitting one of these events) when its callback is slow or under certain
    // input conditions; it must be re-enabled or the monitor goes permanently deaf — dictation gets
    // stuck "listening" because the release edge never arrives.
    fileprivate func reEnable(reason: CGEventType) {
        guard let tap else { return }
        hotkeyLog.error("event tap disabled (type=\(reason.rawValue, privacy: .public)); re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Suspended while a HotkeyRecorder is capturing in Settings, so pressing a chord to record it can't
    // also fire an existing global shortcut or mode trigger. The tap goes quiet, and the Carbon chords
    // unregister so the recorder's local monitor sees the raw keystroke; both are restored on resume.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended { carbon.update([]) } else { rebuildCarbon() }
            rebuildMouse()
        }
    }

    // Modifier-only triggers only. Chord triggers and action chords are handled by `CarbonHotKeys`.
    // Never consumes — a bare modifier types nothing, so there is nothing to swallow.
    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        guard !isSuspended else { return }
        var now: TimeInterval = 0
        var haveNow = false
        for i in bindings.indices {
            guard case .named = bindings[i].descriptor else { continue }
            guard let edge = edge(binding: i, type: type, keyCode: keyCode, flags: flags) else { continue }
            if !haveNow { now = ProcessInfo.processInfo.systemUptime; haveNow = true }
            fire(index: i, edge: edge, now: now)
        }
    }

    private func rebuildCarbon() {
        guard !isSuspended else { carbon.update([]); return }
        var registrations: [CarbonHotKeys.Registration] = []
        for i in bindings.indices {
            guard case .chord = bindings[i].descriptor else { continue }
            registrations.append(.init(
                keyCode: bindings[i].descriptor.triggerKeyCode,
                modifiers: bindings[i].descriptor.requiredModifierMask,
                onPressed: { [weak self] in self?.carbonEdge(index: i, edge: .down) },
                onReleased: { [weak self] in self?.carbonEdge(index: i, edge: .up) }))
        }
        for action in actionBindings {
            let id = action.id
            registrations.append(.init(
                keyCode: action.descriptor.triggerKeyCode,
                modifiers: action.descriptor.requiredModifierMask,
                onPressed: { [weak self] in self?.dispatchSideEffect { self?.onAction(id) } },
                onReleased: nil))
        }
        carbon.update(registrations)
    }

    private func carbonEdge(index: Int, edge: TriggerEdge) {
        guard bindings.indices.contains(index) else { return }
        fire(index: index, edge: edge, now: ProcessInfo.processInfo.systemUptime)
    }

    // Mouse-button triggers ride a separate consuming tap (`MouseEventTap`), not the modifier tap or
    // Carbon — a mouse button is neither a `keyDown` chord nor a bare modifier. Empty set while
    // suspended so a recorder capturing a mouse button sees the raw click.
    private func rebuildMouse() {
        guard !isSuspended else { mouseTap.setConsumedButtons([]); return }
        var buttons: Set<Int> = []
        for binding in bindings {
            if case .mouseButton(let n) = binding.descriptor { buttons.insert(n) }
        }
        mouseTap.setConsumedButtons(buttons)
    }

    private func fireMouse(button: Int, edge: TriggerEdge) {
        guard let index = bindings.firstIndex(where: {
            if case .mouseButton(let n) = $0.descriptor { return n == button }
            return false
        }) else { return }
        fire(index: index, edge: edge, now: ProcessInfo.processInfo.systemUptime)
    }

    private func fire(index: Int, edge: TriggerEdge, now: TimeInterval) {
        let key = bindings[index].triggerKey
        let style = bindings[index].gesture.style
        switch bindings[index].gesture.handle(edge, at: now) {
        case .start: dispatchSideEffect { self.onStart(key, style) }
        case .commit: dispatchSideEffect { self.onCommit(key) }
        case .none: break
        }
    }

    // Run a gesture/action callback off the event-tap delivery context: `onStart`/`onCommit`/`onAction` do
    // real work (engine resolve, audio start, HUD) that inline would risk a `tapDisabledByTimeout`. Gesture
    // state already advanced synchronously; only the side-effect is deferred, FIFO so a start precedes its commit.
    private func dispatchSideEffect(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }

    private func edge(binding i: Int, type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> TriggerEdge? {
        let descriptor = bindings[i].descriptor
        switch descriptor {
        case .named(.hyper):
            let all: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
            let engaged = flags.isSuperset(of: all)
            if engaged, !bindings[i].hyperEngaged { bindings[i].hyperEngaged = true; return .down }
            if !engaged, bindings[i].hyperEngaged { bindings[i].hyperEngaged = false; return .up }
            return nil

        case .named(let named):
            guard type == .flagsChanged, keyCode == Int64(descriptor.triggerKeyCode) else { return nil }
            switch named {
            case .fn:
                return flags.contains(.maskSecondaryFn) ? .down : .up
            case .rightOption:
                return flags.rawValue & UInt64(NX_DEVICERALTKEYMASK) != 0 ? .down : .up
            case .rightCommand:
                return flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0 ? .down : .up
            case .hyper: return nil
            }

        case .chord, .mouseButton:
            return nil
        }
    }
}

nonisolated(unsafe) private weak var activeHotkeyMonitor: HotkeyMonitor?

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { activeHotkeyMonitor?.reEnable(reason: type) }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let rawFlags = event.flags.rawValue
    MainActor.assumeIsolated {
        activeHotkeyMonitor?.handle(type: type, keyCode: keyCode, flags: CGEventFlags(rawValue: rawFlags))
    }
    return Unmanaged.passUnretained(event)
}
