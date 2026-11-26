import CoreGraphics
import Foundation
import IOKit.hidsystem
import KeyScribeKit
import os
import Testing
@testable import KeyScribeApp

@MainActor
final class TapClock {
    var now: TimeInterval = 0
}

@MainActor
@Suite(.serialized)
struct HotkeyTapThreadTests {
    private static let base: TimeInterval = 1_000
    nonisolated private static let rightOption = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK)
    nonisolated private static let fn = CGEventFlags.maskSecondaryFn.rawValue

    private enum Step {
        case down(TimeInterval), up(TimeInterval), key(TimeInterval), click(TimeInterval)

        var at: TimeInterval {
            switch self {
            case .down(let t), .up(let t), .key(let t), .click(let t): t
            }
        }
    }

    private func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64((seconds * 1_000_000_000).rounded()) }

    private func event(_ step: Step, held: UInt64) -> (CGEventType, CGEvent) {
        let type: CGEventType
        let event: CGEvent
        switch step {
        case .down, .up:
            type = .flagsChanged
            event = CGEvent(source: nil)!
            event.type = .flagsChanged
            if case .down = step { event.flags = CGEventFlags(rawValue: held) } else { event.flags = [] }
        case .key:
            type = .keyDown
            event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            event.flags = CGEventFlags(rawValue: held)
        case .click:
            type = .leftMouseDown
            event = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
            event.flags = CGEventFlags(rawValue: held)
        }
        event.timestamp = nanoseconds(Self.base + step.at)
        return (type, event)
    }

    private func drain(until done: () -> Bool = { false }) async {
        for _ in 0..<50 where !done() {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
    }

    private func blockMain(until done: DispatchSemaphore) -> Bool {
        done.wait(timeout: .now() + 2) == .success
    }

    private func monitor(
        _ key: String, style: PressStyle, clock: TapClock, record: @escaping @MainActor (String) -> Void,
        pressed: @escaping @MainActor (DispatchTime) -> Void = { _ in }, mouseTap: MouseTapping = FakeMouseTap(),
        grace: TimeInterval = 0.15,
        schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil
    ) throws -> HotkeyMonitor {
        let binding = HotkeyMonitor.Binding(
            triggerKey: key, descriptor: try KeyDescriptor(parsing: key), style: style, tapThreshold: 0.25)
        let m = HotkeyMonitor(
            bindings: [],
            onStart: { _, _, at in record("start"); pressed(at) },
            onCommit: { _ in record("commit") },
            onCancel: { _ in record("cancel") },
            carbon: FakeChordRegistrar(), mouseTap: mouseTap, chordGraceSeconds: grace,
            schedule: schedule ?? { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
            },
            clock: { clock.now })
        m.update(bindings: [binding])
        return m
    }

    private func mouseEvent(_ step: Step, button: Int64) -> (CGEventType, CGEvent) {
        let type: CGEventType = if case .down = step { .otherMouseDown } else { .otherMouseUp }
        let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        event.timestamp = nanoseconds(Self.base + step.at)
        return (type, event)
    }

    private func deliverStalled(_ steps: [Step], held: UInt64, to m: HotkeyMonitor, clock: TapClock) -> Bool {
        let events = steps.map { event($0, held: held) }
        nonisolated(unsafe) let sent = events
        let taken = DispatchSemaphore(value: 0)
        Thread {
            for (type, event) in sent { m.received(type: type, event: event) }
            taken.signal()
        }.start()
        let free = blockMain(until: taken)
        clock.now = Self.base + (steps.last?.at ?? 0) + 0.3
        return free
    }

    private struct Cell {
        let name: String
        var key = "right_option"
        var held = HotkeyTapThreadTests.rightOption
        let steps: [Step]
        let expected: [PressStyle: [String]]
    }

    private static let cells: [Cell] = [
        Cell(name: "hold", steps: [.down(0), .up(1.0)], expected: [
            .holdOnly: ["start", "commit"], .holdOrTap: ["start", "commit"], .tapToToggle: ["start"], .doubleTap: [],
        ]),
        Cell(name: "tap inside the grace", steps: [.down(0), .up(0.1)], expected: [
            .holdOnly: ["start", "commit"], .holdOrTap: ["start"], .tapToToggle: ["start"], .doubleTap: [],
        ]),
        Cell(name: "chord key inside the grace", steps: [.down(0), .key(0.05), .up(0.2)], expected: [
            .holdOnly: [], .holdOrTap: [], .tapToToggle: [], .doubleTap: [],
        ]),
        Cell(name: "chord key after the grace", steps: [.down(0), .key(0.4), .up(0.6)], expected: [
            .holdOnly: ["start", "cancel"], .holdOrTap: ["start", "cancel"], .tapToToggle: ["start", "cancel"],
            .doubleTap: [],
        ]),
        Cell(name: "two quick taps", steps: [.down(0), .up(0.1), .down(0.3), .up(0.4)], expected: [
            .holdOnly: ["start", "commit", "start", "commit"], .holdOrTap: ["start", "commit"],
            .tapToToggle: ["start", "commit"], .doubleTap: ["start"],
        ]),
        Cell(name: "two taps a second apart", steps: [.down(0), .up(0.1), .down(1.1), .up(1.2)], expected: [
            .holdOnly: ["start", "commit", "start", "commit"], .holdOrTap: ["start", "commit"],
            .tapToToggle: ["start", "commit"], .doubleTap: [],
        ]),
        Cell(name: "click inside the grace", steps: [.down(0), .click(0.05), .up(0.2)], expected: [
            .holdOnly: [], .holdOrTap: [], .tapToToggle: [], .doubleTap: [],
        ]),
        Cell(name: "click after the grace", steps: [.down(0), .click(0.4), .up(0.6)], expected: [
            .holdOnly: ["start", "cancel"], .holdOrTap: ["start", "cancel"], .tapToToggle: ["start", "cancel"],
            .doubleTap: [],
        ]),
        Cell(name: "fn, click inside the grace", key: "fn", held: HotkeyTapThreadTests.fn,
             steps: [.down(0), .click(0.05), .up(0.2)], expected: [
            .holdOnly: [], .holdOrTap: [], .tapToToggle: [], .doubleTap: [],
        ]),
        Cell(name: "fn, click after the grace", key: "fn", held: HotkeyTapThreadTests.fn,
             steps: [.down(0), .click(0.4), .up(0.6)], expected: [
            .holdOnly: ["start", "commit"], .holdOrTap: ["start", "commit"], .tapToToggle: ["start"], .doubleTap: [],
        ]),
    ]

    private static let mouseCells: [Cell] = [
        Cell(name: "hold", steps: [.down(0), .up(1.0)], expected: [
            .holdOnly: ["start", "commit"], .holdOrTap: ["start", "commit"], .tapToToggle: ["start"],
        ]),
        Cell(name: "tap", steps: [.down(0), .up(0.1)], expected: [
            .holdOnly: ["start", "commit"], .holdOrTap: ["start"], .tapToToggle: ["start"],
        ]),
        Cell(name: "two taps a second apart", steps: [.down(0), .up(0.1), .down(1.1), .up(1.2)], expected: [
            .holdOnly: ["start", "commit", "start", "commit"], .holdOrTap: ["start", "commit"],
            .tapToToggle: ["start", "commit"],
        ]),
    ]

    @Test func everyPressReadsTheSameWhetherMainKeptUpOrWasBlocked() async throws {
        for cell in Self.cells {
            for (style, expected) in cell.expected {
                for stalled in [false, true] {
                    let clock = TapClock()
                    var edges: [String] = []
                    let m = try monitor(cell.key, style: style, clock: clock, record: { edges.append($0) })
                    if stalled {
                        #expect(deliverStalled(cell.steps, held: cell.held, to: m, clock: clock))
                    } else {
                        for step in cell.steps {
                            clock.now = Self.base + step.at
                            let (type, event) = event(step, held: cell.held)
                            m.received(type: type, event: event)
                            await drain()
                        }
                    }
                    await drain { edges == expected }
                    #expect(edges == expected, "\(cell.name), \(style), \(stalled ? "main blocked" : "main live")")
                }
            }
        }
    }

    @Test func everyMouseButtonPressReadsTheSameWhetherMainKeptUpOrWasBlocked() async throws {
        for cell in Self.mouseCells {
            for (style, expected) in cell.expected {
                for stalled in [false, true] {
                    let clock = TapClock()
                    var edges: [String] = []
                    let tap = MouseEventTap(isProcessTrusted: { false })
                    let m = try monitor("mouse3", style: style, clock: clock, record: { edges.append($0) }, mouseTap: tap)
                    let events = cell.steps.map { mouseEvent($0, button: 3) }
                    if stalled {
                        nonisolated(unsafe) let sent = events
                        let taken = DispatchSemaphore(value: 0)
                        Thread {
                            for (type, event) in sent { _ = tap.received(type: type, event: event) }
                            taken.signal()
                        }.start()
                        #expect(blockMain(until: taken))
                        clock.now = Self.base + (cell.steps.last?.at ?? 0) + 0.3
                    } else {
                        for (step, (type, event)) in zip(cell.steps, events) {
                            clock.now = Self.base + step.at
                            #expect(tap.received(type: type, event: event))
                            await drain()
                        }
                    }
                    await drain { edges == expected }
                    #expect(edges == expected, "mouse \(cell.name), \(style), \(stalled ? "main blocked" : "main live")")
                    _ = m
                }
            }
        }
    }

    @Test func aStartDeliveredLateKeepsItsPhysicalTimeForTheAgentInputCheck() async throws {
        let cases: [(PressStyle, [Step], startsAt: TimeInterval)] = [
            (.holdOnly, [.down(0), .click(0.3)], 0),
            (.doubleTap, [.down(0), .up(0.1), .down(0.2), .up(0.3), .click(0.5)], 0.3),
        ]
        for (style, steps, startsAt) in cases {
            let offset = Double(UserInput.latest) / 1_000_000_000 + 1_000 - Self.base
            let steps = steps.map { step -> Step in
                switch step {
                case .down(let t): .down(offset + t)
                case .up(let t): .up(offset + t)
                case .key(let t): .key(offset + t)
                case .click(let t): .click(offset + t)
                }
            }
            let clickAt = nanoseconds(Self.base + steps.last!.at)
            let clock = TapClock()
            var edges: [String] = []
            var pressedAt: DispatchTime?
            var noted: [UInt64] = []
            UserInput.onInput = { noted.append($0) }
            defer { UserInput.onInput = nil }
            let m = try monitor(
                "fn", style: style, clock: clock, record: { edges.append($0) }, pressed: { pressedAt = $0 })

            #expect(deliverStalled(steps, held: Self.fn, to: m, clock: clock))
            #expect(UserInput.latest == clickAt)
            #expect(noted.isEmpty)
            await drain { pressedAt != nil && noted.contains(clickAt) }

            #expect(edges == ["start"], "\(style)")
            #expect(pressedAt?.uptimeNanoseconds == nanoseconds(Self.base + offset + startsAt), "\(style)")
            #expect(noted.last == clickAt, "\(style)")
            #expect(UserInput.latest > pressedAt?.uptimeNanoseconds ?? .max, "\(style)")
        }
    }
}

struct EventTapThreadTests {
    @Test func aDisableNoticeNeverReachesTheHandler() {
        let handled = OSAllocatedUnfairLock<[CGEventType]>(initialState: [])
        let thread = EventTapThread(name: "test") { type, _ in
            handled.withLock { $0.append(type) }
            return nil
        }
        let event = CGEvent(source: nil)!
        let proxy = OpaquePointer(bitPattern: 1)!
        let disabled = eventTapThreadCallback(proxy: proxy, type: .tapDisabledByTimeout, event: event, userInfo: thread.userInfo)
        let delivered = eventTapThreadCallback(proxy: proxy, type: .otherMouseDown, event: event, userInfo: thread.userInfo)
        #expect(disabled != nil)
        #expect(delivered == nil)
        #expect(handled.withLock { $0 } == [CGEventType.otherMouseDown])
    }
}
