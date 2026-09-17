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

    @Test func prewarmLoadsTheStartCueOnceWithoutPlayingAnything() {
        var loads = 0
        var played = 0
        let effects = DuringDictationEffects(
            reapplyDelays: [], duckFollowInterval: 100,
            loadStartCueSound: { loads += 1; return NSSound(data: Self.silentWAV(seconds: 0.05)) },
            playSound: { _, _ in played += 1 })

        effects.prewarm()
        #expect(loads == 1)
        #expect(played == 0)

        let hold = effects.begin(
            Settings.DuringDictation(
                otherAudio: .unchanged, keepDisplayAwake: false, sounds: true, soundVolumePercent: 100))
        #expect(loads == 1)
        #expect(played == 1)
        #expect(hold > 0)
    }

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

    static func silentWAV(seconds: Double, sampleRate: Int = 44_100) -> Data {
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
