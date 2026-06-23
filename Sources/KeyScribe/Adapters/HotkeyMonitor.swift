import CoreGraphics
import Foundation
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
    private var hasConsumableBindings: Bool
    private var engagedActions: Set<String> = []
    private var suppressedKeyCodes: Set<Int64> = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    let onStart: (String?) -> Void
    let onCommit: (String?) -> Void
    let onAction: (String) -> Void
    let onCancel: () -> Void
    let canCancel: () -> Bool

    init(
        bindings: [Binding], actionBindings: [ActionBinding] = [],
        onStart: @escaping (String?) -> Void, onCommit: @escaping (String?) -> Void,
        onAction: @escaping (String) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}, canCancel: @escaping () -> Bool = { false }
    ) {
        self.bindings = bindings
        self.actionBindings = actionBindings
        self.hasConsumableBindings = Self.anyChordBindings(bindings, actionBindings)
        self.onStart = onStart
        self.onCommit = onCommit
        self.onAction = onAction
        self.onCancel = onCancel
        self.canCancel = canCancel
    }

    func update(bindings: [Binding], actionBindings: [ActionBinding] = []) {
        self.bindings = bindings
        self.actionBindings = actionBindings
        hasConsumableBindings = Self.anyChordBindings(bindings, actionBindings)
        engagedActions.removeAll(keepingCapacity: true)
        suppressedKeyCodes.removeAll(keepingCapacity: true)
    }

    // Most installs bind only modifier-only named triggers (Fn/right-Option), which never consume a
    // chord. Knowing up front whether any chord/action binding exists lets the per-event `consume`
    // and `handleActions` skip their per-binding scans entirely on the common path.
    private static func anyChordBindings(_ bindings: [Binding], _ actionBindings: [ActionBinding]) -> Bool {
        if !actionBindings.isEmpty { return true }
        return bindings.contains { if case .chord = $0.descriptor { return true } else { return false } }
    }

    // An active (.defaultTap) tap so a *chord* trigger (mode or action) can be swallowed before the
    // focused app sees it — a listen-only tap can only observe, so the chord double-fires into the app
    // (e.g. ⌃⌥E reaches the app as the Option-E dead key and replaces the very selection an edit-in-place
    // mode is about to rewrite). An active tap needs Accessibility, which the app already requires to
    // insert; if it can't be created (e.g. Accessibility not yet granted) we fall back to a listen-only
    // tap — hotkeys still fire, the chord still passes through — rather than losing the hotkey entirely.
    // Only exact chord matches are consumed (see `consume`); modifier-only named keys never are.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue))
        guard let tap = makeTap(mask: mask, options: .defaultTap)
            ?? makeTap(mask: mask, options: .listenOnly) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        activeHotkeyMonitor = self
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
        suppressedKeyCodes.removeAll(keepingCapacity: true)
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
    // also fire an existing global shortcut or mode trigger. While suspended `handle` consumes nothing,
    // so the keystroke still reaches the recorder — we just don't act on it here.
    var isSuspended = false

    // Returns true when the event is a chord trigger (mode or action) that should be swallowed — the
    // active tap then discards it so the focused app never sees the keystroke. Modifier-only named
    // triggers arrive as `.flagsChanged` and are never consumed: they type nothing, and swallowing a
    // bare modifier would break it system-wide.
    @discardableResult
    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard !isSuspended else { return false }
        // ESC aborts an in-flight dictation (recording or transcribing/rewriting — not the brief
        // inserting phase, which can't be rolled back). Swallow it only while cancellable so ESC
        // reaches the focused app at all other times; suppress the matching key-up so we never strand
        // a half-consumed key. `canCancel` is checked at key-down on the main actor, so it reads the
        // live dictation state.
        if keyCode == Self.escapeKeyCode {
            if type == .keyDown, canCancel() {
                suppressedKeyCodes.insert(keyCode)
                dispatchSideEffect { self.onCancel() }
                return true
            }
            if type == .keyUp { return suppressedKeyCodes.remove(keyCode) != nil }
            return false
        }
        let mods = Self.activeModifiers(flags)
        let consumed = consume(type: type, keyCode: keyCode, mods: mods)
        var now: TimeInterval = 0
        var haveNow = false
        for i in bindings.indices {
            guard let edge = edge(binding: i, type: type, keyCode: keyCode, flags: flags, mods: mods) else { continue }
            if !haveNow { now = ProcessInfo.processInfo.systemUptime; haveNow = true }
            let key = bindings[i].triggerKey
            switch bindings[i].gesture.handle(edge, at: now) {
            case .start: dispatchSideEffect { self.onStart(key) }
            case .commit: dispatchSideEffect { self.onCommit(key) }
            case .none: break
            }
        }
        handleActions(type: type, keyCode: keyCode, mods: mods)
        return consumed
    }

    // Run a gesture/action callback off the event-tap callback. An active (.defaultTap) tap holds the
    // event until the callback returns, and `onStart`/`onCommit`/`onAction` do real work (engine resolve,
    // audio start, SwiftUI HUD) — keeping that on the callback would stall input and risk a
    // `tapDisabledByTimeout`. Gesture *state* already advanced synchronously above; only the side-effect
    // is deferred, FIFO on the main queue so a start always runs before its commit.
    private func dispatchSideEffect(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }

    // Swallow only an exact chord match (mode trigger or action chord). On a matching key-down we record
    // the base keyCode and consume it; we consume the matching key-up only when we consumed its key-down,
    // so later typing the chord's base key *alone* (no modifiers) passes through untouched on both edges —
    // never a half-swallowed key-up that would strand the app in a stuck-key state.
    private func consume(type: CGEventType, keyCode: Int64, mods: ModifierSet) -> Bool {
        switch type {
        case .keyDown:
            guard hasConsumableBindings else { return false }
            let matches = bindings.contains { $0.descriptor.matchesChord(keyCode: Int(keyCode), activeModifierMask: mods) }
                || actionBindings.contains { $0.descriptor.matchesChord(keyCode: Int(keyCode), activeModifierMask: mods) }
            if matches { suppressedKeyCodes.insert(keyCode) }
            return matches
        case .keyUp:
            return suppressedKeyCodes.remove(keyCode) != nil
        default:
            return false
        }
    }

    // One-shot chord actions. keyDown auto-repeats while a key is held, so an `engaged` set debounces
    // to a single fire per physical press; the key's keyUp clears it so the next press fires again.
    private func handleActions(type: CGEventType, keyCode: Int64, mods: ModifierSet) {
        guard !actionBindings.isEmpty else { return }
        for action in actionBindings {
            let matches = action.descriptor.matchesChord(keyCode: Int(keyCode), activeModifierMask: mods)
            if type == .keyDown, matches {
                if engagedActions.insert(action.id).inserted {
                    let id = action.id
                    dispatchSideEffect { self.onAction(id) }
                }
            } else if type == .keyUp, keyCode == Int64(action.descriptor.triggerKeyCode) {
                engagedActions.remove(action.id)
            }
        }
    }

    private func edge(binding i: Int, type: CGEventType, keyCode: Int64, flags: CGEventFlags, mods: ModifierSet) -> TriggerEdge? {
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
            let bit: CGEventFlags
            switch named {
            case .fn: bit = .maskSecondaryFn
            case .rightOption: bit = .maskAlternate
            case .rightCommand: bit = .maskCommand
            case .hyper: return nil
            }
            return flags.contains(bit) ? .down : .up

        case .chord:
            guard keyCode == Int64(descriptor.triggerKeyCode) else { return nil }
            if type == .keyUp { return .up }
            if type == .keyDown,
               descriptor.matchesChord(keyCode: Int(keyCode), activeModifierMask: mods) {
                return .down
            }
            return nil
        }
    }

    private static let escapeKeyCode: Int64 = 53

    private static func activeModifiers(_ flags: CGEventFlags) -> ModifierSet {
        var mods: ModifierSet = []
        if flags.contains(.maskControl) { mods.insert(.control) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskShift) { mods.insert(.shift) }
        if flags.contains(.maskCommand) { mods.insert(.command) }
        return mods
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
    let consumed = MainActor.assumeIsolated {
        activeHotkeyMonitor?.handle(type: type, keyCode: keyCode, flags: CGEventFlags(rawValue: rawFlags)) ?? false
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
