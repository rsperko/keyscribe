import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Idle mic warm-up rides the Eviction tier: Fastest/Balanced prewarm the input unit, Frugal never
// touches it. The fake records prewarm/refreshBinding calls, so no real microphone is needed.
@MainActor
struct CaptureWarmthTierTests {
    private final class TinyEngine: SpeechEngine, @unchecked Sendable {
        let id = "tiny"
        let displayName = "Tiny"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "" }
        func evict() async {}
    }

    private final class RecordingAudio: AudioCapturing, @unchecked Sendable {
        private let lock = NSLock()
        private var _prewarms = 0
        private var _refreshes = 0
        private var _releases = 0
        var prewarms: Int { lock.withLock { _prewarms } }
        var refreshes: Int { lock.withLock { _refreshes } }
        var releases: Int { lock.withLock { _releases } }
        func start(sampleRate: Int) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
        func stop() -> URL? { nil }
        func prewarm() { lock.withLock { _prewarms += 1 } }
        func refreshBinding() { lock.withLock { _refreshes += 1 } }
        func releaseWarm() { lock.withLock { _releases += 1 } }
        func setPreferredInputUID(_ uid: String?) {}
    }

    private func makeController(
        eviction: Eviction, idleSeconds: Int? = nil, audio: AudioCapturing
    ) -> DictationController {
        var settings = Settings.defaults
        settings.stt.eviction = eviction
        if let idleSeconds { settings.stt.evictionIdleSeconds = idleSeconds }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-warmth-\(UUID().uuidString)", isDirectory: true)
        let provider = try! SpeechEngineProvider(engines: [TinyEngine()], activeId: "tiny")
        return DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: dir),
            history: nil, hud: nil, audio: audio, micStatus: { .granted })
    }

    private func settings(eviction: Eviction, idleSeconds: Int? = nil) -> Settings {
        var settings = Settings.defaults
        settings.stt.eviction = eviction
        if let idleSeconds { settings.stt.evictionIdleSeconds = idleSeconds }
        return settings
    }

    private func poll(until condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func fastestPrewarmsOnDemand() {
        let audio = RecordingAudio()
        makeController(eviction: .fastest, audio: audio).prewarmCapture()
        #expect(audio.prewarms == 1)
    }

    @Test func balancedPrewarmsOnDemand() {
        let audio = RecordingAudio()
        makeController(eviction: .balanced, audio: audio).prewarmCapture()
        #expect(audio.prewarms == 1)
    }

    @Test func frugalNeverPrewarms() {
        let audio = RecordingAudio()
        makeController(eviction: .frugal, audio: audio).prewarmCapture()
        #expect(audio.prewarms == 0)
    }

    @Test func frugalNeverRefreshesBinding() {
        let audio = RecordingAudio()
        makeController(eviction: .frugal, audio: audio).refreshCaptureBinding()
        #expect(audio.refreshes == 0)
    }

    @Test func balancedRefreshesBindingOnWake() {
        let audio = RecordingAudio()
        makeController(eviction: .balanced, audio: audio).refreshCaptureBinding()
        #expect(audio.refreshes == 1)
    }

    // Fastest has no pending idle-eviction checkpoint to dispose the unit, so downgrading tiers must do
    // it explicitly — else the mic stays held after picking a mic-friendlier tier.
    @Test func switchingFromFastestToFrugalDisposesTheWarmUnit() {
        let audio = RecordingAudio()
        let controller = makeController(eviction: .fastest, audio: audio)
        controller.prewarmCapture()
        #expect(audio.releases == 0)
        controller.updateSettings(settings(eviction: .frugal))
        #expect(audio.releases == 1)
    }

    @Test func switchingFromFastestToBalancedKeepsItWarmThenReleasesOnIdle() async {
        let audio = RecordingAudio()
        let controller = makeController(eviction: .fastest, audio: audio)
        controller.prewarmCapture()
        controller.updateSettings(settings(eviction: .balanced, idleSeconds: 0))
        #expect(audio.prewarms == 2)
        await poll { audio.releases >= 1 }
        #expect(audio.releases >= 1)
    }

    // A launch-time Balanced prewarm has no post-dictation checkpoint, so release must be scheduled at
    // prewarm time or the mic is held until the first dictation.
    @Test func balancedPrewarmDoesNotHoldTheMicIndefinitely() async {
        let audio = RecordingAudio()
        let controller = makeController(eviction: .balanced, idleSeconds: 0, audio: audio)
        controller.prewarmCapture()
        await poll { audio.releases >= 1 }
        #expect(audio.releases >= 1)
    }
}
