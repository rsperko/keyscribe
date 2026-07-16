import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// THE CONTRACT: if the recording HUD is visible, admission is open and the user's next word will be
// captured. The HUD is the visual half of the start cue, so it may not appear one instant before the cue
// sounds — a HUD at trigger time invites speech into the ~200-500ms the mic is still negotiating, and every
// word of it is discarded (admission stays closed so the cue itself is never recorded).
//
// The order is: hidden at the press -> first buffer -> cue -> publish the cue-end admission boundary ->
// recording HUD + duck. Nothing before that boundary may invite speech.
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
        func render(_ state: HUDState) { states.append(state) }
        // The press renders .hidden (clearing any stale HUD), so "nothing shown" is not "nothing rendered".
        var sawVisibleHUD: Bool { states.contains { $0 != .hidden } }
        var sawRecording: Bool { states.contains { if case .recording = $0 { return true }; return false } }
        var errorMessage: String? {
            for state in states { if case .error(let message, _) = state { return message } }
            return nil
        }
    }

    // start() blocks until the test fires `ready`, standing in for a Bluetooth route that has bound and
    // started but not yet delivered a buffer. Records every openAdmission boundary the controller publishes.
    private final class GatedAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let ready: SignalLatch
        private let failWith: Error?
        private let lock = NSLock()
        private var _boundaries: [UInt64] = []
        private var _startCalls = 0
        private var _stops = 0
        var boundaries: [UInt64] { lock.withLock { _boundaries } }
        var startCalls: Int { lock.withLock { _startCalls } }
        var stops: Int { lock.withLock { _stops } }
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
        func openAdmission(afterHostTime: UInt64) { lock.withLock { _boundaries.append(afterHostTime) } }
    }

    private func makeController(audio: AudioCapturing, hud: HUDPresenting, cueSeconds: TimeInterval) -> DictationController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-cue-order-\(UUID().uuidString)", isDirectory: true)
        let provider = try! SpeechEngineProvider(engines: [TinyEngine()], activeId: "tiny")
        let effects = DuringDictationEffects(
            defaultOutputDeviceID: { nil }, setDuck: { _, _ in false },
            startCueDurationOverride: cueSeconds)
        return DictationController(
            settings: Settings.defaults, provider: provider, config: ConfigCache(supportDir: dir),
            history: nil, hud: hud, audio: audio, effects: effects, micStatus: { .granted })
    }

    private func poll(until condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // The core regression: a mic that has started but delivered nothing shows the user NOTHING, and
    // publishes no cue-end boundary — never "Listening", and never a panel, over a mic that cannot yet hear.
    @Test func admissionStaysClosedWhileTheMicHasNotDeliveredABuffer() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        #expect(audio.boundaries.isEmpty)
        #expect(!hud.sawVisibleHUD)
        ready.signal()
        await poll { hud.sawRecording }
        #expect(audio.boundaries.count == 1)
    }

    // The press shows nothing. Asserted in the same main-actor turn handleStart ran on, so the capture task
    // provably has not run yet: no panel can precede the microphone, let alone the admission boundary.
    @Test func thePressShowsNoVisibleHUDBeforeTheMicrophoneIsRequested() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.handleStart()
        #expect(!hud.sawVisibleHUD)
        #expect(audio.startCalls == 0)
        ready.signal()
        await poll { hud.sawRecording }
        #expect(audio.startCalls == 1)
    }

    // A failed arm shows the error and nothing before it — the error HUD is the first thing the user sees.
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

    // The HUD must stay hidden for the WHOLE cue, not merely until readiness. The boundary is published at
    // cue start, so its arrival proves the cue is playing — and the panel may not appear until that boundary
    // is reached. A long cue makes the two instants far apart enough to tell.
    @Test func theHUDStaysHiddenThroughTheCueAndAppearsOnlyAtAdmission() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.3)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        ready.signal()
        await poll { !audio.boundaries.isEmpty }
        #expect(!hud.sawVisibleHUD)
        await poll { hud.sawRecording }
        #expect(hud.sawRecording)
    }

    // Anchoring proof: the boundary is cue-end, so a boundary still in the future once readiness lands can
    // only mean the cue started at readiness. A cue played at trigger time would already have elapsed.
    @Test func theCueEndBoundaryIsAnchoredToReadinessNotToTheTrigger() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.2)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        // Outlast a trigger-anchored cue (0.2 s + pad) so the two anchors are distinguishable.
        try? await Task.sleep(for: .milliseconds(300))
        let readyAt = mach_absolute_time()
        ready.signal()
        await poll { !audio.boundaries.isEmpty }
        #expect(audio.boundaries.first! > readyAt)
    }

    // A route that never delivers audio fails honestly. It must not open admission on the way out — a
    // half-open capture that later admits frames would record from a mic the user was told had failed.
    @Test func aTimedOutBringUpReportsTheErrorAndNeverOpensAdmission() async {
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
        #expect(audio.boundaries.isEmpty)
        #expect(!hud.sawRecording)
    }

    // Releasing the trigger while the route is still coming up leaves nothing behind: no cue-end boundary,
    // no recording state, and the capture is torn back down.
    @Test func releasingDuringArmingNeverOpensAdmissionAndTearsTheCaptureDown() async {
        let ready = SignalLatch()
        let audio = GatedAudio(url: URL(fileURLWithPath: "/dev/null"), ready: ready)
        let hud = RecordingHUD()
        let controller = makeController(audio: audio, hud: hud, cueSeconds: 0.05)
        controller.handleStart()
        await poll { audio.startCalls == 1 }
        controller.handleCommit()
        ready.signal()
        await poll { !controller.isBusy }
        #expect(audio.boundaries.isEmpty)
        #expect(!hud.sawVisibleHUD)
        #expect(audio.stops == 1)
    }

    // The scenario that opened this investigation: a mic error, then an immediate retry that fails the same
    // way. "Could not start the microphone" lingers 8s, so without the press resetting the HUD to .hidden the
    // identical second error is deduplicated by HUDController.render and the retry looks like it did nothing.
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
        // A .hidden must separate the two identical errors, or render's dedupe swallows the second.
        let visible = hud.states.enumerated().filter { $0.element != .hidden }.map(\.offset)
        try #require(visible.count == 2)
        #expect(hud.states[(visible[0] + 1)..<visible[1]].contains(.hidden))
    }
}
