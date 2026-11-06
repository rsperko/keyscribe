import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandOutputTests {
    private final class Runner: VoiceCommandRunning {
        var onProgress: (@MainActor (VoiceCommandProgress) -> Void)?
        func run(
            transcript: String, places: [VoiceCommandPlace], scripts: [VoiceCommandScript], origin: VoiceCommandOrigin?,
            stillWanted: @escaping @MainActor () -> Bool, onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
        ) async -> VoiceCommandOutcome { .abandoned }
    }

    private final class HUDSpy: HUDPresenting {
        var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private final class Host: VoiceCommandHost {
        var isBusy = false
        var isArming = false
        var takeStarts = 0
        var answeringChoiceId: Int?
        var voiceCommandsEnabled = true
        var voiceCommandsAvailable = true
        var savedCommands = VoiceCommandConfig()
        var voiceCommandShortcut: String?
        var hides: [Double] = []
        func cancelTake() {}
        func whenIdle(_ work: @escaping () -> Void) { work() }
        func hide(after seconds: Double) { hides.append(seconds) }
        func alert(_ cue: DuringDictationEffects.EndCue) {}
    }

    private func output(_ spy: HUDSpy, host: Host) -> VoiceCommandOutput {
        let output = VoiceCommandOutput(
            runner: Runner(), hud: HUDChannel(hud: spy), reporter: TakeReporter(history: nil, replacementUsage: nil))
        output.host = host
        return output
    }

    @Test func everyStopCountsSoWorkStartedBeforeItCanTellItWasStopped() {
        let host = Host()
        let output = output(HUDSpy(), host: host)
        #expect(output.stops == 0)
        output.stop()
        output.stop()
        #expect(output.stops == 2)
    }

    @Test func aLateResultForAStartedCommandShowsWhenNothingElseIsOnScreen() {
        let spy = HUDSpy()
        let host = Host()
        let output = output(spy, host: host)
        let late = VoiceCommandOutput.LateResult()
        late.started = true
        late.outcome = .failed(message: "The script exited with 1")
        output.applyLateResult(late)
        #expect(spy.states == [.error(message: "The script exited with 1", action: nil)])
        #expect(host.hides == [4])
        output.applyLateResult(late)
        #expect(spy.states.count == 1)
    }

    @Test func aLateResultWaitsWhileATakeIsRunning() {
        let spy = HUDSpy()
        let host = Host()
        host.isBusy = true
        let output = output(spy, host: host)
        let late = VoiceCommandOutput.LateResult()
        late.started = true
        late.outcome = .failed(message: "The script exited with 1")
        output.applyLateResult(late)
        #expect(spy.states.isEmpty)
    }

    @Test func anUnrecognizedCommandShowsAShortTitleAndWhatWasHeard() throws {
        let excerpt = HeardExcerpt(heard: "zorb the thing")
        let shown = try #require(VoiceCommandOutput.presentation(
            of: .failed(message: "No command matches", kind: .unrecognizedCommand), resultPrefix: "", excerpt: excerpt))
        #expect(shown.state == .error(message: "Command not recognized", action: nil, heard: excerpt))
        #expect(shown.outcome == .commandFailed)
    }

    @Test func onlyACommandThatRanCountsItsReplacements() {
        #expect(VoiceCommandOutput.ranACommand(.command(.done(summary: "Opened Mail", command: "open mail"))))
        #expect(!VoiceCommandOutput.ranACommand(.command(.failed(message: "nope"))))
        #expect(!VoiceCommandOutput.ranACommand(.cancelled(request: "open")))
    }
}
