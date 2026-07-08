import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private actor BiasCapture {
    private(set) var terms: [String]?
    func record(_ t: [String]) { terms = t }
}

private final class RecordingBiasEngine: SpeechEngine, @unchecked Sendable {
    let id: String
    let displayName = "RecordingBias"
    let supportsRecognitionBias = true
    private let capture: BiasCapture
    init(id: String, capture: BiasCapture) { self.id = id; self.capture = capture }
    func loadIfNeeded() async throws {}
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        await capture.record(biasTerms)
        return "hello world"
    }
    func evict() async {}
}

private final class FakeAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    init(url: URL) { self.url = url }
    func start(sampleRate: Int) async throws -> URL { url }
    func stop() -> URL? { url }
}

@MainActor
struct RecognitionBiasCaptureTests {
    private func makeController(
        supportDir: URL, capture: BiasCapture, settings: Settings
    ) -> (DictationController, SpeechEngineProvider) {
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))
        try! DictionaryStore.write(DictionarySet(words: ["Kubernetes", "Postgres"]), to: supportDir)
        let engine = RecordingBiasEngine(id: "instant", capture: capture)
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "instant")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
        return (controller, provider)
    }

    @Test func biasDisabledMidDictationDoesNotDropTermsFromTheInFlightTranscribe() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        let capture = BiasCapture()
        var settings = Settings.defaults
        settings.stt = .init(engine: "instant", eviction: .fastest)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let (controller, _) = makeController(supportDir: supportDir, capture: capture, settings: settings)

        controller.handleStart()
        await controller.captureBringUpTask?.value
        var flipped = settings
        flipped.stt.recognitionBiasDisabledEngines = ["instant"]
        controller.updateSettings(flipped)
        controller.handleCommit()
        await controller.dictationTask?.value

        let terms = await capture.terms
        #expect(terms?.contains("Kubernetes") == true)
        #expect(terms?.contains("Postgres") == true)
    }

    @Test func biasEnabledMidDictationDoesNotAddTermsToTheInFlightTranscribe() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        let capture = BiasCapture()
        var settings = Settings.defaults
        settings.stt = .init(engine: "instant", eviction: .fastest)
        settings.stt.recognitionBiasDisabledEngines = ["instant"]
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let (controller, _) = makeController(supportDir: supportDir, capture: capture, settings: settings)

        controller.handleStart()
        await controller.captureBringUpTask?.value
        var flipped = settings
        flipped.stt.recognitionBiasDisabledEngines = []
        controller.updateSettings(flipped)
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(await capture.terms == [])
    }
}
