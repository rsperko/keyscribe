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

    @Test func aShippedRightSideTriggerNoLongerArmsWhileTheOtherOptionIsHeld() async {
        var starts = 0
        let m = monitor([namedBinding("right_option")], onStart: { _, _ in starts += 1 })
        let bothOptions = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue
            | UInt64(NX_DEVICELALTKEYMASK) | UInt64(rightAlt))

        m.handle(type: .flagsChanged, keyCode: 58, flags: flags([.maskAlternate], UInt64(NX_DEVICELALTKEYMASK)))
        m.handle(type: .flagsChanged, keyCode: 61, flags: bothOptions)
        await drainMain()
        #expect(starts == 0)

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

        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 1)

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

    @Test func rightOptionDoesNotReArmWhileHeldAfterAChordAbort() async {
        var starts = 0, commits = 0, cancels = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _, _ in starts += 1 }, onCommit: { _ in commits += 1 },
            onCancel: { _ in cancels += 1 }, carbon: FakeChordRegistrar(), chordGraceSeconds: 0)
        m.update(bindings: [namedBinding("right_option")])

        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 1)

        let joined = CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt) | CGEventFlags.maskControl.rawValue
        m.handle(type: .flagsChanged, keyCode: 59, flags: CGEventFlags(rawValue: joined))
        await drainMain()
        #expect(cancels == 1)

        m.handle(type: .flagsChanged, keyCode: 59,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        m.handle(type: .flagsChanged, keyCode: 61, flags: CGEventFlags(rawValue: 0))
        await drainMain()
        m.handle(type: .flagsChanged, keyCode: 61,
                 flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(rightAlt)))
        await drainMain()
        #expect(starts == 2)
    }

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

        m.handle(type: .flagsChanged, keyCode: 56, flags: hyperFlags)
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

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

    @Test func hudHoldsKeyFocusOnlyAcrossVisibleCancellableStates() {
        #expect(HUDState.recording(mode: nil, level: 0, latchedTrigger: nil).holdsKeyFocus)
        #expect(HUDState.transcribing(mode: "m").holdsKeyFocus)
        #expect(HUDState.rewriting(
            connection: "c", mode: "m", redacted: false, contextCategories: [], offerLocalTranscript: false).holdsKeyFocus)
        #expect(!HUDState.ready(mode: "m").holdsKeyFocus)
        #expect(!HUDState.error(message: "x", action: nil).holdsKeyFocus)
        #expect(!HUDState.hidden.holdsKeyFocus)
    }

    @Test func aPendingArmSurvivesARebuildThatShiftsItsIndex() async {
        let clock = ManualScheduler()
        var started: [String?] = []
        let m = monitor([chordBinding("fn"), chordBinding("left_command")],
                        grace: 0.15, schedule: clock.schedule, onStart: { key, _ in started.append(key) })

        m.handle(type: .flagsChanged, keyCode: 55, flags: flags([.maskCommand], Self.leftCmd))
        m.update(bindings: [chordBinding("left_command")])
        clock.fireAll()
        await drainMain()

        #expect(started == ["left_command"])
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
