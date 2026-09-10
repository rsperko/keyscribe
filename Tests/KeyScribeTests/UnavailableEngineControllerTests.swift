import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct UnavailableEngineControllerTests {
    private final class UnrunnableEngine: SpeechEngine, @unchecked Sendable {
        let id = "unrunnable"
        let displayName = "Unrunnable Model"
        let supportsRecognitionBias = false
        let unavailability: EngineUnavailability? = .shaderLibraryUnloadable
        private let lock = NSLock()
        private var _loads = 0
        var loads: Int { lock.withLock { _loads } }
        func loadIfNeeded() async throws { lock.withLock { _loads += 1 } }
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            lock.withLock { _loads += 1 }
            return "hello"
        }
        func evict() async {}
    }

    private final class StubAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var _begins = 0
        var captureBegins: Int { lock.withLock { _begins } }
        init(url: URL) { self.url = url }
        func setCaptureLostHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock { _begins += 1 }
        }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private final class HUDRecorder: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private struct StubLLM: LLMClient {
        func complete(system: String, user: String, connection: Connection) async throws -> String { user }
    }

    private struct Harness {
        let controller: DictationController
        let engine: UnrunnableEngine
        let hud: HUDRecorder
        let audio: StubAudio
        let dir: URL
    }

    private func harness() -> Harness {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-unrunnable-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: supportDir.appendingPathComponent("modes", isDirectory: true), withIntermediateDirectories: true)
        var settings = Settings.defaults
        settings.stt = .init(engine: "unrunnable", eviction: .fastest)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let engine = UnrunnableEngine()
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "unrunnable")
        let hud = HUDRecorder()
        let audio = StubAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud,
            audio: audio,
            insert: { _, _, _, _, _ in true },
            submitKey: { _ in },
            captureSelection: { _ in nil },
            clipboard: { nil },
            snapshot: { TargetSnapshot(bundleId: "com.apple.Notes") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: StubLLM())
        return Harness(controller: controller, engine: engine, hud: hud, audio: audio, dir: supportDir)
    }

    @Test func aPressOnAModelThisBuildCannotRunPointsToSpeechModels() {
        let h = harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")

        #expect(h.hud.states.contains(.error(message: "Unrunnable Model can’t run in this build", action: .openSpeechModels)))
        #expect(h.audio.captureBegins == 0)
        #expect(h.engine.loads == 0)
    }

    @Test func preloadNeverLoadsAModelThisBuildCannotRun() async {
        let h = harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.preloadActiveEngineIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(h.engine.loads == 0)
    }
}
