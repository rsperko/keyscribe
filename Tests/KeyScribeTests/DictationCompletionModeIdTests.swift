import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// `DictationCompletion.modeId` must carry the mode that actually produced the text — the first-run
// playground attributes a lesson to it. It is read from `activeMode`, which is torn down by
// `releaseCapturedPlan()`, so it must be captured BEFORE that teardown runs. This drives the REAL
// DictationController to guard against the completion arriving with a nil mode id.
@MainActor
struct DictationCompletionModeIdTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        private let text: String
        init(text: String) { self.text = text }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { text }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    @Test func completionCarriesTheModeThatProducedTheText() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-completion-modeid-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var mode = Mode(id: "polish", name: "Polish")
        mode.trailing = .none
        try? ModeStore.write(mode, to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: "hello")], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            submitKey: { _ in },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { true })

        var completion: DictationCompletion?
        controller.onDictationCompleted = { completion = $0 }

        controller.setNextModeOverride(id: mode.id)
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(completion?.outcome == .inserted)
        #expect(completion?.modeId == "polish")
    }
}
