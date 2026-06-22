import AppKit
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

    private var bindings: [Binding]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    let onStart: (String?) -> Void
    let onCommit: (String?) -> Void

    init(bindings: [Binding], onStart: @escaping (String?) -> Void, onCommit: @escaping (String?) -> Void) {
        self.bindings = bindings
        self.onStart = onStart
        self.onCommit = onCommit
    }

    func update(bindings: [Binding]) { self.bindings = bindings }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: hotkeyTapCallback, userInfo: nil
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        activeHotkeyMonitor = self
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
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

    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        let now = ProcessInfo.processInfo.systemUptime
        for i in bindings.indices {
            guard let edge = edge(binding: i, type: type, keyCode: keyCode, flags: flags) else { continue }
            switch bindings[i].gesture.handle(edge, at: now) {
            case .start: onStart(bindings[i].triggerKey)
            case .commit: onCommit(bindings[i].triggerKey)
            case .none: break
            }
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
               descriptor.matchesChord(keyCode: Int(keyCode), activeModifiers: Self.activeModifiers(flags)) {
                return .down
            }
            return nil
        }
    }

    private static func activeModifiers(_ flags: CGEventFlags) -> Set<Modifier> {
        var mods: Set<Modifier> = []
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
    MainActor.assumeIsolated {
        activeHotkeyMonitor?.handle(type: type, keyCode: keyCode, flags: CGEventFlags(rawValue: rawFlags))
    }
    return Unmanaged.passUnretained(event)
}
