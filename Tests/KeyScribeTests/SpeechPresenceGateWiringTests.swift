import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct SpeechPresenceGateWiringTests {
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

    private struct StubPresence: SpeechPresenceDetecting {
        let presence: SpeechPresence
        func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading {
            SpeechPresenceReading(
                presence: presence, maxProbability: presence == .speech ? 0.9 : 0,
                latencyMs: 1, modelUsed: true)
        }
    }

    private final class LateBoundCancel: @unchecked Sendable {
        var run: (@MainActor () -> Void)?
    }

    private struct CancellingPresence: SpeechPresenceDetecting {
        let cancel: LateBoundCancel
        func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading {
            await MainActor.run { cancel.run?() }
            return SpeechPresenceReading(
                presence: .noSpeech, maxProbability: 0, latencyMs: 1, modelUsed: true)
        }
    }

    private func run(transcript: String, detector: SpeechPresenceDetecting) async -> DictationRecord? {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vad-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var m = Mode(id: "plain", name: "plain")
        m.commands = .init(liveEdits: false, privacy: false)
        try? ModeStore.write(m, to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            presenceDetector: detector,
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        return controller.lastRecord
    }

    @Test func noSpeechGateSuppressesTranscription() async {
        let record = await run(transcript: "hello world", detector: StubPresence(presence: .noSpeech))
        #expect(record?.outcome == .noSpeech)
    }

    @Test func speechGateProceedsToTranscription() async {
        let record = await run(transcript: "hello world", detector: StubPresence(presence: .speech))
        #expect(record?.outcome == .inserted)
    }

    @Test func cancelDuringGateStillRemovesTheCaptureFile() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vad-cancel-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var m = Mode(id: "plain", name: "plain")
        m.commands = .init(liveEdits: false, privacy: false)
        try? ModeStore.write(m, to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let wav = supportDir.appendingPathComponent("capture.wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data([0]))

        let cancel = LateBoundCancel()
        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: "hello world")], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: wav),
            presenceDetector: CancellingPresence(cancel: cancel),
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
        cancel.run = { controller.dictationTask?.cancel() }

        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(!FileManager.default.fileExists(atPath: wav.path))
        #expect(controller.lastRecord == nil)
    }

    @Test func unavailableModelFailsOpenToTranscription() async {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vad-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        let record = await run(
            transcript: "hello world", detector: SpeechPresenceDetector(modelsDir: emptyDir))
        #expect(record?.outcome == .inserted)
    }
}
