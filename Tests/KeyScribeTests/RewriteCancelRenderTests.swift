import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if fired { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }
    }

    func fire() {
        lock.lock()
        fired = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

private final class HUDSpy: HUDPresenting {
    private(set) var states: [HUDState] = []
    func render(_ state: HUDState) { states.append(state) }
}

// DictationCancellationTests counts `.hidden` renders around cancel but never cancels inside the
// request-build window. `.rewriting` is in holdsKeyFocus, so a stale render after cancel re-takes key
// focus on a HUD the machine no longer considers cancellable — ESC can't reach it and it swallows the
// user's keystrokes until the next dictation. Pins the repo invariant "the recording HUD is key ⟺ the
// HUD is visible and cancellable" across that window (X-2).
@MainActor
struct RewriteCancelRenderTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "hello world" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private final class SpyLLM: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            lock.withLock { _calls += 1 }
            return "rewritten"
        }
    }

    @Test func cancellingInsideTheRequestBuildWindowNeverRendersRewriting() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-cancelbuild-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        // Preceding-text context is what makes build() await the AX probe — the suspension X-2 lands in.
        var mode = Mode(id: "cloud", name: "Cloud")
        mode.aiRewrite = Mode.AIRewrite(
            connection: "c", prompt: "Clean this up.", context: Mode.ContextOptIn(precedingText: true))
        try? ModeStore.write(mode, to: modesDir)
        try? ConnectionStore.write(
            ConnectionSet(connections: [Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")]),
            to: supportDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let probeEntered = Signal(), releaseProbe = Signal()
        let hud = HUDSpy()
        let llm = SpyLLM()
        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 100, focusedWindowId: "cg:1") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            precedingTextProbe: { _, _ in
                probeEntered.fire()
                await releaseProbe.wait()
                return "preceding"
            },
            llmClient: llm)

        controller.setNextModeOverride(id: mode.id)
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await probeEntered.wait()

        // The blocked probe is the only suspension the dictation task cannot get past, so once it has had a
        // scheduling window it is definitively parked at build()'s `await precedingTextTask.value`. The
        // llmCalls == 0 assertion below confirms the cancel really landed before the rewrite, not after.
        try? await Task.sleep(for: .milliseconds(100))

        let task = controller.dictationTask
        controller.cancel()
        let statesAtCancel = hud.states.count
        releaseProbe.fire()
        await task?.value

        let after = hud.states.suffix(from: statesAtCancel)
        #expect(!after.contains { if case .rewriting = $0 { return true } else { return false } })
        #expect(hud.states.last == .hidden)
        #expect(llm.calls == 0)
    }
}
