import CoreGraphics
import IOKit.hidsystem
import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

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

    private func namedBinding(_ key: String, style: PressStyle = .holdOnly) -> HotkeyMonitor.Binding {
        .init(triggerKey: nil, descriptor: try! KeyDescriptor(parsing: key), style: style, tapThreshold: 0.25)
    }

    private func monitor(
        _ bindings: [HotkeyMonitor.Binding], grace: TimeInterval = 0,
        schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil,
        onStart: @escaping (String?, PressStyle) -> Void = { _, _ in },
        onCommit: @escaping (String?) -> Void = { _ in },
        onCancel: @escaping (String?) -> Void = { _ in }
    ) -> HotkeyMonitor {
        let m = HotkeyMonitor(
            bindings: [], onStart: onStart, onCommit: onCommit, onCancel: onCancel,
            carbon: FakeChordRegistrar(), chordGraceSeconds: grace,
            schedule: schedule ?? { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
            })
        m.update(bindings: bindings)
        return m
    }

    private static let leftCmd = UInt64(NX_DEVICELCMDKEYMASK)
    private static let leftCtl = UInt64(NX_DEVICELCTLKEYMASK)

    private func flags(_ generic: CGEventFlags, _ device: UInt64 = 0) -> CGEventFlags {
        CGEventFlags(rawValue: generic.rawValue | device)
    }

    // Caps Lock sets `maskAlphaShift` on every flagsChanged while it is on. Comparing raw flags would make
    // every modifier-only trigger silently dead for the whole time the light is lit.
    @Test func capsLockDoesNotBreakEngagement() async {
        var starts = 0, commits = 0
        let m = monitor([namedBinding("right_option")], onStart: { _, _ in starts += 1 },
                        onCommit: { _ in commits += 1 })
        let capsLock = CGEventFlags.maskAlphaShift.rawValue

        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt) | capsLock))
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .flagsChanged, keyCode: 61, flags: CGEventFlags(rawValue: capsLock))
        await drainMain()
        #expect(commits == 1)
    }

    @Test func aLeftSidedPairEngagesAndCommitsOnStaggeredRelease() async {
        var starts = 0, commits = 0
        let m = monitor([namedBinding("left_command+left_control")], onStart: { _, _ in starts += 1 },
                        onCommit: { _ in commits += 1 })
        let both = flags([.maskCommand, .maskControl], Self.leftCmd | Self.leftCtl)

        m.handle(type: .flagsChanged, keyCode: 55, flags: flags([.maskCommand], Self.leftCmd))
        await drainMain()
        #expect(starts == 0)   // ⌘ alone is not this trigger

        m.handle(type: .flagsChanged, keyCode: 59, flags: both)
        await drainMain()
        #expect(starts == 1)

        // Staggered release: ⌃ lifts first, then ⌘. Exactly one commit, on the first drop out of the set.
        m.handle(type: .flagsChanged, keyCode: 59, flags: flags([.maskCommand], Self.leftCmd))
        await drainMain()
        #expect(commits == 1)

        m.handle(type: .flagsChanged, keyCode: 55, flags: CGEventFlags(rawValue: 0))
        await drainMain()
        #expect(commits == 1)
        #expect(starts == 1)
    }

    @Test func theOppositeSideDoesNotEngageASidedTrigger() async {
        var starts = 0
        let m = monitor([namedBinding("left_command")], onStart: { _, _ in starts += 1 })
        m.handle(type: .flagsChanged, keyCode: 54,
                 flags: flags([.maskCommand], UInt64(NX_DEVICERCMDKEYMASK)))
        await drainMain()
        #expect(starts == 0)
    }

    @Test func aForeignModifierJoiningAPairAborts() async {
        var starts = 0, cancels = 0, commits = 0
        let m = monitor([namedBinding("left_command+left_control")], onStart: { _, _ in starts += 1 },
                        onCommit: { _ in commits += 1 }, onCancel: { _ in cancels += 1 })
        let both = flags([.maskCommand, .maskControl], Self.leftCmd | Self.leftCtl)

        m.handle(type: .flagsChanged, keyCode: 59, flags: both)
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .flagsChanged, keyCode: 56,
                 flags: flags([.maskCommand, .maskControl, .maskShift], Self.leftCmd | Self.leftCtl))
        await drainMain()
        #expect(cancels == 1)
        #expect(commits == 0)
    }

    // Both a subset and its superset bound: pressing the pair must start only the pair. The grace is what
    // buys that — the subset's arm is still pending when the second modifier lands.
    @Test func aSubsetTriggerInsideTheGraceYieldsToTheLargerSet() async {
        let clock = ManualScheduler()
        var started: [String?] = []
        let m = monitor(
            [chordBinding("left_command"), chordBinding("left_command+left_control")],
            grace: 0.15, schedule: clock.schedule, onStart: { key, _ in started.append(key) })

        m.handle(type: .flagsChanged, keyCode: 55, flags: flags([.maskCommand], Self.leftCmd))
        m.handle(type: .flagsChanged, keyCode: 59,
                 flags: flags([.maskCommand, .maskControl], Self.leftCmd | Self.leftCtl))
        clock.fireAll()
        await drainMain()

        #expect(started == ["left_command+left_control"])
    }

    // A held modifier followed by a click is a modifier-click, not a dictation: without this every ⌘-click
    // in the browser would start and cancel a dictation for anyone on a `left_command` trigger.
    @Test func aMouseDownCancelsAPendingArmAndAbortsAStartedOne() async {
        let clock = ManualScheduler()
        var starts = 0, cancels = 0
        let m = monitor([namedBinding("left_command")], grace: 0.15, schedule: clock.schedule,
                        onStart: { _, _ in starts += 1 }, onCancel: { _ in cancels += 1 })
        let down = flags([.maskCommand], Self.leftCmd)

        m.handle(type: .flagsChanged, keyCode: 55, flags: down)
        m.handle(type: .leftMouseDown, keyCode: 0, flags: down)
        clock.fireAll()
        await drainMain()
        #expect(starts == 0)
        #expect(cancels == 0)

        m.handle(type: .flagsChanged, keyCode: 55, flags: CGEventFlags(rawValue: 0))
        m.handle(type: .flagsChanged, keyCode: 55, flags: down)
        clock.fireAll()
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .rightMouseDown, keyCode: 0, flags: down)
        await drainMain()
        #expect(cancels == 1)
    }

    // Scroll is not a chord: a stray trackpad or momentum scroll must never kill a dictation already
    // running. It only discards an arm that has not started anything yet.
    @Test func scrollCancelsAPendingArmButNeverAbortsAStartedOne() async {
        let clock = ManualScheduler()
        var starts = 0, cancels = 0, commits = 0
        let m = monitor([namedBinding("left_command")], grace: 0.15, schedule: clock.schedule,
                        onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
                        onCancel: { _ in cancels += 1 })
        let down = flags([.maskCommand], Self.leftCmd)

        m.handle(type: .flagsChanged, keyCode: 55, flags: down)
        m.handle(type: .scrollWheel, keyCode: 0, flags: down)
        clock.fireAll()
        await drainMain()
        #expect(starts == 0)
        #expect(cancels == 0)

        m.handle(type: .flagsChanged, keyCode: 55, flags: CGEventFlags(rawValue: 0))
        m.handle(type: .flagsChanged, keyCode: 55, flags: down)
        clock.fireAll()
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .scrollWheel, keyCode: 0, flags: down)
        await drainMain()
        #expect(cancels == 0)

        m.handle(type: .flagsChanged, keyCode: 55, flags: CGEventFlags(rawValue: 0))
        await drainMain()
        #expect(commits == 1)
    }

    // Holding both ⌘ keys must not engage a sided binding: that is the physical state in which a
    // `left_command` and a `right_command` trigger would otherwise both fire and run two dictations.
    // The opposite key is FOREIGN participation, so releasing it may not leave the left ⌘ looking freshly
    // pressed — the gesture is spent until both are up, exactly like a foreign modifier.
    @Test func theOppositeSideSpendsASidedTriggerUntilFullRelease() async {
        var starts = 0
        let m = monitor([namedBinding("left_command")], onStart: { _, _ in starts += 1 })
        let bothCmd = flags([.maskCommand], Self.leftCmd | UInt64(NX_DEVICERCMDKEYMASK))

        m.handle(type: .flagsChanged, keyCode: 54, flags: bothCmd)
        await drainMain()
        #expect(starts == 0)

        m.handle(type: .flagsChanged, keyCode: 54, flags: flags([.maskCommand], Self.leftCmd))
        await drainMain()
        #expect(starts == 0)

        m.handle(type: .flagsChanged, keyCode: 55, flags: CGEventFlags(rawValue: 0))
        m.handle(type: .flagsChanged, keyCode: 55, flags: flags([.maskCommand], Self.leftCmd))
        await drainMain()
        #expect(starts == 1)
    }

    // The mirror of the above while a dictation is already running: the opposite key joining is a different
    // gesture forming, so it aborts rather than being ignored.
    @Test func theOppositeSideJoiningMidDictationAborts() async {
        var starts = 0, commits = 0, cancels = 0
        let m = monitor([namedBinding("right_option")], onStart: { _, _ in starts += 1 },
                        onCommit: { _ in commits += 1 }, onCancel: { _ in cancels += 1 })

        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .flagsChanged, keyCode: 58,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)
                                     | UInt64(NX_DEVICELALTKEYMASK)))
        await drainMain()
        #expect(cancels == 1)
        #expect(commits == 0)
    }

    // `right_option` is a SHIPPED default (the Polish mode), and this is the one place its behavior moved:
    // the old soleness rule subtracted the key's OWN modifier from "foreign", so left ⌥ held did not stop
    // right ⌥ from arming. Exact matching is what lets left and right be two separate triggers.
    @Test func aShippedRightSideTriggerNoLongerArmsWhileTheOtherOptionIsHeld() async {
        var starts = 0
        let m = monitor([namedBinding("right_option")], onStart: { _, _ in starts += 1 })
        let bothOptions = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue
            | UInt64(NX_DEVICELALTKEYMASK) | UInt64(rightAlt))

        m.handle(type: .flagsChanged, keyCode: 58, flags: flags([.maskAlternate], UInt64(NX_DEVICELALTKEYMASK)))
        m.handle(type: .flagsChanged, keyCode: 61, flags: bothOptions)
        await drainMain()
        #expect(starts == 0)

        // …and it stays spent until BOTH are up, so the left one lifting is not a fresh right-⌥ press.
        m.handle(type: .flagsChanged, keyCode: 58,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 0)

        m.handle(type: .flagsChanged, keyCode: 61, flags: CGEventFlags(rawValue: 0))
        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 1)
    }

    // A sideless set is the opposite contract: either key satisfies it, including both at once.
    @Test func aSidelessSetEngagesFromEitherSideAndFromBoth() async {
        for device in [Self.leftCmd, UInt64(NX_DEVICERCMDKEYMASK), Self.leftCmd | UInt64(NX_DEVICERCMDKEYMASK)] {
            var starts = 0, commits = 0
            let m = monitor([namedBinding("command")], onStart: { _, _ in starts += 1 },
                            onCommit: { _ in commits += 1 })
            m.handle(type: .flagsChanged, keyCode: 55, flags: flags([.maskCommand], device))
            await drainMain()
            #expect(starts == 1)

            m.handle(type: .flagsChanged, keyCode: 55, flags: CGEventFlags(rawValue: 0))
            await drainMain()
            #expect(commits == 1)
        }
    }

    // Hyper is matched exactly, not as a superset: Fn joining it is a foreign modifier like any other.
    @Test func fnJoiningHyperAborts() async {
        var starts = 0, cancels = 0
        let m = monitor([namedBinding("hyper")], onStart: { _, _ in starts += 1 },
                        onCancel: { _ in cancels += 1 })

        m.handle(type: .flagsChanged, keyCode: 59, flags: hyperFlags)
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .flagsChanged, keyCode: 63,
                 flags: CGEventFlags(rawValue: hyperFlags.rawValue | CGEventFlags.maskSecondaryFn.rawValue))
        await drainMain()
        #expect(cancels == 1)
    }

    // A trackpad reports plenty of scrollWheel events that are not scrolling. Each of these would eat a
    // trigger pressed nearby, since cancelling the arm also suppresses it until release.
    @Test(arguments: [
        (128 as Int64, "fingers resting on the trackpad (mayBegin)"),
        (4 as Int64, "fingers lifting (ended)"),
        (8 as Int64, "gesture cancelled"),
    ])
    func aScrollPhaseTheUserIsNotDrivingIsNotAScroll(_ phase: Int64, _ what: String) {
        #expect(!HotkeyMonitor.scrollIsUserDriven(
            momentumPhase: 0, scrollPhase: phase, deltaAxis1: 0, deltaAxis2: 0), "\(what)")
    }

    @Test func aScrollTheUserIsDrivingCounts() {
        #expect(HotkeyMonitor.scrollIsUserDriven(momentumPhase: 0, scrollPhase: 1, deltaAxis1: 0, deltaAxis2: 0))
        #expect(HotkeyMonitor.scrollIsUserDriven(momentumPhase: 0, scrollPhase: 2, deltaAxis1: 0, deltaAxis2: 0))
        // A legacy wheel carries no phase at all, so its delta is the only signal.
        #expect(HotkeyMonitor.scrollIsUserDriven(momentumPhase: 0, scrollPhase: 0, deltaAxis1: -1, deltaAxis2: 0))
        #expect(!HotkeyMonitor.scrollIsUserDriven(momentumPhase: 0, scrollPhase: 0, deltaAxis1: 0, deltaAxis2: 0))
        #expect(!HotkeyMonitor.scrollIsUserDriven(momentumPhase: 1, scrollPhase: 2, deltaAxis1: 5, deltaAxis2: 0))
    }

    @Test func aScrollTheUserIsNotDrivingDoesNotCancelAPendingArm() async {
        let clock = ManualScheduler()
        var starts = 0
        let m = monitor([namedBinding("left_command")], grace: 0.15, schedule: clock.schedule,
                        onStart: { _, _ in starts += 1 })
        let down = flags([.maskCommand], Self.leftCmd)

        m.handle(type: .flagsChanged, keyCode: 55, flags: down)
        m.handle(type: .scrollWheel, keyCode: 0, flags: down, scrollIsUserDriven: false)
        clock.fireAll()
        await drainMain()
        #expect(starts == 1)
    }

    // A member pressed BESIDE a foreign modifier is spent until fully released. Otherwise the foreign
    // modifier's RELEASE leaves the set alone and reads as a fresh engage: ⇧⌘4, then lifting ⇧, would start
    // a dictation the user never asked for — and on hold-or-tap the ⌘ release latches an open mic.
    @Test func aForeignModifierPressedFirstSpendsTheTriggerUntilRelease() async {
        var starts = 0, commits = 0
        let m = monitor([namedBinding("left_command", style: .holdOrTap)],
                        onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 })
        let shift = flags([.maskShift], UInt64(NX_DEVICELSHIFTKEYMASK))
        let shiftCmd = flags([.maskShift, .maskCommand], UInt64(NX_DEVICELSHIFTKEYMASK) | Self.leftCmd)

        m.handle(type: .flagsChanged, keyCode: 56, flags: shift)
        m.handle(type: .flagsChanged, keyCode: 55, flags: shiftCmd)
        m.handle(type: .keyDown, keyCode: 21, flags: shiftCmd)          // ⇧⌘4
        await drainMain()
        #expect(starts == 0)

        m.handle(type: .flagsChanged, keyCode: 56, flags: flags([.maskCommand], Self.leftCmd))
        await drainMain()
        #expect(starts == 0)

        m.handle(type: .flagsChanged, keyCode: 55, flags: CGEventFlags(rawValue: 0))
        await drainMain()
        #expect(starts == 0)
        #expect(commits == 0)

        m.handle(type: .flagsChanged, keyCode: 55, flags: flags([.maskCommand], Self.leftCmd))
        await drainMain()
        #expect(starts == 1)
    }

    // The same shape with no key involved at all — nothing ever armed, so no abort ever ran, which is why
    // the suppression has to be set from the flags rather than from the abort path.
    @Test func aForeignModifierPressedFirstSpendsTheTriggerWithNoKeyInvolved() async {
        var starts = 0
        let m = monitor([namedBinding("left_command")], onStart: { _, _ in starts += 1 })
        let shift = flags([.maskShift], UInt64(NX_DEVICELSHIFTKEYMASK))

        m.handle(type: .flagsChanged, keyCode: 56, flags: shift)
        m.handle(type: .flagsChanged, keyCode: 55,
                 flags: flags([.maskShift, .maskCommand], UInt64(NX_DEVICELSHIFTKEYMASK) | Self.leftCmd))
        m.handle(type: .flagsChanged, keyCode: 56, flags: flags([.maskCommand], Self.leftCmd))
        await drainMain()
        #expect(starts == 0)
    }

    // Fn regresses the same way: the old path keyed on keyCode 63, so a foreign modifier's release was
    // invisible to it. The general rule has to cover Fn too.
    @Test func aForeignModifierPressedFirstSpendsAnFnTrigger() async {
        var starts = 0
        let m = monitor([namedBinding("fn")], onStart: { _, _ in starts += 1 })

        m.handle(type: .flagsChanged, keyCode: 59, flags: flags([.maskControl], Self.leftCtl))
        m.handle(type: .flagsChanged, keyCode: 63,
                 flags: flags([.maskControl, .maskSecondaryFn], Self.leftCtl))
        m.handle(type: .flagsChanged, keyCode: 59, flags: .maskSecondaryFn)
        await drainMain()
        #expect(starts == 0)
    }

    // A pair has no foreign modifier at any point, so neither release order may be suppressed — releasing
    // either member is the user letting go, and must commit exactly once.
    @Test(arguments: [[59, 55], [55, 59]])
    func aPairCommitsOnceInEitherReleaseOrder(_ order: [Int]) async {
        var starts = 0, commits = 0
        let m = monitor([namedBinding("left_command+left_control")], onStart: { _, _ in starts += 1 },
                        onCommit: { _ in commits += 1 })
        let bits: [Int: UInt64] = [55: Self.leftCmd, 59: Self.leftCtl]
        let generic: [Int: CGEventFlags] = [55: .maskCommand, 59: .maskControl]

        m.handle(type: .flagsChanged, keyCode: 55, flags: flags([.maskCommand], Self.leftCmd))
        m.handle(type: .flagsChanged, keyCode: 59,
                 flags: flags([.maskCommand, .maskControl], Self.leftCmd | Self.leftCtl))
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .flagsChanged, keyCode: Int64(order[0]),
                 flags: flags(generic[order[1]]!, bits[order[1]]!))
        m.handle(type: .flagsChanged, keyCode: Int64(order[1]), flags: CGEventFlags(rawValue: 0))
        await drainMain()
        #expect(commits == 1)
        #expect(starts == 1)
    }

    // A click can never be part of an Fn gesture — a click carries the generic modifier flags, and an
    // Fn-only set carries none of them — so clicking mid-sentence must not throw the dictation away.
    @Test func aClickDoesNotAbortAnFnDictationButStillDropsAPendingArm() async {
        let clock = ManualScheduler()
        var starts = 0, commits = 0, cancels = 0
        let m = monitor([namedBinding("fn")], grace: 0.15, schedule: clock.schedule,
                        onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
                        onCancel: { _ in cancels += 1 })

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        clock.fireAll()
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .leftMouseDown, keyCode: 0, flags: .maskSecondaryFn)
        await drainMain()
        #expect(cancels == 0)

        m.handle(type: .flagsChanged, keyCode: 63, flags: CGEventFlags(rawValue: 0))
        await drainMain()
        #expect(commits == 1)

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        m.handle(type: .leftMouseDown, keyCode: 0, flags: .maskSecondaryFn)
        clock.fireAll()
        await drainMain()
        #expect(starts == 1)
    }

    @Test func fnCombinedWithASidedModifierEngages() async {
        var starts = 0, commits = 0
        let m = monitor([namedBinding("fn+left_command")], onStart: { _, _ in starts += 1 },
                        onCommit: { _ in commits += 1 })

        m.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        await drainMain()
        #expect(starts == 0)

        m.handle(type: .flagsChanged, keyCode: 55,
                 flags: flags([.maskSecondaryFn, .maskCommand], Self.leftCmd))
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .flagsChanged, keyCode: 55, flags: .maskSecondaryFn)
        await drainMain()
        #expect(commits == 1)
    }

    @Test func rightOptionReleaseFiresEvenWhenLeftOptionStillHeld() async {
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding("right_option")])

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
        m.update(bindings: [namedBinding("right_command")])

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
        m.update(bindings: [namedBinding("right_option")])

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
        m.update(bindings: [namedBinding("right_option")])

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
        m.update(bindings: [namedBinding("right_option")])

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
        m.update(bindings: [namedBinding("right_option")])

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
        m.update(bindings: [namedBinding("fn")])

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
        m.update(bindings: [namedBinding("fn")])

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
        m.update(bindings: [namedBinding("hyper")])

        m.handle(type: .flagsChanged, keyCode: 59, flags: hyperFlags)
        await drainMain()
        #expect(starts == 1)

        m.handle(type: .keyDown, keyCode: 2, flags: hyperFlags)
        await drainMain()
        #expect(cancels == 1)
        #expect(commits == 0)
    }

    // With all four modifiers still held after an abort, every later flagsChanged still reads as engaged —
    // it must not re-arm. Suppression persists until the modifier set drops below Hyper.
    @Test func hyperDoesNotReArmWhileEngagedAfterAChordAbort() async {
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding("hyper")])

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
        m.update(bindings: [namedBinding("right_control")])

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
        m.update(bindings: [namedBinding("fn")])

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
        m.update(bindings: [namedBinding("fn")])

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
        m.update(bindings: [namedBinding("fn", style: .holdOnly)])

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
        m.update(bindings: [namedBinding("hyper")])

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
        m.update(bindings: [namedBinding("fn")])

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
        m.update(bindings: [namedBinding("right_option")])

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

@MainActor
struct HotkeyMonitorLayoutTests {
    private func binding(_ key: String) -> HotkeyMonitor.Binding {
        .init(triggerKey: key, descriptor: try! KeyDescriptor(parsing: key), style: .holdOnly, tapThreshold: 0.25)
    }

    private func monitor(_ fake: FakeChordRegistrar, layout: @escaping () -> KeyboardLayoutIndex)
        -> HotkeyMonitor {
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in }, onCommit: { _ in },
            carbon: fake, mouseTap: FakeMouseTap())
        m.layout = layout
        return m
    }

    @Test func registersAPunctuationChordAtItsLayoutPosition() {
        let fake = FakeChordRegistrar()
        let m = monitor(fake, layout: { .ansiUS })
        m.update(bindings: [binding("control+`")])
        #expect(fake.lastRegistrations.count == 1)
        #expect(fake.lastRegistrations[0].keyCode == 50)
        #expect(fake.lastRegistrations[0].modifiers == .control)
    }

    @Test func theSameChordRegistersElsewhereOnAnotherLayout() {
        let fake = FakeChordRegistrar()
        var index = KeyboardLayoutIndex.ansiUS
        let m = monitor(fake, layout: { index })
        m.update(bindings: [binding("control+`")])
        #expect(fake.lastRegistrations[0].keyCode == 50)

        index = KeyboardLayoutIndex { keyCode, modifiers in
            guard modifiers.isEmpty else { return nil }
            return keyCode == 10 ? "`" : nil
        }
        m.update(bindings: [binding("control+`")])
        #expect(fake.lastRegistrations.count == 1)
        #expect(fake.lastRegistrations[0].keyCode == 10)
    }

    @Test func aChordAbsentFromTheLayoutIsNotRegistered() {
        let fake = FakeChordRegistrar()
        let m = monitor(fake, layout: { .ansiUS })
        m.update(bindings: [binding("control+é"), binding("control+option+e")])
        #expect(fake.lastRegistrations.count == 1)
        #expect(fake.lastRegistrations[0].keyCode == 14)
    }

    @Test func aSpecialKeyChordRegistersWithoutTheLayout() {
        let fake = FakeChordRegistrar()
        let m = monitor(fake, layout: { KeyboardLayoutIndex { _, _ in nil } })
        m.update(bindings: [binding("option+space")])
        #expect(fake.lastRegistrations.count == 1)
        #expect(fake.lastRegistrations[0].keyCode == 49)
    }

    @Test func aChordStillDrivesItsGestureAfterAReregistration() async {
        let fake = FakeChordRegistrar()
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            carbon: fake, mouseTap: FakeMouseTap())
        m.layout = { .ansiUS }
        m.update(bindings: [binding("control+`")])
        m.update(bindings: [binding("control+`")])

        fake.lastRegistrations[0].onPressed()
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        #expect(starts == 1)
        fake.lastRegistrations[0].onReleased?()
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        #expect(commits == 1)
    }

    @Test func anActionShortcutAbsentFromTheLayoutIsNotRegistered() {
        let fake = FakeChordRegistrar()
        let m = monitor(fake, layout: { .ansiUS })
        m.update(bindings: [], actionBindings: [
            .init(id: "offLayout", descriptor: try! KeyDescriptor(parsing: "control+é")),
            .init(id: "onLayout", descriptor: try! KeyDescriptor(parsing: "control+option+e")),
        ])
        #expect(fake.lastRegistrations.count == 1)
        #expect(fake.lastRegistrations[0].keyCode == 14)
    }

    @Test func aLayoutChangeWhileSuspendedIsRegisteredOnResume() {
        let fake = FakeChordRegistrar()
        var index = KeyboardLayoutIndex.ansiUS
        let m = monitor(fake, layout: { index })
        m.update(bindings: [binding("control+`")])

        m.isSuspended = true
        index = KeyboardLayoutIndex { keyCode, modifiers in
            guard modifiers.isEmpty else { return nil }
            return keyCode == 10 ? "`" : nil
        }
        m.isSuspended = false

        #expect(fake.lastRegistrations.count == 1)
        #expect(fake.lastRegistrations[0].keyCode == 10)
    }
}
