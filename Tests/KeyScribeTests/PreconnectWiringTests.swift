import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// A mode wired to a BYOK connection warms that endpoint during recording so the post-commit rewrite
// reuses a warm TLS connection; a local-only mode makes no network touch at all.
@MainActor
struct PreconnectWiringTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "hello" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private final class PreconnectSpyLLM: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        var preconnectedIds: [String] { lock.withLock { ids } }
        func complete(system: String, user: String, connection: Connection) async throws -> String { "out" }
        func preconnect(connection: Connection) async {
            lock.withLock { ids.append(connection.id) }
        }
    }

    private func makeController(
        mode: Mode, connection: Connection?, llm: PreconnectSpyLLM,
        pressSnapshot: (@MainActor () -> TargetSnapshot)? = nil,
        fullSnapshot: (@MainActor () async -> TargetSnapshot)? = nil
    ) -> DictationController {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-preconnect-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try? ModeStore.write(mode, to: modesDir)
        if let connection { try? ConnectionStore.write(ConnectionSet(connections: [connection]), to: supportDir) }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        return DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            submitKey: { _ in },
            pressSnapshot: pressSnapshot,
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            snapshotAsync: fullSnapshot,
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: llm)
    }

    private func rewriteMode() -> Mode {
        var mode = Mode(id: "m", name: "M")
        mode.aiRewrite = .init(connection: "c1", prompt: "Rewrite it.", context: .init())
        return mode
    }
    private let conn = Connection(id: "c1", name: "C1", provider: .gemini, model: "m", keyRef: "k")

    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<60 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func aRewriteModePreconnectsItsConnectionDuringRecording() async {
        let llm = PreconnectSpyLLM()
        let controller = makeController(mode: rewriteMode(), connection: conn, llm: llm)

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(await poll { llm.preconnectedIds == ["c1"] })
        controller.cancel()
    }

    @Test func aLocalOnlyModeMakesNoPreconnect() async {
        let llm = PreconnectSpyLLM()
        let controller = makeController(mode: Mode(id: "m", name: "M"), connection: nil, llm: llm)

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        try? await Task.sleep(for: .milliseconds(80))

        #expect(llm.preconnectedIds.isEmpty)
        controller.cancel()
    }

    // Production shape: the fast press snapshot carries no secure-field info, so the endpoint is warmed
    // only after the async full snapshot confirms a non-secure field.
    @Test func aRewriteModePreconnectsOnlyAfterANonSecureFullSnapshot() async {
        let llm = PreconnectSpyLLM()
        let controller = makeController(
            mode: rewriteMode(), connection: conn, llm: llm,
            pressSnapshot: { TargetSnapshot(bundleId: "app") },
            fullSnapshot: { TargetSnapshot(bundleId: "app", isSecureField: false) })

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.snapshotAdoptionTask?.value

        #expect(await poll { llm.preconnectedIds == ["c1"] })
        controller.cancel()
    }

    // The fast press snapshot (bundle id only) doesn't yet know the field is secure; the async full
    // snapshot reveals it and must still suppress the preconnect.
    @Test func aSecureFieldRevealedByTheFullSnapshotSuppressesPreconnect() async {
        let llm = PreconnectSpyLLM()
        let controller = makeController(
            mode: rewriteMode(), connection: conn, llm: llm,
            pressSnapshot: { TargetSnapshot(bundleId: "app") },
            fullSnapshot: { TargetSnapshot(bundleId: "app", isSecureField: true) })

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.snapshotAdoptionTask?.value
        try? await Task.sleep(for: .milliseconds(80))

        #expect(llm.preconnectedIds.isEmpty)
        controller.cancel()
    }
}
