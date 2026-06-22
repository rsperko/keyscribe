import CoreGraphics
import KeyScribeKit
import Testing
@testable import KeyScribe

@MainActor
struct HotkeyMonitorSuppressionTests {
    private static let dKeyCode: Int64 = 2
    private static let aKeyCode: Int64 = 0
    private static let none = CGEventFlags(rawValue: 0)
    private static let chordFlags = CGEventFlags([.maskControl, .maskAlternate, .maskShift])

    private func chordMonitor() -> HotkeyMonitor {
        let desc = try! KeyDescriptor(parsing: "control+option+shift+d")
        return HotkeyMonitor(
            bindings: [.init(triggerKey: "control+option+shift+d", descriptor: desc,
                             style: .holdOrTap, tapThreshold: 0.25)],
            onStart: { _ in }, onCommit: { _ in })
    }

    @Test func consumesMatchingChordDownThenUp() {
        let m = chordMonitor()
        #expect(m.handle(type: .keyDown, keyCode: Self.dKeyCode, flags: Self.chordFlags))
        #expect(m.handle(type: .keyUp, keyCode: Self.dKeyCode, flags: Self.none))
    }

    // The chord's base key typed alone (no modifiers) must pass through on BOTH edges — never a
    // consumed key-up without its key-down, which would strand the app in a stuck-key state.
    @Test func passesBaseKeyTypedWithoutModifiers() {
        let m = chordMonitor()
        #expect(!m.handle(type: .keyDown, keyCode: Self.dKeyCode, flags: Self.none))
        #expect(!m.handle(type: .keyUp, keyCode: Self.dKeyCode, flags: Self.none))
    }

    @Test func passesUnrelatedKey() {
        let m = chordMonitor()
        #expect(!m.handle(type: .keyDown, keyCode: Self.aKeyCode, flags: Self.chordFlags))
        #expect(!m.handle(type: .keyUp, keyCode: Self.aKeyCode, flags: Self.none))
    }

    // Modifier-only named triggers (Fn/right-Option/…) arrive as flagsChanged and must never be
    // swallowed — they type nothing, and consuming a bare modifier would break it system-wide.
    @Test func neverConsumesModifierFlagsChanged() {
        let desc = try! KeyDescriptor(parsing: "fn")
        let m = HotkeyMonitor(
            bindings: [.init(triggerKey: "fn", descriptor: desc, style: .holdOnly, tapThreshold: 0.25)],
            onStart: { _ in }, onCommit: { _ in })
        #expect(!m.handle(type: .flagsChanged, keyCode: 63, flags: [.maskSecondaryFn]))
        #expect(!m.handle(type: .flagsChanged, keyCode: 63, flags: Self.none))
    }

    @Test func suspendedConsumesNothing() {
        let m = chordMonitor()
        m.isSuspended = true
        #expect(!m.handle(type: .keyDown, keyCode: Self.dKeyCode, flags: Self.chordFlags))
        #expect(!m.handle(type: .keyUp, keyCode: Self.dKeyCode, flags: Self.none))
    }

    @Test func consumesActionChord() {
        let desc = try! KeyDescriptor(parsing: "control+option+shift+d")
        let m = HotkeyMonitor(
            bindings: [], actionBindings: [.init(id: "x", descriptor: desc)],
            onStart: { _ in }, onCommit: { _ in })
        #expect(m.handle(type: .keyDown, keyCode: Self.dKeyCode, flags: Self.chordFlags))
        #expect(m.handle(type: .keyUp, keyCode: Self.dKeyCode, flags: Self.none))
    }
}
