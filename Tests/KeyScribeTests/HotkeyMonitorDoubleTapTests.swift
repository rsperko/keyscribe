import CoreGraphics
import Foundation
import IOKit.hidsystem
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct HotkeyMonitorDoubleTapTests {
    private final class Events {
        var starts = 0, commits = 0, cancels = 0, engages = 0
        var now: TimeInterval = 100
    }

    private static let leftCmd = UInt64(NX_DEVICELCMDKEYMASK)
    private static let rightCmd = UInt64(NX_DEVICERCMDKEYMASK)
    private static let leftShift = UInt64(NX_DEVICELSHIFTKEYMASK)
    private static let none = CGEventFlags(rawValue: 0)

    private func flags(_ generic: CGEventFlags, _ device: UInt64 = 0) -> CGEventFlags {
        CGEventFlags(rawValue: generic.rawValue | device)
    }

    private func monitor(_ keys: [String], style: PressStyle = .doubleTap, events: Events) -> HotkeyMonitor {
        let m = HotkeyMonitor(
            bindings: [],
            onStart: { _, _, _ in events.starts += 1 }, onCommit: { _ in events.commits += 1 },
            onCancel: { _ in events.cancels += 1 }, onEngage: { _ in events.engages += 1 },
            carbon: FakeChordRegistrar(), mouseTap: FakeMouseTap(), chordGraceSeconds: 0.15,
            schedule: { _, _ in }, clock: { events.now })
        m.update(bindings: keys.map {
            .init(triggerKey: $0, descriptor: try! KeyDescriptor(parsing: $0), style: style, tapThreshold: 0.25)
        })
        return m
    }

    private func drainMain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    private func tapCommand(_ m: HotkeyMonitor, _ events: Events, device: UInt64 = leftCmd) {
        events.now += 0.1
        m.handle(type: .flagsChanged, keyCode: 55, flags: flags(.maskCommand, device))
        events.now += 0.08
        m.handle(type: .flagsChanged, keyCode: 55, flags: Self.none)
    }

    private func doubleTapCommand(_ m: HotkeyMonitor, _ events: Events) {
        tapCommand(m, events)
        tapCommand(m, events)
    }

    @Test func aDoubleTapStartsWithoutWarmingTheMicAndATapFinishes() async {
        let events = Events()
        let m = monitor(["left_command"], events: events)
        tapCommand(m, events)
        await drainMain()
        #expect(events.starts == 0)
        #expect(events.engages == 0)

        tapCommand(m, events)
        await drainMain()
        #expect(events.starts == 1)
        #expect(events.engages == 0)

        events.now += 1
        tapCommand(m, events)
        await drainMain()
        #expect(events.commits == 1)
    }

    @Test func aRapidThirdTapDoesNotFinishTheNewTake() async {
        let events = Events()
        let m = monitor(["left_command"], events: events)
        doubleTapCommand(m, events)
        tapCommand(m, events)
        await drainMain()
        #expect(events.starts == 1)
        #expect(events.commits == 0)
    }

    @Test func eitherCommandNeedsBothTapsOnTheSameSide() async {
        let events = Events()
        let m = monitor(["command"], events: events)
        tapCommand(m, events, device: Self.leftCmd)
        tapCommand(m, events, device: Self.rightCmd)
        await drainMain()
        #expect(events.starts == 0)

        tapCommand(m, events, device: Self.rightCmd)
        await drainMain()
        #expect(events.starts == 1)
    }

    @Test func holdingBothCommandKeysIsNotATap() async {
        let events = Events()
        let m = monitor(["command"], events: events)
        tapCommand(m, events)
        m.handle(type: .flagsChanged, keyCode: 55, flags: flags(.maskCommand, Self.leftCmd))
        m.handle(type: .flagsChanged, keyCode: 54, flags: flags(.maskCommand, Self.leftCmd | Self.rightCmd))
        m.handle(type: .flagsChanged, keyCode: 55, flags: flags(.maskCommand, Self.rightCmd))
        m.handle(type: .flagsChanged, keyCode: 54, flags: Self.none)
        await drainMain()
        #expect(events.starts == 0)
    }

    @Test(arguments: [CGEventType.keyDown, .leftMouseDown, .scrollWheel])
    func inputBetweenTapsInterruptsTheSequence(_ type: CGEventType) async {
        let events = Events()
        let m = monitor(["left_command"], events: events)
        tapCommand(m, events)
        m.handle(type: type, keyCode: 0, flags: Self.none)
        tapCommand(m, events)
        await drainMain()
        #expect(events.starts == 0)

        tapCommand(m, events)
        await drainMain()
        #expect(events.starts == 1)
    }

    @Test func anotherModifierBetweenTapsInterruptsTheSequence() async {
        let events = Events()
        let m = monitor(["left_command"], events: events)
        tapCommand(m, events)
        m.handle(type: .flagsChanged, keyCode: 56, flags: flags(.maskShift, Self.leftShift))
        m.handle(type: .flagsChanged, keyCode: 56, flags: Self.none)
        tapCommand(m, events)
        await drainMain()
        #expect(events.starts == 0)
    }

    @Test func aShortcutDuringATakeNeitherFinishesNorCancelsIt() async {
        let events = Events()
        let m = monitor(["left_command"], events: events)
        doubleTapCommand(m, events)
        events.now += 1
        m.handle(type: .flagsChanged, keyCode: 55, flags: flags(.maskCommand, Self.leftCmd))
        m.handle(type: .keyDown, keyCode: 8, flags: flags(.maskCommand, Self.leftCmd))
        m.handle(type: .flagsChanged, keyCode: 55, flags: Self.none)
        await drainMain()
        #expect(events.commits == 0)
        #expect(events.cancels == 0)

        tapCommand(m, events)
        await drainMain()
        #expect(events.commits == 1)
    }

    @Test func aModifiedClickDuringATakeNeitherFinishesNorCancelsIt() async {
        let events = Events()
        let m = monitor(["left_command"], events: events)
        doubleTapCommand(m, events)
        events.now += 1
        m.handle(type: .flagsChanged, keyCode: 55, flags: flags(.maskCommand, Self.leftCmd))
        m.handle(type: .leftMouseDown, keyCode: 0, flags: flags(.maskCommand))
        m.handle(type: .flagsChanged, keyCode: 55, flags: Self.none)
        await drainMain()
        #expect(events.commits == 0)
        #expect(events.cancels == 0)
    }

    @Test func aChordOnTheKeyDuringATakeLeavesItRecording() async {
        let events = Events()
        let m = monitor(["left_command"], events: events)
        doubleTapCommand(m, events)
        events.now += 1
        m.handle(type: .flagsChanged, keyCode: 55, flags: flags(.maskCommand, Self.leftCmd))
        m.handle(type: .flagsChanged, keyCode: 56,
                 flags: flags([.maskCommand, .maskShift], Self.leftCmd | Self.leftShift))
        m.handle(type: .flagsChanged, keyCode: 56, flags: flags(.maskCommand, Self.leftCmd))
        m.handle(type: .flagsChanged, keyCode: 55, flags: Self.none)
        await drainMain()
        #expect(events.commits == 0)
        #expect(events.cancels == 0)

        tapCommand(m, events)
        await drainMain()
        #expect(events.commits == 1)
    }

    @Test func cancellingGesturesClearsAPendingFirstTap() async {
        let events = Events()
        let m = monitor(["left_command"], events: events)
        tapCommand(m, events)
        m.cancelGestures()
        tapCommand(m, events)
        await drainMain()
        #expect(events.starts == 0)
    }

    @Test func aSlowLonePressFinishesATake() async {
        let events = Events()
        let m = monitor(["left_command"], events: events)
        doubleTapCommand(m, events)
        events.now += 1
        m.handle(type: .flagsChanged, keyCode: 55, flags: flags(.maskCommand, Self.leftCmd))
        events.now += 0.9
        m.handle(type: .flagsChanged, keyCode: 55, flags: Self.none)
        await drainMain()
        #expect(events.commits == 1)
    }

    @Test func eitherCommandFinishesFromTheOtherSide() async {
        let events = Events()
        let m = monitor(["command"], events: events)
        tapCommand(m, events, device: Self.rightCmd)
        tapCommand(m, events, device: Self.rightCmd)
        events.now += 1
        tapCommand(m, events, device: Self.leftCmd)
        await drainMain()
        #expect(events.starts == 1)
        #expect(events.commits == 1)
    }

    @Test func otherStylesStillAbortOnAChord() async {
        let events = Events()
        let m = monitor(["left_command"], style: .holdOnly, events: events)
        m.handle(type: .flagsChanged, keyCode: 55, flags: flags(.maskCommand, Self.leftCmd))
        m.handle(type: .keyDown, keyCode: 8, flags: flags(.maskCommand, Self.leftCmd))
        await drainMain()
        #expect(events.starts == 0)
        #expect(events.engages == 1)
    }
}
