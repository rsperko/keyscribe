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
}
