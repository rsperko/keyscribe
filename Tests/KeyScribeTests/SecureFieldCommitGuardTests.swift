import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// A password field can steal focus AFTER the press/adoption snapshots settled (autofill, a manager
// prompt, the user clicking a login form mid-recording). FocusGuardWiringTests pins that the inserter
// diverts such a dictation to a concealed copy; these pin the other two consumers of the same fact —
// the cloud rewrite and history must be neutered too, not just the insert (X-1).
@MainActor
struct SecureFieldCommitGuardTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "hunter2 correct horse" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    // Records whether the rewrite ever reached the transport. A secure field must mean no call at all.
    private final class SpyLLM: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            lock.withLock { _calls += 1 }
            return "rewritten"
        }
    }

    // The snapshot seam fires three times per dictation: press, the commit-time probe, then the insert-time
    // read. `secureFrom` picks which of those first sees the password field, so a test can land the focus
    // steal in a chosen window.
    private final class SecureFrom: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let threshold: Int
        init(_ threshold: Int) { self.threshold = threshold }
        func next() -> Bool { lock.withLock { let c = count; count += 1; return c >= threshold } }
    }

    private struct Result {
        let record: DictationRecord?
        let decision: InsertionDecision?
        let llmCalls: Int
        let historyEntries: [HistoryEntry]
    }

    private func run(secureFrom: Int) async -> Result {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-secure-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var mode = Mode(id: "cloud", name: "Cloud")
        mode.aiRewrite = Mode.AIRewrite(connection: "c", prompt: "Clean this up.")
        try? ModeStore.write(mode, to: modesDir)
        try? ConnectionStore.write(
            ConnectionSet(connections: [Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")]),
            to: supportDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        settings.history = .init(enabled: true, retentionDays: 7)

        let history = HistoryStore(supportDir: supportDir)
        let llm = SpyLLM()
        let secure = SecureFrom(secureFrom)
        let captured = Captured()
        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { decision, _, _, _, _ in captured.decision = decision; return true },
            snapshot: {
                TargetSnapshot(
                    bundleId: "test.bundle", pid: 100, focusedWindowId: "cg:1",
                    isSecureField: secure.next())
            },
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: llm)

        controller.setNextModeOverride(id: mode.id)
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        // History appends on a background queue; give a would-be write time to land so the negative
        // assertion fails loudly rather than racing the flush into a false pass.
        try? await Task.sleep(for: .milliseconds(50))
        return Result(
            record: controller.lastRecord, decision: captured.decision,
            llmCalls: llm.calls, historyEntries: history.entries())
    }

    private final class Captured: @unchecked Sendable {
        var decision: InsertionDecision?
    }

    // The whole point of X-1: the rewrite ran BEFORE anything noticed the password field, so the spoken
    // password crossed the network boundary while the HUD claimed it was kept local.
    @Test func aSecureFieldFocusedAfterPressStillBlocksTheCloudRewrite() async {
        let result = await run(secureFrom: 1)
        #expect(result.llmCalls == 0)
        #expect(result.record?.cloudInvolved == false)
    }

    // design.md §4.4: "Password-field dictations are never written to history, regardless of the setting."
    @Test func aSecureFieldFocusedAfterPressIsNeverWrittenToHistory() async {
        let result = await run(secureFrom: 1)
        #expect(result.historyEntries.isEmpty)
    }

    @Test func aSecureFieldFocusedAfterPressStillDivertsToAConcealedCopy() async {
        let result = await run(secureFrom: 1)
        #expect(result.decision == .clipboardFallback(reason: .secureField))
    }

    // The narrowest window the commit probe cannot close: focus lands on the password field after the probe
    // resolved, so only the insert-time read sees it. The rewrite is already gone, but the inserter's
    // password-grade verdict must still veto history — the layer that stops a spoken password landing in
    // plaintext JSONL.
    @Test func aSecureFieldSeenOnlyAtInsertTimeStillVetoesHistory() async {
        let result = await run(secureFrom: 2)
        #expect(result.decision == .clipboardFallback(reason: .secureField))
        #expect(result.historyEntries.isEmpty)
    }

    // The press-time path must keep working unchanged — the commit probe only ever adds secure, never
    // clears it.
    @Test func aSecureFieldPresentAtPressStaysLocalAndUnrecorded() async {
        let result = await run(secureFrom: 0)
        #expect(result.llmCalls == 0)
        #expect(result.record?.cloudInvolved == false)
        #expect(result.historyEntries.isEmpty)
    }
}
