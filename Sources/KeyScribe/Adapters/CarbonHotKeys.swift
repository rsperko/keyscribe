import Carbon.HIToolbox
import Foundation
import KeyScribeKit
import os

private let carbonLog = Logger(subsystem: "com.keyscribe.app", category: "hotkey")

// A registrar for global chord hot keys; this seam lets `HotkeyMonitor` be unit-tested without the OS.
@MainActor
protocol ChordRegistering: AnyObject {
    @discardableResult
    func update(_ registrations: [CarbonHotKeys.Registration]) -> Bool
    func stop()
}

// Chord triggers (key + modifiers) register as system hot keys via `RegisterEventHotKey` — no Input
// Monitoring, no Accessibility; the OS dispatches the chord and suppresses it from the focused app.
// Modifier-only triggers stay on the Accessibility event tap (`HotkeyMonitor`).
@MainActor
final class CarbonHotKeys: ChordRegistering {
    struct Registration {
        let keyCode: Int
        let modifiers: ModifierSet
        let onPressed: () -> Void
        let onReleased: (() -> Void)?
    }

    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef?] = []
    private var byId: [UInt32: Registration] = [:]
    private let signature: OSType = 0x4B59_5343  // 'KYSC'

    @discardableResult
    func update(_ registrations: [Registration]) -> Bool {
        // unregisterAll() drops any in-flight hold: a chord held across an update loses its kEventHotKeyReleased
        // (the ref that would fire it is gone). Mainline is protected (AppDelegate defers rebuilds while busy);
        // this needs an external config edit landing in the arming window to trigger.
        unregisterAll()
        guard !registrations.isEmpty else { return true }
        installHandlerIfNeeded()
        var allRegistered = true
        for reg in registrations {
            let numericId = nextCarbonHotKeyId
            nextCarbonHotKeyId &+= 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: numericId)
            let status = RegisterEventHotKey(
                UInt32(reg.keyCode), Self.carbonMask(reg.modifiers),
                hotKeyID, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, ref != nil {
                refs.append(ref)
                byId[numericId] = reg
            } else {
                allRegistered = false
                // Only an exclusive-lock collision returns an error here; a system-reserved combo
                // (e.g. ⌘Space) registers with noErr and simply never fires, so this is a partial signal.
                carbonLog.error(
                    "RegisterEventHotKey failed (kc=\(reg.keyCode, privacy: .public) mods=\(reg.modifiers.rawValue, privacy: .public) status=\(status, privacy: .public))")
            }
        }
        return allRegistered
    }

    isolated deinit {
        stop()
    }

    func stop() {
        unregisterAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private func unregisterAll() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref) }
        refs.removeAll()
        byId.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(), carbonHotKeyHandler, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    fileprivate func dispatch(id: UInt32, kind: UInt32) -> Bool {
        guard let reg = byId[id] else { return false }
        if kind == UInt32(kEventHotKeyPressed) {
            reg.onPressed()
        } else if kind == UInt32(kEventHotKeyReleased) {
            reg.onReleased?()
        }
        return true
    }

    private static func carbonMask(_ mods: ModifierSet) -> UInt32 {
        var mask: UInt32 = 0
        if mods.contains(.command) { mask |= UInt32(cmdKey) }
        if mods.contains(.option) { mask |= UInt32(optionKey) }
        if mods.contains(.control) { mask |= UInt32(controlKey) }
        if mods.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }
}

nonisolated(unsafe) private var nextCarbonHotKeyId: UInt32 = 1

private func carbonHotKeyHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard err == noErr else { return OSStatus(eventNotHandledErr) }
    let kind = GetEventKind(event)
    let owner = Unmanaged<CarbonHotKeys>.fromOpaque(userData).takeUnretainedValue()
    let handled = MainActor.assumeIsolated { owner.dispatch(id: hotKeyID.id, kind: kind) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
