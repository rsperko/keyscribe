import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// STT engine whose loadIfNeeded() throws for the first `failTimes` calls, then succeeds — models a
// transient cold CoreML/MLX compile failure right after launch. transcribe() returns fixed text once
// loaded.
private final class FlakyLoadEngine: SpeechEngine, @unchecked Sendable {
    let id = "flaky"
    let displayName = "Flaky"
    let supportsRecognitionBias = false
    struct LoadBoom: Error {}
    private let lock = NSLock()
    private var calls = 0
    private let failTimes: Int
    private let text: String

    init(failTimes: Int, text: String = "hello world") {
        self.failTimes = failTimes
        self.text = text
    }

    var loadCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }

    private func nextCallShouldFail() -> Bool {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls <= failTimes
    }

    func loadIfNeeded() async throws {
        if nextCallShouldFail() { throw LoadBoom() }
    }
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { text }
    func evict() async {}
}

// loadIfNeeded always throws a timeout — exercises the "do not auto-retry a 300 s hang" branch
// without waiting on the real deadline.
private final class TimeoutLoadEngine: SpeechEngine, @unchecked Sendable {
    let id = "timeout"
    let displayName = "Timeout"
    let supportsRecognitionBias = false
    private let lock = NSLock()
    private var calls = 0
    var loadCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    private func bump() { lock.lock(); calls += 1; lock.unlock() }
    func loadIfNeeded() async throws { bump(); throw DeadlineExceeded() }
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "unreachable" }
    func evict() async {}
}

private final class FakeAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    init(url: URL) { self.url = url }
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL { url }
    func stop() -> URL? { url }
}

private actor InsertSpy {
    private(set) var calls = 0
    func record() { calls += 1 }
}

@MainActor
private final class HUDSpy: HUDPresenting {
    private(set) var states: [HUDState] = []
    func render(_ state: HUDState) { states.append(state) }
}

@MainActor
private final class LoadFailureRecorder {
    private(set) var records: [(engine: String, timedOut: Bool, error: String)] = []
    func record(_ engine: String, _ timedOut: Bool, _ error: String) {
        records.append((engine, timedOut, error))
    }
}

@MainActor
struct ModelLoadRetryTests {
    private struct Harness {
        let controller: DictationController
        let insertSpy: InsertSpy
        let hud: HUDSpy
        let recorder: LoadFailureRecorder
        let engine: FlakyLoadEngine
        let supportDir: URL
    }

    private func makeHarness(failTimes: Int) -> Harness {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let engine = FlakyLoadEngine(failTimes: failTimes)
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "flaky")
        let insertSpy = InsertSpy()
        let hud = HUDSpy()
        let recorder = LoadFailureRecorder()

        var settings = Settings.defaults
        settings.stt = .init(engine: "flaky", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true },
            recordModelLoadFailure: { recorder.record($0, $1, $2) })

        return Harness(
            controller: controller, insertSpy: insertSpy, hud: hud, recorder: recorder,
            engine: engine, supportDir: supportDir)
    }

    private func runOneDictation(_ h: Harness) async {
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        await h.controller.dictationTask?.value
    }

    private func sawError(_ states: [HUDState], message: String) -> Bool {
        states.contains {
            if case .error(let m, _) = $0 { return m == message }
            return false
        }
    }

    private func sawLoadError(_ states: [HUDState]) -> Bool {
        sawError(states, message: "Could not load the speech model")
    }

    @Test func transientColdLoadFailureRecoversSilentlyOnRetry() async {
        let h = makeHarness(failTimes: 1)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runOneDictation(h)

        #expect(await h.insertSpy.calls == 1)
        #expect(h.recorder.records.isEmpty)
        #expect(!sawLoadError(h.hud.states))
        #expect(h.engine.loadCalls >= 2)
    }

    @Test func persistentColdLoadFailureSurfacesErrorAndRecordsOnce() async {
        let h = makeHarness(failTimes: 99)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        await runOneDictation(h)

        #expect(await h.insertSpy.calls == 0)
        #expect(h.recorder.records.count == 1)
        #expect(h.recorder.records.first?.engine == "flaky")
        #expect(h.recorder.records.first?.timedOut == false)
        #expect(sawLoadError(h.hud.states))
    }

    @Test func loadTimeoutSurfacesWithoutRetrying() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let engine = TimeoutLoadEngine()
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "timeout")
        let insertSpy = InsertSpy()
        let hud = HUDSpy()
        let recorder = LoadFailureRecorder()
        var settings = Settings.defaults
        settings.stt = .init(engine: "timeout", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true },
            recordModelLoadFailure: { recorder.record($0, $1, $2) })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(await insertSpy.calls == 0)
        #expect(recorder.records.count == 1)
        #expect(recorder.records.first?.timedOut == true)
        #expect(sawError(hud.states, message: "Loading the speech model timed out"))
        // A timeout is terminal on the first attempt — no second load.
        #expect(engine.loadCalls == 1)
    }
}
