import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// The dictation trigger is a bare modifier event tap with no notion of session state, so a key used to
// wake/unlock the machine can fire handleStart while the screen is locked. Proves the injected lock
// seam gates the start path and that handleScreenLocked cancels an in-flight dictation.
@MainActor
struct SessionLockGateTests {
    private final class InstantEngine: SpeechEngine, @unchecked Sendable {
        let id = "instant"
        let displayName = "Instant"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "hello" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var _starts = 0
        var starts: Int { lock.withLock { _starts } }
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { lock.withLock { _starts += 1 }; return url }
        func stop() -> URL? { url }
    }

    @MainActor
    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private func makeController(
        locked: @escaping @MainActor () -> Bool, audio: AudioCapturing, hud: HUDPresenting, supportDir: URL
    ) -> DictationController {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        ModeStore.seedStarterFilesForTesting(in: supportDir.appendingPathComponent("modes", isDirectory: true))
        let provider = try! SpeechEngineProvider(engines: [InstantEngine()], activeId: "instant")
        var settings = Settings.defaults
        settings.stt = .init(engine: "instant", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        return DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud, audio: audio,
            insert: { _, _, _, _, _ in return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true },
            isSessionLocked: locked)
    }

    @Test func handleStartWhileLockedDoesNotArmOrRecord() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let hud = HUDSpy()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let controller = makeController(locked: { true }, audio: audio, hud: hud, supportDir: supportDir)

        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(controller.isBusy == false)
        #expect(controller.dictationTask == nil)
        #expect(audio.starts == 0)
        #expect(hud.states.isEmpty)
    }

    @Test func handleStartWhileUnlockedProceedsToArm() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let hud = HUDSpy()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let controller = makeController(locked: { false }, audio: audio, hud: hud, supportDir: supportDir)

        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(audio.starts == 1)
        #expect(hud.states.contains { if case .recording = $0 { true } else { false } })
    }

    @Test func handleScreenLockedCancelsAnInFlightDictationAndDeletesTheCapture() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let captureURL = supportDir.appendingPathComponent("capture.wav")
        let controller = makeController(
            locked: { false }, audio: FakeAudio(url: captureURL), hud: HUDSpy(), supportDir: supportDir)
        FileManager.default.createFile(atPath: captureURL.path, contents: Data("pcm".utf8))

        controller.handleStart()
        await controller.captureBringUpTask?.value
        #expect(controller.isBusy)

        controller.handleScreenLocked()

        #expect(controller.isBusy == false)
        #expect(!FileManager.default.fileExists(atPath: captureURL.path))
    }

    @Test func handleScreenLockedWhileIdleIsANoOp() {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let controller = makeController(
            locked: { false }, audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            hud: HUDSpy(), supportDir: supportDir)

        controller.handleScreenLocked()

        #expect(controller.isBusy == false)
    }
}
