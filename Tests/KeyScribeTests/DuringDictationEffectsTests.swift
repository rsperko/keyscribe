import AppKit
import CoreAudio
import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct DuringDictationEffectsTests {
    private let duckConfig = Settings.DuringDictation(
        otherAudio: .mute, keepDisplayAwake: false, sounds: false)
    private let quietConfig = Settings.DuringDictation(
        otherAudio: .quiet, keepDisplayAwake: false, sounds: false)
    private let unchangedConfig = Settings.DuringDictation(
        otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)

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

    @Test func quietDucksToAPartialLevelAndRestoresFullVolume() {
        var writes: [Float32] = []
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            setDuck: { value, _ in writes.append(value); return true },
            reapplyDelays: [], duckFollowInterval: 100)

        effects.begin(quietConfig)
        effects.activateDuck()
        #expect(writes == [0.25])
        effects.end(quietConfig)
        #expect(writes == [0.25, 1])
    }

    @Test func unchangedNeverTouchesTheOutput() {
        var writes: [Float32] = []
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { 42 },
            setDuck: { value, _ in writes.append(value); return true },
            reapplyDelays: [], duckFollowInterval: 100)

        effects.begin(unchangedConfig)
        effects.activateDuck()
        effects.end(unchangedConfig)
        #expect(writes.isEmpty)
    }

    @Test func quietFollowsTheOutputAtTheSameLevelWhenTheRouteMoves() async {
        var defaultDev: AudioDeviceID = 1
        var levels: [AudioDeviceID: Float32] = [:]
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { defaultDev },
            setDuck: { value, dev in levels[dev] = value; return true },
            reapplyDelays: [], duckFollowInterval: 0.02)

        effects.begin(quietConfig)
        effects.activateDuck()
        #expect(levels[1] == 0.25)
        defaultDev = 2
        for _ in 0..<200 { if levels[2] == 0.25 { break }; try? await Task.sleep(for: .seconds(0.02)) }
        #expect(levels[2] == 0.25)

        effects.end(quietConfig)
        #expect(levels[1] == 1)
        #expect(levels[2] == 1)
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

    // Every sound the app plays — the start cue, the three end cues, and the settings preview — carries the
    // configured volume. The start cue needs the injected asset: the xctest bundle has no start-cue.wav, so
    // `play` would otherwise return early on a nil sound and this path would go unmeasured.
    @Test func configuredVolumeIsAppliedToEveryDictationSound() {
        var volumes: [Float] = []
        let effects = DuringDictationEffects(
            reapplyDelays: [], duckFollowInterval: 100,
            loadStartCueSound: { NSSound(data: Self.silentWAV(seconds: 0.05)) },
            playSound: { _, volume in volumes.append(volume) })
        let config = Settings.DuringDictation(
            otherAudio: .unchanged, keepDisplayAwake: false, sounds: true, soundVolumePercent: 35)

        effects.begin(config)
        effects.alert(config, cue: .error)
        effects.end(config, cue: .success)
        effects.end(config, cue: .cancel)
        effects.end(config, cue: .error)
        effects.previewStartCue(volumePercent: 35)

        #expect(volumes.count == 6)
        #expect(volumes.allSatisfy { abs($0 - 0.1225) < 0.0001 })
    }

    // 0 and 100 are the ends users can actually reach on the slider, and the taper must hit them exactly:
    // a max that is not 1.0 quietly attenuates the shipped cue level, and a 0 that is not silent is not off.
    @Test(arguments: [(0, Float(0)), (50, 0.25), (100, 1)])
    func volumeTaperIsExactAtTheSliderEnds(percent: Int, expected: Float) {
        var volumes: [Float] = []
        let effects = DuringDictationEffects(
            reapplyDelays: [], duckFollowInterval: 100,
            playSound: { _, volume in volumes.append(volume) })

        effects.end(
            Settings.DuringDictation(
                otherAudio: .unchanged, keepDisplayAwake: false, sounds: true, soundVolumePercent: percent),
            cue: .success)

        #expect(volumes == [expected])
    }

    // Zero volume means no audible cue, so there is nothing to fence out of the take: recording must admit
    // immediately instead of paying the cue hold for silence. Same timing as sounds-off.
    @Test func aSilentCueIsSkippedSoCaptureAdmitsImmediately() {
        var played = 0
        let effects = DuringDictationEffects(
            reapplyDelays: [], duckFollowInterval: 100,
            loadStartCueSound: { NSSound(data: Self.silentWAV(seconds: 0.05)) },
            playSound: { _, _ in played += 1 })

        let hold = effects.begin(
            Settings.DuringDictation(
                otherAudio: .unchanged, keepDisplayAwake: false, sounds: true, soundVolumePercent: 0))

        #expect(hold == 0)
        #expect(played == 0)
    }

    // One percent is still audible policy-wise, so it keeps the hold — the skip is exact-zero only, never a
    // fuzzy "quiet enough" threshold that would let a real cue leak into the head of the recording.
    @Test func theQuietestAudibleVolumeStillHoldsAdmission() {
        let effects = DuringDictationEffects(
            reapplyDelays: [], duckFollowInterval: 100,
            loadStartCueSound: { NSSound(data: Self.silentWAV(seconds: 0.05)) },
            playSound: { _, _ in })

        let hold = effects.begin(
            Settings.DuringDictation(
                otherAudio: .unchanged, keepDisplayAwake: false, sounds: true, soundVolumePercent: 1))

        #expect(hold > 0)
    }

    // The start cue's length is the capture-admission hold, so `begin` must report the asset's own duration.
    @Test func beginReportsTheCueAssetDurationAsTheAdmissionHold() {
        let effects = DuringDictationEffects(
            reapplyDelays: [], duckFollowInterval: 100,
            loadStartCueSound: { NSSound(data: Self.silentWAV(seconds: 0.05)) },
            playSound: { _, _ in })

        let hold = effects.begin(
            Settings.DuringDictation(
                otherAudio: .unchanged, keepDisplayAwake: false, sounds: true, soundVolumePercent: 100))

        #expect(abs(hold - 0.05) < 0.005)
    }

    // Minimal 16-bit mono PCM WAV. NSSound rejects malformed data, so this must be a real container.
    private static func silentWAV(seconds: Double, sampleRate: Int = 44_100) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let dataBytes = frames * 2
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                          // PCM header size
        append(UInt16(1))                           // PCM
        append(UInt16(1))                           // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))              // byte rate
        append(UInt16(2))                           // block align
        append(UInt16(16))                          // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        wav.append(Data(count: dataBytes))
        return wav
    }
}
