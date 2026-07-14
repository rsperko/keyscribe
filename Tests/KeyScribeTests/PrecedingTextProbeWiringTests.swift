import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// A preceding-text mode probes the field once during recording and reuses that value for the rewrite
// prompt, rather than serializing the AX walk between STT and the LLM request.
@MainActor
struct PrecedingTextProbeWiringTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "draft the memo" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    // Echoes the <content> block so the test can check the probed value landed in it.
    private actor EchoLLM: LLMClient {
        private(set) var lastUser = ""
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            lastUser = user
            guard let start = user.range(of: "<content>\n"),
                  let end = user.range(of: "\n</content>") else { return user }
            return String(user[start.upperBound..<end.lowerBound])
        }
    }

    @MainActor private final class ProbeSpy {
        private(set) var bundleIds: [String] = []
        var value: String? = "PRECEDINGCTX"
        func probe(_ bundleId: String) async -> String? {
            bundleIds.append(bundleId)
            return value
        }
    }

    private func contextMode() -> Mode {
        var mode = Mode(id: "m", name: "M")
        mode.aiRewrite = .init(connection: "c1", prompt: "Rewrite it.", context: .init(precedingText: true))
        return mode
    }
    private let conn = Connection(id: "c1", name: "C1", provider: .gemini, model: "m", keyRef: "k")

    private func makeController(
        mode: Mode, probe: ProbeSpy, llm: any LLMClient,
        pressSnapshot: (@MainActor () -> TargetSnapshot)? = nil,
        fullSnapshot: (@MainActor () async -> TargetSnapshot)? = nil
    ) -> DictationController {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-preceding-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try? ModeStore.write(mode, to: modesDir)
        try? ConnectionStore.write(ConnectionSet(connections: [conn]), to: supportDir)

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
            precedingTextProbe: { await probe.probe($0) },
            llmClient: llm)
    }

    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func aContextModeProbesOnceDuringRecordingAndReusesIt() async {
        let probe = ProbeSpy()
        let llm = EchoLLM()
        let controller = makeController(mode: contextMode(), probe: probe, llm: llm)

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(await poll { probe.bundleIds == ["test.bundle"] })

        controller.handleCommit()
        await controller.dictationTask?.value

        // Reused, not re-run: still exactly one probe.
        #expect(probe.bundleIds == ["test.bundle"])
        #expect(await llm.lastUser.contains("PRECEDINGCTX"))
    }

    @Test func aModeWithoutPrecedingContextNeverProbes() async {
        let probe = ProbeSpy()
        var mode = Mode(id: "m", name: "M")
        mode.aiRewrite = .init(connection: "c1", prompt: "Rewrite it.", context: .init())
        let controller = makeController(mode: mode, probe: probe, llm: EchoLLM())

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(probe.bundleIds.isEmpty)
    }

    // The async full snapshot's isSecureField neuters the mode before the probe gate opens.
    @Test func aSecureFieldSuppressesThePrecedingTextProbe() async {
        let probe = ProbeSpy()
        let controller = makeController(
            mode: contextMode(), probe: probe, llm: EchoLLM(),
            pressSnapshot: { TargetSnapshot(bundleId: "app") },
            fullSnapshot: { TargetSnapshot(bundleId: "app", isSecureField: true) })

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.snapshotAdoptionTask?.value
        try? await Task.sleep(for: .milliseconds(80))

        #expect(probe.bundleIds.isEmpty)
        controller.cancel()
    }
}
