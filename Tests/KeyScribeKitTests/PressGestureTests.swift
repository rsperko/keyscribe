import Testing
@testable import KeyScribeKit

struct PressGestureTests {
    @Test func instructionExplainsEveryPressStyle() {
        #expect(PressStyle.holdOnly.title == "Hold to talk")
        #expect(PressStyle.tapToToggle.title == "Tap to toggle")
        #expect(PressStyle.holdOrTap.title == "Hold to talk; tap to toggle")
        #expect(PressStyle.holdOnly.instruction == "Hold the trigger while speaking, then release it to stop.")
        #expect(PressStyle.tapToToggle.instruction == "Tap once to start, then tap again to stop.")
        #expect(PressStyle.holdOrTap.instruction == "Hold and release, or tap to start and tap again to stop.")
    }
    @Test func startAndStopStylesExplainThemselves() {
        #expect(PressStyle(rawValue: "start") == .startOnly)
        #expect(PressStyle(rawValue: "stop") == .stopOnly)
        #expect(PressStyle.startOnly.title == "Start only")
        #expect(PressStyle.stopOnly.title == "Stop only")
        #expect(PressStyle.startOnly.instruction == "Press to start; does nothing while a dictation is in progress.")
        #expect(PressStyle.stopOnly.instruction == "Press to stop; does nothing when no dictation is recording.")
    }

    @Test func startOnlyAsksToStartOnEveryPressAndNeverToStop() {
        var g = PressGesture(style: .startOnly, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .start)
        #expect(g.handle(.up, at: 0.05) == .none)
        #expect(g.handle(.down, at: 1.0) == .start)
        #expect(g.handle(.up, at: 3.0) == .none)
    }

    @Test func stopOnlyAsksToStopOnEveryPressAndNeverToStart() {
        var g = PressGesture(style: .stopOnly, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .commit)
        #expect(g.handle(.up, at: 0.05) == .none)
        #expect(g.handle(.down, at: 1.0) == .commit)
        #expect(g.handle(.up, at: 3.0) == .none)
    }

    @Test func startAndStopStylesIgnoreAutoRepeatDowns() {
        var start = PressGesture(style: .startOnly, tapThreshold: 0.3)
        #expect(start.handle(.down, at: 0.0) == .start)
        #expect(start.handle(.down, at: 0.1) == .none)
        var stop = PressGesture(style: .stopOnly, tapThreshold: 0.3)
        #expect(stop.handle(.down, at: 0.0) == .commit)
        #expect(stop.handle(.down, at: 0.1) == .none)
    }

    @Test func holdOnlyStartsOnDownCommitsOnUp() {
        var g = PressGesture(style: .holdOnly, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .start)
        #expect(g.handle(.up, at: 1.0) == .commit)
    }

    @Test func tapToToggleAlternatesOnEachDown() {
        var g = PressGesture(style: .tapToToggle, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .start)
        #expect(g.handle(.up, at: 0.05) == .none)
        #expect(g.handle(.down, at: 1.0) == .commit)
        #expect(g.handle(.up, at: 1.05) == .none)
        #expect(g.handle(.down, at: 2.0) == .start)
    }

    @Test func holdOrTapHoldCommitsOnRelease() {
        var g = PressGesture(style: .holdOrTap, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .start)
        #expect(g.handle(.up, at: 0.9) == .commit)
    }

    @Test func holdOrTapTreatsAutoRepeatDownsAsContinuedHoldNotNewTaps() {
        var g = PressGesture(style: .holdOrTap, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .start)
        #expect(g.handle(.down, at: 2.95) == .none)
        #expect(g.handle(.up, at: 3.0) == .commit)
    }

    @Test func holdOnlyIgnoresAutoRepeatDowns() {
        var g = PressGesture(style: .holdOnly, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .start)
        #expect(g.handle(.down, at: 0.1) == .none)
        #expect(g.handle(.up, at: 1.0) == .commit)
    }

    @Test func tapToToggleIgnoresAutoRepeatDowns() {
        var g = PressGesture(style: .tapToToggle, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .start)
        #expect(g.handle(.down, at: 0.1) == .none)
        #expect(g.handle(.up, at: 1.0) == .none)
        #expect(g.handle(.down, at: 2.0) == .commit)
    }

    @Test func holdOrTapQuickTapLatchesThenNextTapCommits() {
        var g = PressGesture(style: .holdOrTap, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .start)
        #expect(g.handle(.up, at: 0.1) == .none)
        #expect(g.handle(.up, at: 0.1) == .none)
        #expect(g.handle(.down, at: 3.0) == .commit)
    }

    @Test func holdOrTapResetsAfterHoldCommit() {
        var g = PressGesture(style: .holdOrTap, tapThreshold: 0.3)
        _ = g.handle(.down, at: 0.0)
        #expect(g.handle(.up, at: 1.0) == .commit)
        #expect(g.handle(.down, at: 2.0) == .start)
        #expect(g.handle(.up, at: 3.0) == .commit)
    }

    @Test func spuriousUpWhileIdleIsIgnored() {
        var g = PressGesture(style: .holdOrTap, tapThreshold: 0.3)
        #expect(g.handle(.up, at: 0.0) == .none)
    }

    @Test func cancelResetsToIdle() {
        var g = PressGesture(style: .holdOrTap, tapThreshold: 0.3)
        _ = g.handle(.down, at: 0.0)
        g.cancel()
        #expect(g.handle(.down, at: 1.0) == .start)
    }

    @Test func doubleTapExplainsItself() {
        #expect(PressStyle(rawValue: "double-tap") == .doubleTap)
        #expect(PressStyle.doubleTap.title == "Double-tap to start")
        #expect(PressStyle.doubleTap.instruction == "Tap twice to start, then once to stop. Escape cancels.")
    }

    @Test func everyStyleSaysHowToStartAroundTheKey() {
        #expect(PressStyle.holdOrTap.invocation == .init(lead: "Hold", trail: "and speak"))
        #expect(PressStyle.holdOnly.invocation == .init(lead: "Hold", trail: "and speak"))
        #expect(PressStyle.tapToToggle.invocation == .init(lead: "Tap", trail: "and speak, then tap it again to stop"))
        #expect(PressStyle.doubleTap.invocation == .init(lead: "Double-tap", trail: "and speak, then tap it again to stop"))
        #expect(PressStyle.startOnly.invocation == .init(lead: "Press", trail: "and speak"))
        #expect(PressStyle.stopOnly.invocation == .init(lead: "Press", trail: "to stop"))
        #expect(PressStyle.doubleTap.invocation.sentence(key: "Right-⌘")
            == "Double-tap Right-⌘ and speak, then tap it again to stop")
    }

    @Test func doubleTapSupportsOnlyASingleModifierKey() throws {
        for key in ["fn", "right_command", "left_command", "command", "control", "option", "left_shift"] {
            #expect(PressStyle.doubleTap.supports(try KeyDescriptor(parsing: key)), "\(key)")
        }
        for key in ["hyper", "left_command+left_control", "option+command+k", "mouse4"] {
            #expect(!PressStyle.doubleTap.supports(try KeyDescriptor(parsing: key)), "\(key)")
        }
        #expect(PressStyle.holdOrTap.supports(try KeyDescriptor(parsing: "option+command+k")))
    }

    private func doubleTap() -> PressGesture {
        PressGesture(style: .doubleTap, tapThreshold: 0.25)
    }

    private func tap(_ g: inout PressGesture, at t: Double, length: Double = 0.08) -> DictationCommand {
        let down = g.handle(.down, at: t)
        #expect(down == .none)
        return g.handle(.up, at: t + length)
    }

    @Test func doubleTapStartsOnTheSecondReleaseAndATapFinishes() {
        var g = doubleTap()
        #expect(tap(&g, at: 0.0) == .none)
        #expect(tap(&g, at: 0.2) == .start)
        #expect(tap(&g, at: 3.0) == .commit)
    }

    @Test func doubleTapIgnoresALoneTap() {
        var g = doubleTap()
        #expect(tap(&g, at: 0.0) == .none)
        #expect(tap(&g, at: 5.0) == .none)
    }

    @Test func doubleTapNeverStartsFromAHold() {
        var g = doubleTap()
        #expect(tap(&g, at: 0.0, length: 1.0) == .none)
        #expect(tap(&g, at: 1.2) == .none)
        #expect(tap(&g, at: 1.4) == .start)
    }

    @Test func doubleTapIgnoresAHeldSecondPress() {
        var g = doubleTap()
        #expect(tap(&g, at: 0.0) == .none)
        #expect(tap(&g, at: 0.2, length: 1.0) == .none)
        #expect(tap(&g, at: 1.4) == .none)
    }

    @Test func doubleTapIgnoresASlowPair() {
        var g = doubleTap()
        #expect(tap(&g, at: 0.0) == .none)
        #expect(tap(&g, at: 0.6) == .none)
        #expect(tap(&g, at: 0.8) == .start)
    }

    @Test func doubleTapIgnoresAutoRepeatDowns() {
        var g = doubleTap()
        #expect(tap(&g, at: 0.0) == .none)
        #expect(g.handle(.down, at: 0.2) == .none)
        #expect(g.handle(.down, at: 0.25) == .none)
        #expect(g.handle(.up, at: 0.3) == .start)
    }

    @Test func anInterruptionBetweenTapsResetsTheSequence() {
        var g = doubleTap()
        #expect(tap(&g, at: 0.0) == .none)
        g.interrupt()
        #expect(tap(&g, at: 0.2) == .none)
        #expect(tap(&g, at: 0.4) == .start)
    }

    @Test func anInterruptedSecondPressDoesNotStart() {
        var g = doubleTap()
        #expect(tap(&g, at: 0.0) == .none)
        _ = g.handle(.down, at: 0.2)
        g.interrupt()
        #expect(g.handle(.up, at: 0.25) == .none)
        #expect(tap(&g, at: 0.4) == .none)
    }

    @Test func aShortcutDuringATakeNeitherFinishesNorEndsIt() {
        var g = doubleTap()
        _ = tap(&g, at: 0.0)
        #expect(tap(&g, at: 0.2) == .start)
        _ = g.handle(.down, at: 2.0)
        g.interrupt()
        #expect(g.handle(.up, at: 2.1) == .none)
        #expect(tap(&g, at: 3.0) == .commit)
    }

    @Test func anyLonePressDuringATakeFinishesIt() {
        var g = doubleTap()
        _ = tap(&g, at: 0.0)
        #expect(tap(&g, at: 0.2) == .start)
        #expect(tap(&g, at: 2.0, length: 1.0) == .commit)
    }

    @Test func aRapidThirdTapDoesNotFinishTheNewTake() {
        var g = doubleTap()
        _ = tap(&g, at: 0.0)
        #expect(tap(&g, at: 0.2) == .start)
        #expect(tap(&g, at: 0.4) == .none)
        #expect(tap(&g, at: 2.0) == .commit)
    }

    @Test func cancelClearsAPendingFirstTap() {
        var g = doubleTap()
        _ = tap(&g, at: 0.0)
        g.cancel()
        #expect(tap(&g, at: 0.2) == .none)
        #expect(tap(&g, at: 0.4) == .start)
    }

    @Test func otherStylesIgnoreInterrupt() {
        var g = PressGesture(style: .holdOnly, tapThreshold: 0.3)
        #expect(g.handle(.down, at: 0.0) == .start)
        g.interrupt()
        #expect(g.handle(.up, at: 1.0) == .commit)
    }
}
