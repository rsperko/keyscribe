import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct PressResolverTests {
    private func mode(_ id: String, key: String? = nil) -> Mode {
        var mode = Mode(id: id, name: id.capitalized)
        if let key { mode.triggerKeys = [Mode.TriggerKey(key: key)] }
        return mode
    }

    private var direct: Mode {
        var mode = Mode.direct
        mode.triggerKeys = [Mode.TriggerKey(key: "fn")]
        return mode
    }

    @Test func aOneShotPickOutranksThePressedKeyAndIsUsedUp() throws {
        let notes = mode("notes")
        let press = PressResolver.phaseA(
            modes: [direct, notes], context: RoutingContext(bundleId: "app"), triggerKey: "fn", overrideId: "notes")
        let choice = try #require(press.choice)
        #expect(choice.mode.id == "notes")
        #expect(choice.reason == .oneShot)
        #expect(choice.shortcutCandidates.isEmpty)
        #expect(press.consumesOverride)
    }

    @Test func theVoiceCommandsShortcutLeavesAOneShotForTheNextDictation() throws {
        var commands = Mode.voiceCommands
        commands.triggerKeys = [Mode.TriggerKey(key: "f5")]
        let press = PressResolver.phaseA(
            modes: [direct, commands, mode("notes")], context: RoutingContext(bundleId: "app"), triggerKey: "f5",
            overrideId: "notes")
        #expect(try #require(press.choice).mode.id == Mode.voiceCommandsId)
        #expect(!press.consumesOverride)
    }

    @Test func aPressedKeyNamesItselfOnTheChoice() throws {
        let press = PressResolver.phaseA(
            modes: [direct], context: RoutingContext(bundleId: "app"), triggerKey: "fn", overrideId: nil)
        let choice = try #require(press.choice)
        #expect(choice.reason == .triggerKey)
        #expect(choice.triggerDisplay != nil)
    }

    @Test func aSnapshotOfTheSameProcessIsAdoptedAndKeepsAnEarlierPasswordField() throws {
        let full = TargetSnapshot(bundleId: "app", pid: 7, focusedWindowId: "w1", isSecureField: false)
        let adopted = try #require(PressResolver.adoption(of: full, capturedBundle: "app", capturedPid: 7, capturedSecure: true))
        #expect(adopted.isSecureField)
        #expect(adopted.focusedWindowId == "w1")
    }

    @Test(arguments: [
        TargetSnapshot(bundleId: "other", pid: 7),
        TargetSnapshot(bundleId: "app", pid: 8),
    ])
    func aSnapshotOfAnotherTargetIsNotAdopted(full: TargetSnapshot) {
        #expect(PressResolver.adoption(of: full, capturedBundle: "app", capturedPid: 7, capturedSecure: false) == nil)
    }

    @Test @MainActor func noModeUsingTheURLOrTitleMeansNoProbe() async {
        let probed = await PressResolver.probeContext(candidates: [mode("notes")], captured: TargetSnapshot(bundleId: "app", pid: 7))
        #expect(probed.url == nil)
        #expect(probed.windowTitle == nil)
    }
}
