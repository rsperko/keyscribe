import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct ConfigProblemHUDTests {
    private final class InstantEngine: SpeechEngine, @unchecked Sendable {
        let id = "instant"
        let displayName = "Instant"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "hello" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    @MainActor
    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private let unusedKey = ConfigFileIssue.unusedKeys(
        "dictionary.toml", [UnknownConfigKey(path: "termz", suggestion: "terms")])
    private let unreadable = ConfigFileIssue.unreadable(
        "replacements.toml", error: .invalid("Expected a value"), recovery: .ignored)

    private func announce(_ issues: [ConfigFileIssue]) -> HUDState? {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-confighud-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let hud = HUDSpy()
        let provider = try! SpeechEngineProvider(engines: [InstantEngine()], activeId: "instant")
        var settings = Settings.defaults
        settings.stt = .init(engine: "instant", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud, permits: { _ in true },
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
        controller.announceConfigProblems(issues)
        return hud.states.last
    }

    @Test func aKeyNothingReadsIsAnnouncedAsAnAdvisoryNotAFailure() {
        #expect(announce([unusedKey]) == .advisory(message: unusedKey.oneLine))
    }

    @Test func anUnreadableFileIsAnnouncedAsAFailureEvenBesideAnAdvisory() {
        #expect(announce([unusedKey, unreadable])
            == .error(message: "\(unusedKey.oneLine) · \(unreadable.oneLine)", action: nil))
    }
}
