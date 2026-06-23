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

    private static let escKeyCode: Int64 = 53

    // ESC fires cancel and is swallowed only while a dictation is cancellable; the matching key-up is
    // consumed symmetrically so the app never sees a stranded half-key. onCancel is dispatched onto the
    // main queue, so drain it (FIFO behind the side effect) before asserting it ran.
    @Test func escCancelsAndIsConsumedOnlyWhileCancellable() async {
        var cancels = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _ in }, onCommit: { _ in },
            onCancel: { cancels += 1 }, canCancel: { true })
        #expect(m.handle(type: .keyDown, keyCode: Self.escKeyCode, flags: Self.none))
        #expect(m.handle(type: .keyUp, keyCode: Self.escKeyCode, flags: Self.none))
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        #expect(cancels == 1)
    }

    @Test func escPassesThroughWhenNotCancellable() {
        var cancels = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _ in }, onCommit: { _ in },
            onCancel: { cancels += 1 }, canCancel: { false })
        #expect(!m.handle(type: .keyDown, keyCode: Self.escKeyCode, flags: Self.none))
        #expect(!m.handle(type: .keyUp, keyCode: Self.escKeyCode, flags: Self.none))
        #expect(cancels == 0)
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
