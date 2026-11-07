import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct DiscardTakeTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        let transcript: String
        init(_ transcript: String) { self.transcript = transcript }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { transcript }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private final class HUDSpy: HUDPresenting {
        var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    @MainActor private final class Inserts { var texts: [String] = [] }

    private func run(_ transcript: String) async -> (inserts: [String], hud: [HUDState], history: [HistoryEntry]) {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-discard-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        var mode = Mode(id: "m", name: "M")
        mode.commands.liveEdits = true
        try? ModeStore.write(mode, to: modesDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let history = HistoryStore(supportDir: supportDir)
        let hud = HUDSpy()
        let inserts = Inserts()
        let controller = DictationController(
            settings: settings, provider: try! SpeechEngineProvider(engines: [FixedEngine(transcript)], activeId: "fixed"),
            config: ConfigCache(supportDir: supportDir), history: history, hud: hud, permits: { _ in true },
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, text, _ in inserts.texts.append(text); return true },
            submitKey: { _ in },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 4242, focusedWindowId: "cg:99") },
            micStatus: { .granted }, accessibilityGranted: { true })
        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        for _ in 0..<50 where history.entries(limit: nil).isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        return (inserts.texts, hud.states, history.entries(limit: nil))
    }

    @Test func neverMindAtTheEndInsertsNothingKeepsNothingAndSaysSo() async {
        let result = await run("Draft the memo for Sam. Never mind.")
        #expect(result.inserts.isEmpty)
        #expect(result.history.isEmpty)
        #expect(result.hud.contains { if case .advisory(DictationController.discardedMessage) = $0 { true } else { false } })
    }

    @Test func neverMindInsideASentenceIsInserted() async {
        let result = await run("Never mind the cost, ship it.")
        #expect(result.inserts.count == 1)
        #expect(result.inserts.first?.contains("Never mind the cost") == true)
        #expect(result.history.count == 1)
    }
}
