import CoreAudio
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct DuringDictationEffectsTests {
    private let muteConfig = Settings.DuringDictation(
        muteSystemAudio: true, keepDisplayAwake: false, sounds: false)

    @Test func muteIsAppliedOnlyWhenCaptureGoesLive() {
        var mute: UInt32 = 0
        var writes: [UInt32] = []
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            outputMuteState: { _ in mute },
            setOutputMute: { value, _ in mute = value; writes.append(value); return true },
            deviceUID: { _ in "out" },
            reapplyDelays: [], muteFollowInterval: 100)

        effects.begin(muteConfig)
        #expect(writes.isEmpty)       // begin only arms — the route is not settled yet
        effects.activateMute()
        #expect(writes == [1])        // applied once capture is live
        effects.end(muteConfig)
        #expect(writes == [1, 0])
        #expect(mute == 0)
    }

    @Test func cancelBeforeCaptureGoesLiveNeverMutes() {
        var writes: [UInt32] = []
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            outputMuteState: { _ in 0 },
            setOutputMute: { value, _ in writes.append(value); return true },
            deviceUID: { _ in "out" },
            reapplyDelays: [], muteFollowInterval: 100)

        effects.begin(muteConfig)
        effects.end(muteConfig, cue: .cancel)   // cancelled while the mic was still coming up
        effects.activateMute()                   // a late capture-live signal must not mute
        #expect(writes.isEmpty)
    }

    // The Bluetooth A2DP<->HFP switch moves the audible output to a different device a beat after the mic
    // opens; the follow loop must mute whatever becomes the default, and restore every device it touched.
    @Test func muteFollowsTheOutputWhenTheRouteMovesToANewDevice() async {
        var defaultDev: AudioDeviceID = 1
        var mutes: [AudioDeviceID: UInt32] = [1: 0, 2: 0]
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { defaultDev },
            outputMuteState: { mutes[$0] },
            setOutputMute: { value, dev in mutes[dev] = value; return true },
            deviceUID: { "uid-\($0)" },
            resolveOutputDevice: { uid in UInt32(uid.replacingOccurrences(of: "uid-", with: "")) },
            reapplyDelays: [], muteFollowInterval: 0.02)

        effects.begin(muteConfig)
        effects.activateMute()                   // mutes device 1
        #expect(mutes[1] == 1)
        defaultDev = 2                           // route shifts the audible output to device 2
        for _ in 0..<200 { if mutes[2] == 1 { break }; try? await Task.sleep(for: .seconds(0.02)) }
        #expect(mutes[2] == 1)                   // follow loop muted the new default

        effects.end(muteConfig)
        #expect(mutes[1] == 0)                   // every touched device restored
        #expect(mutes[2] == 0)
    }

    // The Bluetooth HFP->A2DP switch as the mic closes can drop the restore write; the re-apply backstop
    // re-asserts the restored value by UID once the route settles.
    @Test func restoreIsReappliedAfterTheRouteDropsTheWrite() async {
        var mute: UInt32 = 0
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            outputMuteState: { _ in mute },
            setOutputMute: { value, _ in mute = value; return true },
            deviceUID: { _ in "out" },
            resolveOutputDevice: { $0 == "out" ? 42 : nil },
            reapplyDelays: [0.02], muteFollowInterval: 100)

        effects.begin(muteConfig)
        effects.activateMute()                   // mute=1
        effects.end(muteConfig)                  // immediate restore mute=0, schedules re-apply
        mute = 1                                 // route switch drops our unmute, stranding it muted

        for _ in 0..<200 {                       // poll so the assertion is not racing the scheduler
            if mute == 0 { break }
            try? await Task.sleep(for: .seconds(0.02))
        }
        #expect(mute == 0)                       // re-apply corrected the stranded mute
    }

    @Test func reapplyDoesNotClobberAFreshDictationsMute() async {
        var mute: UInt32 = 0
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            outputMuteState: { _ in mute },
            setOutputMute: { value, _ in mute = value; return true },
            deviceUID: { _ in "out" },
            resolveOutputDevice: { $0 == "out" ? 42 : nil },
            reapplyDelays: [0.05], muteFollowInterval: 100)

        effects.begin(muteConfig)
        effects.activateMute()
        effects.end(muteConfig)                  // schedules re-apply of 0
        effects.begin(muteConfig)                // a new dictation starts...
        effects.activateMute()                   // ...and mutes again (mute=1, new epoch)
        try? await Task.sleep(for: .seconds(0.12))

        #expect(mute == 1)                       // the stale re-apply must not have unmuted the new dictation
    }
}
