import Testing
@testable import KeyScribeKit

struct PressGestureTests {
    @Test func instructionExplainsEveryPressStyle() {
        #expect(PressStyle.holdOnly.instruction == "Hold the trigger while speaking, then release it to stop.")
        #expect(PressStyle.tapToToggle.instruction == "Tap once to start, then tap again to stop.")
        #expect(PressStyle.holdOrTap.instruction == "Hold and release, or tap to start and tap again to stop.")
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
