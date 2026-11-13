import CoreGraphics
import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

// THE CONTRACT: the HUD is the visual half of the start cue, so it may not appear one instant before the cue
// sounds — a HUD at trigger time invites speech into the time the mic is still negotiating, when nothing can
// be recorded. The mic records from its first buffer and the cue stays in the recording.
//
// The order is: hidden at the press -> first buffer -> cue -> cue ends -> recording HUD + duck.
@MainActor
struct CaptureCueOrderingTests {
    private final class TinyEngine: SpeechEngine, @unchecked Sendable {
        let id = "tiny"
        let displayName = "Tiny"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "" }
        func evict() async {}
    }

    private final class RecordingHUD: HUDPresenting {
        var states: [HUDState] = []
        var keyFocusFree: [Bool] = []
        func setKeyFocusFree(_ free: Bool) { keyFocusFree.append(free) }
        private(set) var firstVisibleAt: UInt64?
        func render(_ state: HUDState) {
            if state != .hidden, firstVisibleAt == nil { firstVisibleAt = mach_absolute_time() }
            states.append(state)
        }
        var sawVisibleHUD: Bool { states.contains { $0 != .hidden } }
        var sawRecording: Bool { states.contains { if case .recording = $0 { return true }; return false } }
        var errorMessage: String? {
            for state in states { if case .error(let message, _, _) = state { return message } }
            return nil
        }
    }

    // start() blocks until the test fires `ready`, standing in for a Bluetooth route that has bound and
    // started but not yet delivered a buffer.
    private final class GatedAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let ready: SignalLatch
        private let failWith: Error?
        private let lock = NSLock()
        private var _startCalls = 0
        private var _stops = 0
        var startCalls: Int { lock.withLock { _startCalls } }
        var stops: Int { lock.withLock { _stops } }
        private var lost: (@Sendable () -> Void)?
        func setCaptureLostHandler(_ handler: @escaping @Sendable () -> Void) { lock.withLock { lost = handler } }
        func loseCapture() { lock.withLock { lost }?() }
        var bluetooth = false
        var inputIsBluetooth: Bool { bluetooth }
        init(url: URL, ready: SignalLatch, failWith: Error? = nil) {
            self.url = url
            self.ready = ready
            self.failWith = failWith
        }

        func start(sampleRate: Int) async throws -> URL {
            lock.withLock { _startCalls += 1 }
            await ready.wait()
            if let failWith { throw failWith }
            return url
        }
        func stop() -> URL? { lock.withLock { _stops += 1 }; return url }
        func finishDraining() async -> URL? { url }
    }

    private final class StartMarkingAudio: AudioCapturing, @unchecked Sendable {
        let startBegan = DispatchSemaphore(value: 0)
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL {
            startBegan.signal()
            return url
        }
        func stop() -> URL? { url }
    }

    @Test func micBringUpIsUnderWayWhileThePressProbeRuns() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-cue-order-\(UUID().uuidString)", isDirectory: true)
        let audio = StartMarkingAudio(url: dir.appendingPathComponent("capture.wav"))
        var startedBeforeProbeFinished = false
        let controller = DictationController(
            settings: Settings.defaults,
            provider: try! SpeechEngineProvider(engines: [TinyEngine()], activeId: "tiny"),
            config: ConfigCache(supportDir: dir), history: nil, hud: RecordingHUD(), permits: { _ in true },
            audio: audio,
            effects: DuringDictationEffects(
                defaultOutputDeviceID: { nil }, setDuck: { _, _ in false }, startCueDurationOverride: 0),
            snapshot: {
                startedBeforeProbeFinished = audio.startBegan.wait(timeout: .now() + 2) == .success
                return TargetSnapshot(bundleId: "test.bundle")
            },
            micStatus: { .granted })

        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(startedBeforeProbeFinished)
        controller.cancel()
    }

    @Test func changingOtherAudioInSettingsReachesSpeechAlreadyPlaying() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-cue-order-\(UUID().uuidString)", isDirectory: true)
        var level: Float32 = 1
        var settings = Settings.defaults
        settings.duringDictation.otherAudio = .mute
        let controller = DictationController(
            settings: settings,
            provider: try! SpeechEngineProvider(engines: [TinyEngine()], activeId: "tiny"),
            config: ConfigCache(supportDir: dir), history: nil, hud: RecordingHUD(), permits: { _ in true },
            audio: StartMarkingAudio(url: dir.appendingPathComponent("capture.wav")),
            effects: DuringDictationEffects(
                defaultOutputDeviceID: { 42 }, setDuck: { value, _ in level = value; return true }, reapplyDelays: [],
                duckFollowInterval: 100, startCueDurationOverride: 0),
            micStatus: { .granted })

        controller.lowerOtherAudioForSpeech(true)
        #expect(level == 0)
        settings.duringDictation.otherAudio = .unchanged
        controller.updateSettings(settings)
        #expect(level == 1)
    }

    @Test func pressingToDictateOverSpeechKeepsOtherAudioDownUntilTheTakeEnds() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-cue-order-\(UUID().uuidString)", isDirectory: true)
        var level: Float32 = 1
        var settings = Settings.defaults
        settings.duringDictation.otherAudio = .mute
        let controller = DictationController(
            settings: settings,
            provider: try! SpeechEngineProvider(engines: [TinyEngine()], activeId: "tiny"),
            config: ConfigCache(supportDir: dir), history: nil, hud: RecordingHUD(), permits: { _ in true },
            audio: StartMarkingAudio(url: dir.appendingPathComponent("capture.wav")),
            effects: DuringDictationEffects(
                defaultOutputDeviceID: { 42 }, setDuck: { value, _ in level = value; return true }, reapplyDelays: [],
                duckFollowInterval: 100, startCueDurationOverride: 0),
            micStatus: { .granted }, silencer: SpeechSilencer())

        controller.lowerOtherAudioForSpeech(true)
        controller.handleStart()
        controller.lowerOtherAudioForSpeech(false)
        #expect(level == 0)
        controller.cancel()
        await controller.captureBringUpTask?.value
        await poll { level == 1 }
        #expect(level == 1)
    }

    @MainActor private final class Sounds { var played = 0 }

    private func makeController(
        audio: AudioCapturing, hud: HUDPresenting, cueSeconds: TimeInterval, silencer: SpeechSilencer = .shared,
        sounds: Sounds? = nil
    ) -> DictationController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-cue-order-\(UUID().uuidString)", isDirectory: true)
        let provider = try! SpeechEngineProvider(engines: [TinyEngine()], activeId: "tiny")
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { nil }, setDuck: { _, _ in false },
            startCueDurationOverride: cueSeconds, playSound: { _, _ in MainActor.assumeIsolated { sounds?.played += 1 } })
        return DictationController(
            settings: Settings.defaults, provider: provider, config: ConfigCache(supportDir: dir),
            history: nil, hud: hud, permits: { _ in true }, audio: audio, effects: effects, micStatus: { .granted },
            silencer: silencer)
    }

    private func poll(until condition: @escaping () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func noCueIsCutWhileTheMicHasNotDeliveredABuffer() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        #expect(!hud.sawRecording)
        #expect(!hud.sawVisibleHUD)
        ready.signal()
        await poll { hud.sawRecording }
    }

    @Test func thePressShowsNoVisibleHUDBeforeTheMicrophoneIsRequested() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.handleStart()
        #expect(!hud.sawVisibleHUD)
        ready.signal()
        await poll { hud.sawRecording }
        #expect(audio.startCalls == 1)
    }

    @Test func armingFailureShowsTheErrorHUDWithNoPriorVisibleHUD() async {
        let ready = SignalLatch()
        let audio = GatedAudio(
            url: URL(fileURLWithPath: "/dev/null"), ready: ready, failWith: AudioCaptureError.bringUpTimedOut)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        #expect(!hud.sawVisibleHUD)
        ready.signal()
        await poll { hud.errorMessage != nil }
        #expect(hud.states.filter { $0 != .hidden }.count == 1)
    }

    @Test func theHUDAppearsOnlyOnceTheCueThatStartsAtReadinessHasEnded() async throws {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.3)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        try? await Task.sleep(for: .milliseconds(200))
        let readyAt = mach_absolute_time()
        ready.signal()
        await poll { hud.sawRecording }
        let shown = try #require(hud.firstVisibleAt)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let cueTicks = UInt64(0.3e9 * Double(timebase.denom) / Double(timebase.numer))
        #expect(shown >= readyAt &+ cueTicks)
    }

    @Test func aTimedOutBringUpReportsTheErrorAndPlaysNoCue() async {
        let ready = SignalLatch()
        let audio = GatedAudio(
            url: URL(fileURLWithPath: "/dev/null"), ready: ready, failWith: AudioCaptureError.bringUpTimedOut)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        ready.signal()
        await poll { hud.errorMessage != nil }
        #expect(hud.errorMessage == "Could not start the microphone")
        #expect(!hud.sawRecording)
        #expect(!hud.sawRecording)
    }

    @Test func releasingDuringArmingPlaysNoCueAndTearsTheCaptureDown() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        controller.handleCommit()
        ready.signal()
        await poll { !controller.isBusy }
        #expect(!hud.sawRecording)
        #expect(!hud.sawVisibleHUD)
        #expect(audio.stops == 1)
    }

    @Test func theMicStartsAtTheKeyDownButTheCuePlaysOnlyOnceThePressStands() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.pressConfirmationBackstop = .seconds(60)
        controller.handleEngage(triggerKey: "right_option")
        await poll { audio.startCalls == 1 }
        ready.signal()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!hud.sawRecording)
        #expect(!hud.sawVisibleHUD)
        controller.handleStart(triggerKey: "right_option")
        await poll { hud.sawRecording }
        #expect(audio.startCalls == 1)
        controller.cancel()
    }

    @Test func aPressThatBecomesAChordStopsTheMicWithoutACueOrHUD() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.pressConfirmationBackstop = .seconds(60)
        controller.handleEngage(triggerKey: "right_option")
        await poll { audio.startCalls == 1 }
        ready.signal()
        controller.handleEngageDropped(triggerKey: "right_option")
        await poll { !controller.isBusy }
        #expect(!controller.isBusy)
        #expect(audio.stops == 1)
        #expect(!hud.sawRecording)
        #expect(!hud.sawVisibleHUD)
    }

    @Test func aPressNeverConfirmedStopsTheMicAfterTheBackstop() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.pressConfirmationBackstop = .milliseconds(50)
        controller.handleEngage(triggerKey: "right_option")
        await poll { audio.startCalls == 1 }
        ready.signal()
        await poll { !controller.isBusy }
        #expect(!controller.isBusy)
        #expect(audio.stops == 1)
        #expect(!hud.sawVisibleHUD)
    }

    @Test func aDroppedPressLeavesTheNextPressFreeToStart() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        ready.signal()
        controller.pressConfirmationBackstop = .seconds(60)
        controller.handleEngage(triggerKey: "right_option")
        controller.handleEngageDropped(triggerKey: "right_option")
        await poll { !controller.isBusy }
        controller.handleStart(triggerKey: "right_option")
        await poll { hud.sawRecording }
        #expect(audio.startCalls == 2)
        controller.cancel()
    }

    @Test func cancellingAnUnconfirmedPressStopsTheMicSilentlyAndFreesTheApp() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let sounds = Sounds()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05, sounds: sounds)
        controller.pressConfirmationBackstop = .seconds(60)
        controller.handleEngage(triggerKey: "right_option")
        await poll { audio.startCalls == 1 }
        ready.signal()
        try? await Task.sleep(for: .milliseconds(100))
        controller.cancel()
        await poll { !controller.isBusy }
        #expect(!controller.isBusy)
        #expect(audio.stops == 1)
        #expect(sounds.played == 0)
        #expect(!hud.sawVisibleHUD)
    }

    @Test func aLostCaptureDuringAnUnconfirmedPressStopsTheMicSilentlyAndFreesTheApp() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let sounds = Sounds()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05, sounds: sounds)
        controller.pressConfirmationBackstop = .seconds(60)
        controller.handleEngage(triggerKey: "right_option")
        await poll { audio.startCalls == 1 }
        ready.signal()
        try? await Task.sleep(for: .milliseconds(100))
        audio.loseCapture()
        await poll { !controller.isBusy }
        #expect(!controller.isBusy)
        #expect(audio.stops == 1)
        #expect(sounds.played == 0)
        #expect(!hud.sawVisibleHUD)
    }

    @Test func aStartRightAfterADroppedPressWaitsForTheTeardownThenRecords() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let sounds = Sounds()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05, sounds: sounds)
        controller.pressConfirmationBackstop = .seconds(60)
        controller.handleEngage(triggerKey: "right_option")
        await poll { audio.startCalls == 1 }
        controller.handleEngageDropped(triggerKey: "right_option")
        controller.handleStart(triggerKey: "right_option+c")
        ready.signal()
        await poll { hud.sawRecording }
        #expect(hud.sawRecording)
        #expect(audio.startCalls == 2)
        #expect(sounds.played == 0)
        controller.cancel()
    }

    @Test func aReleaseBeforeTheDeferredStartRunsCancelsIt() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.pressConfirmationBackstop = .seconds(60)
        controller.handleEngage(triggerKey: "right_option")
        await poll { audio.startCalls == 1 }
        controller.handleEngageDropped(triggerKey: "right_option")
        controller.handleStart(triggerKey: "right_option+c")
        controller.handleCommit()
        ready.signal()
        await poll { audio.startCalls == 2 && !controller.isBusy }
        #expect(!controller.isBusy)
        #expect(!hud.sawRecording)
    }

    @Test func aBluetoothInputIsNotOpenedAtTheKeyDownButStillRecordsOnceThePressStands() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        audio.bluetooth = true
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.handleEngage(triggerKey: "right_option")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(audio.startCalls == 0)
        #expect(!controller.isBusy)
        controller.handleEngageDropped(triggerKey: "right_option")
        controller.handleStart(triggerKey: "right_option")
        ready.signal()
        await poll { hud.sawRecording }
        #expect(audio.startCalls == 1)
        controller.cancel()
    }

    @MainActor private final class Replayed { var events: [CGEvent] = [] }

    private func optionC() -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
        event.flags = .maskAlternate
        return event
    }

    private func recordingController(
        _ replayed: Replayed, style: PressStyle = .holdOrTap
    ) async -> (DictationController, GatedAudio, RecordingHUD) {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.01)
        controller.replayKeys = { replayed.events += $0 }
        controller.handleStart(triggerKey: "right_option", pressStyle: style)
        ready.signal()
        await poll { hud.sawRecording }
        return (controller, audio, hud)
    }

    @Test func aKeyThePanelTookIsReplayedWhenAChordCancelsTheTake() async {
        let replayed = Replayed()
        let (controller, _, _) = await recordingController(replayed)
        controller.noteKeyReceivedByHUD(optionC())
        controller.cancelStartedByModifier(triggerKey: "right_option")
        await poll { !replayed.events.isEmpty }
        #expect(replayed.events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [8])
        #expect(replayed.events.first?.flags.contains(.maskAlternate) == true)
    }

    @Test func aKeyThePanelReceivesJustAfterTheChordCancelIsStillReplayed() async {
        let replayed = Replayed()
        let (controller, _, _) = await recordingController(replayed)
        controller.cancelStartedByModifier(triggerKey: "right_option")
        controller.noteKeyReceivedByHUD(optionC())
        await poll { !replayed.events.isEmpty }
        #expect(replayed.events.count == 1)
    }

    @Test func aDoubleTapTakeAsksTheHUDToLeaveKeyFocusWithTheApp() async {
        let replayed = Replayed()
        let (controller, _, hud) = await recordingController(replayed, style: .doubleTap)
        #expect(hud.keyFocusFree == [true])
        controller.cancel()
    }

    @Test func otherTakesLetTheHUDTakeKeyFocus() async {
        let replayed = Replayed()
        let (controller, _, hud) = await recordingController(replayed, style: .tapToToggle)
        #expect(hud.keyFocusFree == [false])
        controller.cancel()
    }

    @Test func keysAreNotReplayedWhenTheTakeEndsAnyOtherWay() async {
        let replayed = Replayed()
        let (controller, _, _) = await recordingController(replayed)
        controller.noteKeyReceivedByHUD(optionC())
        controller.cancel()
        controller.noteKeyReceivedByHUD(optionC())
        try? await Task.sleep(for: .milliseconds(300))
        #expect(replayed.events.isEmpty)
    }

    @Test func aReplayedKeyIsMarkedSoTheKeyboardMonitorIgnoresIt() {
        let event = optionC()
        #expect(!KeyReplay.isReplayed(event))
        #expect(KeyReplay.isReplayed(KeyReplay.marked(event)!))
    }

    @Test func aRepeatedArmingErrorIsStillShown() async throws {
        let hud = RecordingHUD()
        for _ in 0..<2 {
            let ready = SignalLatch()
            let audio = GatedAudio(
                url: URL(fileURLWithPath: "/dev/null"), ready: ready,
                failWith: AudioCaptureError.bringUpTimedOut)
            let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
            controller.handleStart()
            await poll { audio.startCalls == 1 }
            ready.signal()
            await poll { !controller.isBusy }
        }
        let visible = hud.states.enumerated().filter { $0.element != .hidden }.map(\.offset)
        try #require(visible.count == 2)
        #expect(hud.states[(visible[0] + 1)..<visible[1]].contains(.hidden))
    }

    private final class LoggingHUD: HUDPresenting {
        let log: (String) -> Void
        init(log: @escaping (String) -> Void) { self.log = log }
        func render(_ state: HUDState) {
            if case .recording = state { log("recording HUD") }
        }
    }

    @Test func aRecordingReleasesTheSpeakingPanelsEscapeBeforeTheRecordingHUDAppears() async {
        var events: [String] = []
        let silencer = SpeechSilencer()
        let speech = SpokenResultOutputTests.FakeSpeech()
        let connection = Connection(id: "omlx", name: "Local", provider: .openaiCompatible, model: "qwen", keyRef: "k")
        let output = SpokenResultOutput(
            client: SpokenResultOutputTests.FakeLLM(), permits: { _ in true }, speech: speech, silencer: silencer,
            settings: { SpokenResultSettings(enabled: true, connection: "omlx") }, connection: { $0 == "omlx" ? connection : nil })
        let escape = FakeChordRegistrar()
        escape.onUpdate = { events.append($0.isEmpty ? "escape released" : "escape claimed") }
        let panel = SpeakingHUDController(escape: escape, defaults: UserDefaults(suiteName: UUID().uuidString)!, displays: .unfocused)
        defer { panel.hide() }
        output.onSpeaking = { speaking in
            if let speaking { panel.show(name: speaking.name, summary: speaking.text) } else { panel.hide() }
        }
        output.finished(conversation: "pi:s1", handle: "api", answer: "Done.")
        await poll { speech.isSpeaking }
        speech.start()

        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = LoggingHUD { events.append($0) }
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05, silencer: silencer)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        ready.signal()
        await poll { events.contains("recording HUD") }
        #expect(events == ["escape claimed", "escape released", "recording HUD"])
        controller.cancel()
    }
}
