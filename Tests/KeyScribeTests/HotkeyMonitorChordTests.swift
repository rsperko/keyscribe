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

// Runs the chord grace on demand instead of on a real timer, so a grace test never sleeps.
@MainActor
final class ManualScheduler {
    private var pending: [@MainActor () -> Void] = []

    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void {
        { [weak self] _, work in self?.pending.append(work) }
    }

    func fireAll() {
        let due = pending
        pending = []
        for work in due { work() }
    }
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

    // A rebuild (Settings toggle / config reload) mid-hold must NOT strand an in-progress gesture. With
    // an identical descriptor + style, update() carries the live gesture over, so the release edge still
    // delivers its commit. Without the carry-over the fresh PressGesture never saw the .down and the .up
    // would be dropped.
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
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
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
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.rightCommand)])

        m.handle(type: .flagsChanged, keyCode: 54, flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10))
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        m.handle(type: .flagsChanged, keyCode: 54, flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08))
        await drainMain()
        #expect(commits == 1)
    }

    // "Chord wins": right-side modifier triggers must not drive dictation when a chord that includes
    // them is being formed — the case that made the old overlap warning fire (right-⌥ + a Hyper chord).
    private let rightAlt = 0x40, rightCtrl = 0x2000

    @Test func rightOptionSuppressedWhenAChordModifierIsAlreadyHeld() async {
        var starts = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in },
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.rightOption)])

        // ⌃ held, then the right Option engages (e.g. building ⌃⌥⇧⌘D with the right Option) → not a bare hold.
        let flags = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)
        m.handle(type: .flagsChanged, keyCode: 61, flags: CGEventFlags(rawValue: flags))
        await drainMain()
        #expect(starts == 0)
    }

    @Test func rightOptionAbortsWhenAChordModifierJoinsAfterABareDown() async {
        var starts = 0, commits = 0, cancels = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            onCancel: { _ in cancels += 1 }, carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.rightOption)])

        // Bare right Option first → dictation starts.
        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 1)

        // ⌃ joins while the right Option is still held → it was a chord, not a hold → abort, no commit.
        let joined = CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt) | CGEventFlags.maskControl.rawValue
        m.handle(type: .flagsChanged, keyCode: 59, flags: CGEventFlags(rawValue: joined))
        await drainMain()
        #expect(cancels == 1)
        #expect(commits == 0)
    }

    @Test func rightOptionAbortsWhenAChordKeyFollows() async {
        var starts = 0, commits = 0, cancels = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            onCancel: { _ in cancels += 1 }, carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.rightOption)])

        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        m.handle(type: .keyDown, keyCode: 2,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()

        #expect(starts == 1)
        #expect(cancels == 1)
        #expect(commits == 0)
    }

    // After a chord abort, releasing the chord drops its modifiers one at a time, so the trigger key is
    // transiently SOLE again while still physically down. It must NOT re-arm a fresh dictation (which would
    // tap-latch and strand the mic recording); suppression persists until the key is fully released.
    @Test func rightOptionDoesNotReArmWhileHeldAfterAChordAbort() async {
        var starts = 0, commits = 0, cancels = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            onCancel: { _ in cancels += 1 }, carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.rightOption)])

        // Bare right Option → start.
        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 1)

        // ⌃ joins while right Option is held → chord → abort.
        let joined = CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt) | CGEventFlags.maskControl.rawValue
        m.handle(type: .flagsChanged, keyCode: 59, flags: CGEventFlags(rawValue: joined))
        await drainMain()
        #expect(cancels == 1)

        // ⌃ lifts first → right Option is momentarily sole again but still down. No re-arm, no latch.
        m.handle(type: .flagsChanged, keyCode: 59,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        // Right Option fully released → suppression lifts; a subsequent genuine bare press arms again.
        m.handle(type: .flagsChanged, keyCode: 61, flags: CGEventFlags(rawValue: 0))
        await drainMain()
        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 2)
    }

    // "Chord wins" for Fn: fn+delete / fn+arrow are the user's own key mappings, not a dictation hold. The
    // keystroke must reach the focused app, so the just-started dictation is discarded and the Fn release
    // commits nothing (without this the HUD takes key focus mid-chord and swallows the keystroke).
    @Test func fnAbortsWhenAChordKeyFollows() async {
        var starts = 0, commits = 0, cancels = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            onCancel: { _ in cancels += 1 }, carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.fn)])

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .keyDown, keyCode: 117, flags: .maskSecondaryFn)   // forward delete
        await drainMain()
        #expect(cancels == 1)

        m.handle(type: .flagsChanged, keyCode: 63, flags: CGEventFlags(rawValue: 0))
        await drainMain()
        #expect(commits == 0)
    }

    @Test func fnReArmsAfterAChordAbortOnceReleased() async {
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.fn)])

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        m.handle(type: .keyDown, keyCode: 117, flags: .maskSecondaryFn)
        m.handle(type: .flagsChanged, keyCode: 63, flags: CGEventFlags(rawValue: 0))
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        await drainMain()
        #expect(starts == 2)
    }

    private let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    @Test func hyperAbortsWhenAChordKeyFollows() async {
        var starts = 0, commits = 0, cancels = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            onCancel: { _ in cancels += 1 }, carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.hyper)])

        m.handle(type: .flagsChanged, keyCode: 59, flags: hyperFlags)
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .keyDown, keyCode: 2, flags: hyperFlags)
        await drainMain()
        #expect(cancels == 1)
        #expect(commits == 0)
    }

    // Hyper's abort clears `hyperEngaged`, so with all four modifiers still held the NEXT flagsChanged is
    // once again a fresh "engaged" transition — it must not re-arm. Suppression persists until the modifier
    // set drops below Hyper.
    @Test func hyperDoesNotReArmWhileEngagedAfterAChordAbort() async {
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.hyper)])

        m.handle(type: .flagsChanged, keyCode: 59, flags: hyperFlags)
        m.handle(type: .keyDown, keyCode: 2, flags: hyperFlags)
        await drainMain()
        #expect(starts == 1)

        // Still every modifier held (e.g. a second chord key goes down) → no fresh arm, no stray commit.
        m.handle(type: .flagsChanged, keyCode: 56, flags: hyperFlags)
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        // Modifiers fully released → suppression lifts; a genuine Hyper hold arms again.
        m.handle(type: .flagsChanged, keyCode: 59, flags: CGEventFlags(rawValue: 0))
        await drainMain()
        m.handle(type: .flagsChanged, keyCode: 59, flags: hyperFlags)
        await drainMain()
        #expect(starts == 2)
    }

    @Test func rightControlStartsAndCommitsAsABareModifier() async {
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding(.rightControl)])

        m.handle(type: .flagsChanged, keyCode: 62,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | UInt64(rightCtrl)))
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        m.handle(type: .flagsChanged, keyCode: 62, flags: CGEventFlags(rawValue: 0))
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

    // --- Chord grace. Arming eagerly makes every chord built on a modifier-only trigger start a dictation
    // and then cancel it — audibly, since the start cue plays as soon as a prewarmed mic is ready and the
    // cancel cue follows. Holding the .down for the grace lets the chord's key land first, so nothing starts
    // at all: no onStart, and therefore no onCancel either.

    @Test func aChordKeyInsideTheGraceStartsNothingAtAll() async {
        var starts = 0, commits = 0, cancels = 0
        let clock = ManualScheduler()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            onCancel: { _ in cancels += 1 }, carbon: FakeChordRegistrar(),
            chordGraceSeconds: 0.15, schedule: clock.schedule)
        m.update(bindings: [namedBinding(.fn)])

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        m.handle(type: .keyDown, keyCode: 117, flags: .maskSecondaryFn)
        clock.fireAll()
        m.handle(type: .flagsChanged, keyCode: 63, flags: CGEventFlags(rawValue: 0))
        await drainMain()

        #expect(starts == 0)
        #expect(cancels == 0)
        #expect(commits == 0)
    }

    @Test func aHeldTriggerArmsOnceTheGraceElapses() async {
        var starts = 0
        let clock = ManualScheduler()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in },
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0.15, schedule: clock.schedule)
        m.update(bindings: [namedBinding(.fn)])

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        await drainMain()
        #expect(starts == 0)

        clock.fireAll()
        await drainMain()
        #expect(starts == 1)
    }

    // A tap shorter than the grace is a real tap, not a chord: the held-back .down must still fire on release
    // so the gesture sees a down/up pair. Dropping it would swallow every fast tap.
    @Test func aTapReleasedInsideTheGraceStillDrivesTheGesture() async {
        var starts = 0, commits = 0
        let clock = ManualScheduler()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0.15, schedule: clock.schedule)
        m.update(bindings: [namedBinding(.fn, style: .holdOnly)])

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        m.handle(type: .flagsChanged, keyCode: 63, flags: CGEventFlags(rawValue: 0))
        clock.fireAll()
        await drainMain()

        #expect(starts == 1)
        #expect(commits == 1)
    }

    @Test func aHyperChordKeyInsideTheGraceStartsNothingAtAll() async {
        var starts = 0, cancels = 0
        let clock = ManualScheduler()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in },
            onCancel: { _ in cancels += 1 }, carbon: FakeChordRegistrar(),
            chordGraceSeconds: 0.15, schedule: clock.schedule)
        m.update(bindings: [namedBinding(.hyper)])

        m.handle(type: .flagsChanged, keyCode: 59, flags: hyperFlags)
        m.handle(type: .keyDown, keyCode: 2, flags: hyperFlags)
        clock.fireAll()
        await drainMain()
        #expect(starts == 0)
        #expect(cancels == 0)

        // A second key in the same chord press must not arm either, and releasing Hyper re-enables the trigger.
        m.handle(type: .keyDown, keyCode: 3, flags: hyperFlags)
        clock.fireAll()
        await drainMain()
        #expect(starts == 0)

        m.handle(type: .flagsChanged, keyCode: 59, flags: CGEventFlags(rawValue: 0))
        m.handle(type: .flagsChanged, keyCode: 59, flags: hyperFlags)
        clock.fireAll()
        await drainMain()
        #expect(starts == 1)
    }

    // The idle resync (AppDelegate.onBecameIdle) calls cancelGestures() whenever nothing is held. A press
    // still inside its grace IS held, so it must report as such or the resync silently eats it.
    @Test func aPressInsideTheGraceCountsAsHeld() async {
        var starts = 0
        let clock = ManualScheduler()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in },
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0.15, schedule: clock.schedule)
        m.update(bindings: [namedBinding(.fn)])

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        #expect(m.hasPhysicallyDownGesture)

        clock.fireAll()
        await drainMain()
        #expect(starts == 1)
        #expect(m.hasPhysicallyDownGesture)
    }

    // The right-side keys reach the same silent outcome by the other route: a foreign modifier joining inside
    // the grace is resolved by flags, not by a keyDown.
    @Test func aForeignModifierInsideTheGraceStartsNothingAtAll() async {
        var starts = 0, cancels = 0
        let clock = ManualScheduler()
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in },
            onCancel: { _ in cancels += 1 }, carbon: FakeChordRegistrar(),
            chordGraceSeconds: 0.15, schedule: clock.schedule)
        m.update(bindings: [namedBinding(.rightOption)])

        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        let joined = CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt) | CGEventFlags.maskControl.rawValue
        m.handle(type: .flagsChanged, keyCode: 59, flags: CGEventFlags(rawValue: joined))
        clock.fireAll()
        await drainMain()

        #expect(starts == 0)
        #expect(cancels == 0)
    }

    // Only the VISIBLE cancellable states: arming is cancellable but shows no HUD, so there is no panel to
    // take key focus — ESC does not reach an arming dictation and the trigger cancels it instead.
    @Test func hudHoldsKeyFocusOnlyAcrossVisibleCancellableStates() {
        #expect(HUDState.recording(mode: nil, level: 0, latchedTrigger: nil).holdsKeyFocus)
        #expect(HUDState.transcribing(mode: "m").holdsKeyFocus)
        #expect(HUDState.rewriting(
            connection: "c", mode: "m", redacted: false, contextCategories: [], offerLocalTranscript: false).holdsKeyFocus)
        #expect(!HUDState.ready(mode: "m").holdsKeyFocus)
        #expect(!HUDState.error(message: "x", action: nil).holdsKeyFocus)
        #expect(!HUDState.hidden.holdsKeyFocus)
    }
}
