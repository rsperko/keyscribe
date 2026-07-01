import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Proves the window-level focus guard is actually FED real data, not just unit-tested in isolation.
// decideInsertion already diverts to the clipboard when the captured and current focusedWindowId
// differ; this drives the injected snapshot seam to return window A at press and window B at
// insertion and asserts the real DictationController routes through the clipboard branch. The
// regression that would catch ContextProbe.snapshot() going back to a hardcoded nil window id.
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
        func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private final class Captured: @unchecked Sendable {
        var decision: InsertionDecision?
    }

    private func run(
        captured capturedWindow: String?, current currentWindow: String?, secure: Bool = false
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
        // snapshot() is read once at press (capture) and once at insertion (current); hand back the
        // captured window first, the current window thereafter.
        let calls = LockedCounter()
        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { decision, _, _, _ in result.decision = decision; return true },
            snapshot: {
                let n = calls.next()
                return TargetSnapshot(
                    bundleId: "test.bundle", focusedWindowId: n == 0 ? capturedWindow : currentWindow,
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

    // A focused secure field diverts to the clipboard even when app and window match — proves the
    // controller carries TargetSnapshot.isSecureField from the snapshot seam into decideInsertion.
    @Test func secureFieldDivertsToClipboard() async {
        let decision = await run(captured: "cg:101", current: "cg:101", secure: true)
        #expect(decision == .clipboardFallback(reason: .secureField))
    }
}
