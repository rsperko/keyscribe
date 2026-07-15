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

    private actor CountingLLM: LLMClient {
        private(set) var callCount = 0
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            callCount += 1
            return user
        }
    }

    @MainActor private final class ProbeSpy {
        private(set) var pids: [pid_t] = []
        private(set) var windowIds: [String?] = []
        var value: String? = "PRECEDINGCTX"
        func probe(_ pid: pid_t, _ windowId: String?) async -> String? {
            pids.append(pid)
            windowIds.append(windowId)
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
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 4242, focusedWindowId: "cg:99") },
            snapshotAsync: fullSnapshot,
            micStatus: { .granted },
            accessibilityGranted: { true },
            precedingTextProbe: { await probe.probe($0, $1) },
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

        #expect(await poll { probe.pids == [4242] })

        controller.handleCommit()
        await controller.dictationTask?.value

        // Reused, not re-run: still exactly one probe, carrying the captured pid AND window id.
        #expect(probe.pids == [4242])
        #expect(probe.windowIds == ["cg:99"])
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

        #expect(probe.pids.isEmpty)
    }

    // The async full snapshot's isSecureField neuters the mode before the probe gate opens.
    @Test func aSecureFieldSuppressesThePrecedingTextProbe() async {
        let probe = ProbeSpy()
        let controller = makeController(
            mode: contextMode(), probe: probe, llm: EchoLLM(),
            pressSnapshot: { TargetSnapshot(bundleId: "app", pid: 77) },
            fullSnapshot: { TargetSnapshot(bundleId: "app", pid: 77, isSecureField: true) })

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.snapshotAdoptionTask?.value
        try? await Task.sleep(for: .milliseconds(80))

        #expect(probe.pids.isEmpty)
        controller.cancel()
    }

    // Secure is sticky: the press snapshot saw a password field (same pid 5), but the async full snapshot
    // read a non-secure field (focus moved within the process). The full read must NOT clear secure — the
    // cloud LLM stays uncalled and the probe stays shut (KS-01).
    @Test func aStickySecurePressSnapshotSuppressesCloudEvenIfFullSnapshotIsNonSecure() async {
        let probe = ProbeSpy()
        let llm = CountingLLM()
        let controller = makeController(
            mode: contextMode(), probe: probe, llm: llm,
            pressSnapshot: { TargetSnapshot(bundleId: "app", pid: 5, isSecureField: true) },
            fullSnapshot: { TargetSnapshot(bundleId: "app", pid: 5, isSecureField: false) })

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        await controller.snapshotAdoptionTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(await llm.callCount == 0)
        #expect(probe.pids.isEmpty)
    }

    // The target moved before the secure-aware snapshot could confirm it (press pid 1, full pid 2). We can't
    // prove the field was safe, so the dictation is forced local — the cloud LLM must never be called, and
    // the preceding-text probe must stay shut (KS-01).
    @Test func anUnconfirmedTargetSuppressesTheCloudRewrite() async {
        let probe = ProbeSpy()
        let llm = CountingLLM()
        let controller = makeController(
            mode: contextMode(), probe: probe, llm: llm,
            pressSnapshot: { TargetSnapshot(bundleId: "app", pid: 1) },
            fullSnapshot: { TargetSnapshot(bundleId: "other", pid: 2) })

        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        await controller.snapshotAdoptionTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(await llm.callCount == 0)
        #expect(probe.pids.isEmpty)
    }
}
