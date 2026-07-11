import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Frugal opens the mic only while dictating, so the warm capture unit the commit path leaves realized must
// be disposed at the terminal — including when the user switches to Frugal mid-dictation (where
// reconcileCaptureWarmth defers to this path). Also covers the plain steady-state Frugal dictation.
@MainActor
struct FrugalCaptureReleaseTests {
    private final class TextEngine: SpeechEngine, @unchecked Sendable {
        let id = "text"
        let displayName = "Text"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "hello world" }
        func evict() async {}
    }

    private final class ReleaseRecordingAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var _releases = 0
        var releases: Int { lock.withLock { _releases } }
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
        func releaseWarm() { lock.withLock { _releases += 1 } }
    }

    private func makeController(eviction: Eviction, audio: AudioCapturing) -> (DictationController, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-frugal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        ModeStore.seedStarterFilesForTesting(in: support.appendingPathComponent("modes", isDirectory: true))
        let provider = try! SpeechEngineProvider(engines: [TextEngine()], activeId: "text")
        var settings = Settings.defaults
        settings.stt = .init(engine: "text", eviction: eviction, evictionIdleSeconds: nil)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: support),
            history: HistoryStore(supportDir: support), hud: nil, audio: audio,
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
        return (controller, support)
    }

    private func runDictation(_ controller: DictationController) async {
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
    }

    @Test func frugalDictationReleasesTheWarmUnit() async {
        let audio = ReleaseRecordingAudio(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("capture.wav"))
        let (controller, support) = makeController(eviction: .frugal, audio: audio)
        defer { try? FileManager.default.removeItem(at: support) }

        await runDictation(controller)

        #expect(audio.releases >= 1)
    }

    @Test func switchingToFrugalMidDictationReleasesTheWarmUnitAtTheTerminal() async {
        let audio = ReleaseRecordingAudio(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("capture.wav"))
        let (controller, support) = makeController(eviction: .fastest, audio: audio)
        defer { try? FileManager.default.removeItem(at: support) }

        controller.handleStart()
        await controller.captureBringUpTask?.value
        var frugal = Settings.defaults
        frugal.stt = .init(engine: "text", eviction: .frugal, evictionIdleSeconds: nil)
        frugal.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        controller.updateSettings(frugal)
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(audio.releases >= 1)
    }
}
