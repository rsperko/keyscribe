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

private final class WedgeableEngine: SpeechEngine, @unchecked Sendable {
    let id: String
    let displayName = "Wedge"
    let supportsRecognitionBias = true
    private let started: Signal
    private let release: Signal
    init(id: String, started: Signal, release: Signal) {
        self.id = id
        self.started = started
        self.release = release
    }
    func loadIfNeeded() async throws {}
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        started.fire()
        await release.wait()
        return "unreachable — release only fires at test teardown"
    }
    func evict() async {}
}

private final class InstantEngine: SpeechEngine, @unchecked Sendable {
    let id: String
    let displayName = "Instant"
    let supportsRecognitionBias = true
    private let text: String
    init(id: String, text: String) { self.id = id; self.text = text }
    func loadIfNeeded() async throws {}
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { text }
    func evict() async {}
}

private final class FakeAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    init(url: URL) { self.url = url }
    func start(sampleRate: Int) async throws -> URL { url }
    func stop() -> URL? { url }
}

private actor InsertSpy {
    private(set) var calls = 0
    func record() { calls += 1 }
}

@MainActor
struct TranscribeGateRecoveryTests {
    @Test func repeatedBusyRejectionsRebuildTheTranscribeGateSoANewDictationCanProceed() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let started = Signal()
        let release = Signal()
        defer { release.fire() }
        let wedge = WedgeableEngine(id: "wedge", started: started, release: release)
        let instant = InstantEngine(id: "instant", text: "hello world")
        let provider = try! SpeechEngineProvider(engines: [wedge, instant], activeId: "wedge")
        let insertSpy = InsertSpy()
        var settings = Settings.defaults
        settings.stt = .init(engine: "wedge", eviction: .fastest)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await started.wait()
        controller.cancel()

        for _ in 0..<3 {
            controller.handleStart()
            await controller.captureBringUpTask?.value
            controller.handleCommit()
            await controller.dictationTask?.value
        }

        settings.stt.engine = "instant"
        try! provider.setActive("instant")
        controller.updateSettings(settings)

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(controller.lastResult == "hello world")
        #expect(await insertSpy.calls == 1)
    }

    @Test func dictationCommittedDuringSelfTestWaitsThenSucceeds() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let selfTestStarted = Signal()
        let selfTestRelease = Signal()
        defer { selfTestRelease.fire() }
        let selfTestEngine = WedgeableEngine(id: "selftest", started: selfTestStarted, release: selfTestRelease)
        let instant = InstantEngine(id: "instant", text: "hello world")
        let provider = try! SpeechEngineProvider(engines: [selfTestEngine, instant], activeId: "instant")
        let insertSpy = InsertSpy()
        var settings = Settings.defaults
        settings.stt = .init(engine: "instant", eviction: .fastest)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
        controller.selfTestClipURLOverride = supportDir.appendingPathComponent("selftest.wav")

        let selfTestTask = Task { await controller.selfTestForSettings(selfTestEngine) }
        await selfTestStarted.wait()

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        // Lets the commit reach the gate (and previously be rejected) before the self-test releases it.
        try? await Task.sleep(for: .milliseconds(200))
        selfTestRelease.fire()

        await controller.dictationTask?.value
        _ = await selfTestTask.value

        #expect(controller.lastResult == "hello world")
        #expect(await insertSpy.calls == 1)
    }

    // A single boolean would regress here: a second self-test finishing while the first still holds the
    // gate must not clear occupancy out from under it — guards the occupancy counter against being
    // simplified to a flag.
    @Test func concurrentSelfTestFinishingDoesNotStrandADictationBehindAnotherSelfTest() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let startedA = Signal()
        let releaseA = Signal()
        defer { releaseA.fire() }
        let selfTestA = WedgeableEngine(id: "selftestA", started: startedA, release: releaseA)
        let selfTestB = InstantEngine(id: "selftestB", text: "x")
        let instant = InstantEngine(id: "instant", text: "hello world")
        let provider = try! SpeechEngineProvider(engines: [instant], activeId: "instant")
        let insertSpy = InsertSpy()
        var settings = Settings.defaults
        settings.stt = .init(engine: "instant", eviction: .fastest)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
        controller.selfTestClipURLOverride = supportDir.appendingPathComponent("selftest.wav")

        let taskA = Task { await controller.selfTestForSettings(selfTestA) }
        await startedA.wait()

        _ = await controller.selfTestForSettings(selfTestB)

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        try? await Task.sleep(for: .milliseconds(200))
        releaseA.fire()

        await controller.dictationTask?.value
        _ = await taskA.value

        #expect(controller.lastResult == "hello world")
        #expect(await insertSpy.calls == 1)
    }
}
