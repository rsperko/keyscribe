import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Proves the focus guard is fed real data end-to-end, not just unit-tested: the snapshot seam
// returns window A at press and window B at insertion, and DictationController must route through
// the clipboard branch — catches ContextProbe.snapshot() regressing to a hardcoded nil window id.
@MainActor
struct FocusGuardWiringTests {
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

    private final class Captured: @unchecked Sendable {
        var decision: InsertionDecision?
    }

    private func run(
        captured capturedWindow: String?, current currentWindow: String?, secure: Bool = false,
        capturedPid: pid_t? = nil, currentPid: pid_t? = nil
    ) async -> InsertionDecision? {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-focus-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        let mode = Mode(id: "m", name: "M")
        try? ModeStore.write(mode, to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let result = Captured()
        // snapshot() fires once at press and once at insertion; return captured, then current.
        let calls = LockedCounter()
        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { decision, _, _, _, _ in result.decision = decision; return true },
            snapshot: {
                let n = calls.next()
                return TargetSnapshot(
                    bundleId: "test.bundle", pid: n == 0 ? capturedPid : currentPid,
                    focusedWindowId: n == 0 ? capturedWindow : currentWindow,
                    isSecureField: secure)
            },
            micStatus: { .granted },
            accessibilityGranted: { true })

        controller.setNextModeOverride(id: mode.id)
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        return result.decision
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; let c = count; count += 1; return c }
    }

    @Test func sameAppDifferentWindowDivertsToClipboard() async {
        let decision = await run(captured: "cg:101", current: "cg:202")
        #expect(decision == .clipboardFallback(reason: .focusChanged))
    }

    @Test func sameAppSameWindowInserts() async {
        let decision = await run(captured: "cg:101", current: "cg:101")
        #expect(decision == .insert)
    }

    @Test func unknownWindowIdFailsOpenToInsert() async {
        let decision = await run(captured: nil, current: nil)
        #expect(decision == .insert)
    }

    // Diverts even when app/window match, proving isSecureField flows from the snapshot into decideInsertion.
    @Test func secureFieldDivertsToClipboard() async {
        let decision = await run(captured: "cg:101", current: "cg:101", secure: true)
        #expect(decision == .clipboardFallback(reason: .secureField))
    }

    // Same bundle id, different process (a same-bundle helper stole focus) must divert — proving the pid
    // captured at press flows into decideInsertion, not just the bundle id.
    @Test func sameBundleDifferentPidDivertsToClipboard() async {
        let decision = await run(
            captured: "cg:101", current: "cg:101", capturedPid: 100, currentPid: 200)
        #expect(decision == .clipboardFallback(reason: .appChanged))
    }

    @Test func sameBundleSamePidInserts() async {
        let decision = await run(
            captured: "cg:101", current: "cg:101", capturedPid: 100, currentPid: 100)
        #expect(decision == .insert)
    }
}
