import CoreAudio
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct DuringDictationEffectsTests {
    private let duckConfig = Settings.DuringDictation(
        muteSystemAudio: true, keepDisplayAwake: false, sounds: false)

    @Test func duckIsAppliedOnlyWhenCaptureGoesLive() {
        var writes: [Float32] = []
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            setDuck: { value, _ in writes.append(value); return true },
            reapplyDelays: [], duckFollowInterval: 100)

        effects.begin(duckConfig)
        #expect(writes.isEmpty)   // begin only arms — the route is not settled yet
        effects.activateDuck()
        #expect(writes == [0])    // 0 = ducked to silence
        effects.end(duckConfig)
        #expect(writes == [0, 1]) // 1 = restored to full volume
    }

    // If ducking is unavailable (the private API is absent on a future macOS), every duck fails — the
    // device must not be tracked, so restore issues no unduck for a duck that never happened.
    @Test func aDuckThatFailsIsNotTrackedSoRestoreIsANoOp() {
        var writes: [Float32] = []
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            setDuck: { value, _ in writes.append(value); return false },
            reapplyDelays: [], duckFollowInterval: 100)

        effects.begin(duckConfig)
        effects.activateDuck()
        #expect(writes == [0])
        effects.end(duckConfig)
        #expect(writes == [0]) // a duck that never took (returned false) is untracked, so restore is a no-op
    }

    @Test func cancelBeforeCaptureGoesLiveNeverDucks() {
        var writes: [Float32] = []
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            setDuck: { value, _ in writes.append(value); return true },
            reapplyDelays: [], duckFollowInterval: 100)

        effects.begin(duckConfig)
        effects.end(duckConfig, cue: .cancel)  // cancelled while the mic was still coming up
        effects.activateDuck()                 // a late capture-live signal must not duck
        #expect(writes.isEmpty)
    }

    // The Bluetooth A2DP<->HFP switch moves the audible output to a different device a beat after the mic
    // opens; the follow loop must duck whatever becomes the default, and restore every device it touched.
    @Test func duckFollowsTheOutputWhenTheRouteMovesToANewDevice() async {
        var defaultDev: AudioDeviceID = 1
        var levels: [AudioDeviceID: Float32] = [:]
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { defaultDev },
            setDuck: { value, dev in levels[dev] = value; return true },
            reapplyDelays: [], duckFollowInterval: 0.02)

        effects.begin(duckConfig)
        effects.activateDuck()
        #expect(levels[1] == 0)
        defaultDev = 2  // route shifts the audible output to device 2
        for _ in 0..<200 { if levels[2] == 0 { break }; try? await Task.sleep(for: .seconds(0.02)) }
        #expect(levels[2] == 0)

        effects.end(duckConfig)
        #expect(levels[1] == 1)
        #expect(levels[2] == 1)
    }

    // The Bluetooth HFP->A2DP switch as the mic closes can drop the restore write; the re-apply backstop
    // re-asserts full volume once the route settles.
    @Test func restoreIsReappliedAfterTheRouteDropsTheWrite() async {
        var level: Float32 = 1
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            setDuck: { value, _ in level = value; return true },
            reapplyDelays: [0.02], duckFollowInterval: 100)

        effects.begin(duckConfig)
        effects.activateDuck()
        effects.end(duckConfig)  // restores immediately AND schedules the re-apply backstop
        level = 0                // simulates the route switch dropping our unduck write

        for _ in 0..<200 {
            if level == 1 { break }
            try? await Task.sleep(for: .seconds(0.02))
        }
        #expect(level == 1)
    }

    @Test func reapplyDoesNotClobberAFreshDictationsDuck() async {
        var level: Float32 = 1
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            setDuck: { value, _ in level = value; return true },
            reapplyDelays: [0.05], duckFollowInterval: 100)

        effects.begin(duckConfig)
        effects.activateDuck()
        effects.end(duckConfig)    // schedules a re-apply
        effects.begin(duckConfig)  // a new dictation starts and ducks again before the re-apply fires,
        effects.activateDuck()     // bumping the epoch — the stale re-apply must not fire against it
        try? await Task.sleep(for: .seconds(0.12))

        #expect(level == 0)
    }
}
