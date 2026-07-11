import CoreGraphics
import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribe

@MainActor
final class FakeChordRegistrar: ChordRegistering {
    var lastRegistrations: [CarbonHotKeys.Registration] = []

    func update(_ registrations: [CarbonHotKeys.Registration]) {
        lastRegistrations = registrations
    }

    func stop() { lastRegistrations = [] }
}

@MainActor
final class FakeMouseTap: MouseTapping {
    var onEdge: ((Int, TriggerEdge) -> Void)?
    var consumedButtons: Set<Int> = []
    var stopped = false

    func setConsumedButtons(_ buttons: Set<Int>) { consumedButtons = buttons }
    func stop() { stopped = true; consumedButtons = [] }
}

@MainActor
struct HotkeyMonitorChordTests {
    private func chordBinding(_ key: String, style: PressStyle = .holdOnly) -> HotkeyMonitor.Binding {
        .init(triggerKey: key, descriptor: try! KeyDescriptor(parsing: key), style: style, tapThreshold: 0.25)
    }

    private func mouseBinding(_ key: String, style: PressStyle = .holdOnly) -> HotkeyMonitor.Binding {
        .init(triggerKey: key, descriptor: try! KeyDescriptor(parsing: key), style: style, tapThreshold: 0.25)
    }

    private func drainMain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    @Test func chordPressAndReleaseDriveTheGesture() async {
        let fake = FakeChordRegistrar()
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 }, carbon: fake)
        m.update(bindings: [chordBinding("control+option+e")])
        #expect(fake.lastRegistrations.count == 1)

        fake.lastRegistrations[0].onPressed()
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        fake.lastRegistrations[0].onReleased?()
        await drainMain()
        #expect(commits == 1)
    }

    @Test func mouseBindingRegistersConsumedButton() {
        let mouse = FakeMouseTap()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in }, onCommit: { _ in },
            carbon: FakeChordRegistrar(), mouseTap: mouse)
        m.update(bindings: [mouseBinding("mouse3")])
        #expect(mouse.consumedButtons == [3])
    }

    @Test func mousePressAndReleaseDriveTheGesture() async {
        let mouse = FakeMouseTap()
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: FakeChordRegistrar(), mouseTap: mouse)
        m.update(bindings: [mouseBinding("mouse4")])

        mouse.onEdge?(4, .down)
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        mouse.onEdge?(4, .up)
        await drainMain()
        #expect(commits == 1)
    }

    @Test func cancelGesturesResetsTapToToggleState() async {
        let fake = FakeChordRegistrar()
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 }, carbon: fake)
        m.update(bindings: [chordBinding("control+option+e", style: .tapToToggle)])

        fake.lastRegistrations[0].onPressed()
        await drainMain()
        m.cancelGestures()
        fake.lastRegistrations[0].onReleased?()
        fake.lastRegistrations[0].onPressed()
        await drainMain()

        #expect(starts == 2)
        #expect(commits == 0)
    }

    @Test func heldGestureIsReportedWhilePhysicalKeyIsDown() async {
        let fake = FakeChordRegistrar()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in }, onCommit: { _ in }, carbon: fake)
        m.update(bindings: [chordBinding("control+option+e", style: .holdOnly)])

        fake.lastRegistrations[0].onPressed()
        #expect(m.hasPhysicallyDownGesture)
        fake.lastRegistrations[0].onReleased?()
        #expect(!m.hasPhysicallyDownGesture)
    }

    // W9: a rebuild (Settings toggle / config reload) mid-hold must NOT strand an in-progress gesture.
    // With an identical descriptor + style, update() carries the live gesture over, so the release edge
    // still delivers its commit. Without the carry-over the fresh PressGesture never saw the .down and
    // the .up would be dropped.
    @Test func updatePreservesInProgressGestureForIdenticalDescriptor() async {
        let fake = FakeChordRegistrar()
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 }, carbon: fake)
        m.update(bindings: [chordBinding("control+option+e")])

        fake.lastRegistrations[0].onPressed()
        await drainMain()
        #expect(starts == 1)

        m.update(bindings: [chordBinding("control+option+e")])

        fake.lastRegistrations[0].onReleased?()
        await drainMain()
        #expect(commits == 1)
    }

    // A changed descriptor gets a fresh gesture — no stale state carried onto a different key.
    @Test func updateGivesAChangedDescriptorAFreshGesture() async {
        let fake = FakeChordRegistrar()
        var commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in }, onCommit: { _ in commits += 1 }, carbon: fake)
        m.update(bindings: [chordBinding("control+option+e", style: .tapToToggle)])

        fake.lastRegistrations[0].onPressed()   // tap-to-toggle start; gesture now "recording"
        await drainMain()

        m.update(bindings: [chordBinding("control+option+r", style: .tapToToggle)])
        fake.lastRegistrations[0].onPressed()   // fresh gesture → start, not commit
        await drainMain()
        #expect(commits == 0)
    }

    private func namedBinding(_ named: NamedKey, style: PressStyle = .holdOnly) -> HotkeyMonitor.Binding {
        .init(triggerKey: nil, descriptor: .named(named), style: style, tapThreshold: 0.25)
    }

    @Test func rightOptionReleaseFiresEvenWhenLeftOptionStillHeld() async {
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: FakeChordRegistrar())
        m.update(bindings: [namedBinding(.rightOption)])

        m.handle(type: .flagsChanged, keyCode: 61, flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40))
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        m.handle(type: .flagsChanged, keyCode: 61, flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20))
        await drainMain()
        #expect(commits == 1)
    }

    @Test func rightCommandReleaseFiresEvenWhenLeftCommandStillHeld() async {
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: FakeChordRegistrar())
        m.update(bindings: [namedBinding(.rightCommand)])

        m.handle(type: .flagsChanged, keyCode: 54, flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10))
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        m.handle(type: .flagsChanged, keyCode: 54, flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08))
        await drainMain()
        #expect(commits == 1)
    }

    @Test func unboundMouseButtonEdgeIsIgnored() async {
        let mouse = FakeMouseTap()
        var starts = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in },
            carbon: FakeChordRegistrar(), mouseTap: mouse)
        m.update(bindings: [mouseBinding("mouse4")])

        mouse.onEdge?(3, .down)
        await drainMain()
        #expect(starts == 0)
    }

    @Test func suspendEmptiesMouseButtonsAndResumeRestoresThem() {
        let mouse = FakeMouseTap()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in }, onCommit: { _ in },
            carbon: FakeChordRegistrar(), mouseTap: mouse)
        m.update(bindings: [mouseBinding("mouse3")])
        #expect(mouse.consumedButtons == [3])

        m.isSuspended = true
        #expect(mouse.consumedButtons.isEmpty)

        m.isSuspended = false
        #expect(mouse.consumedButtons == [3])
    }

    @Test func suspendUnregistersChordsAndResumeRestoresThem() {
        let fake = FakeChordRegistrar()
        let m = HotkeyMonitor(bindings: [], onStart: { _, _ in }, onCommit: { _ in }, carbon: fake)
        m.update(bindings: [chordBinding("control+option+e")])
        #expect(fake.lastRegistrations.count == 1)

        m.isSuspended = true
        #expect(fake.lastRegistrations.isEmpty)

        m.isSuspended = false
        #expect(fake.lastRegistrations.count == 1)
    }

    @Test func untrustedDefersTapButStillRegistersChords() {
        let fake = FakeChordRegistrar()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in }, onCommit: { _ in },
            carbon: fake, mouseTap: FakeMouseTap(), isProcessTrusted: { false })
        m.update(bindings: [chordBinding("control+option+e")])

        #expect(m.start() == false)
        #expect(m.isTapActive == false)
        #expect(fake.lastRegistrations.count == 1)
    }

    @Test func hudHoldsKeyFocusOnlyAcrossCancellableStates() {
        #expect(HUDState.recording(mode: nil, level: 0, latchedTrigger: nil).holdsKeyFocus)
        #expect(HUDState.transcribing(mode: "m").holdsKeyFocus)
        #expect(HUDState.rewriting(
            connection: "c", mode: "m", redacted: false, contextCategories: [], offerLocalTranscript: false).holdsKeyFocus)
        #expect(HUDState.arming(mode: "m").holdsKeyFocus)
        #expect(!HUDState.ready(mode: "m").holdsKeyFocus)
        #expect(!HUDState.error(message: "x", action: nil).holdsKeyFocus)
        #expect(!HUDState.hidden.holdsKeyFocus)
    }
}
