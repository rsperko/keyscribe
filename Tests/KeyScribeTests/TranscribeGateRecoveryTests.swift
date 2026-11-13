import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

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

private final class StuckOnceEngine: SpeechEngine, @unchecked Sendable {
    let id = "stuck-once"
    let displayName = "Stuck once"
    let supportsRecognitionBias = true
    private let started: Signal
    private let release: Signal
    init(started: Signal, release: Signal) {
        self.started = started
        self.release = release
    }
    func loadIfNeeded() async throws {}
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        guard wavURL.lastPathComponent == "reply.wav" else { return "hello world" }
        started.fire()
        await release.wait()
        return "the reply"
    }
    func evict() async {}
}

private final class WaitingHUDSpy: HUDPresenting {
    private(set) var states: [HUDState] = []
    func render(_ state: HUDState) { states.append(state) }
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
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil, permits: { _ in true },
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

    private func stuckCheck(
        _ supportDir: URL, started: Signal, release: Signal, hud: WaitingHUDSpy? = nil
    ) -> (DictationController, InsertSpy) {
        ModeStore.seedStarterFilesForTesting(in: supportDir.appendingPathComponent("modes", isDirectory: true))
        let engine = SerializedEngine(StuckOnceEngine(started: started, release: release))
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "stuck-once")
        let insertSpy = InsertSpy()
        var settings = Settings.defaults
        settings.stt = .init(engine: "stuck-once", eviction: .fastest)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud, permits: { _ in true },
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
        controller.transcribeTimeoutOverride = 0.3
        controller.checkStallSeconds = 0.3
        return (controller, insertSpy)
    }

    @Test func aDictationCommittedWhileAStuckReplyCheckHoldsTheModelWaitsPastItsTimeoutAndIsTranscribedOnceTheCheckEnds() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let started = Signal()
        let release = Signal()
        defer { release.fire() }
        let hud = WaitingHUDSpy()
        let (controller, insertSpy) = stuckCheck(supportDir, started: started, release: release, hud: hud)

        let check = Task { await controller.listenToSpokenReply(wav: supportDir.appendingPathComponent("reply.wav")) }
        await started.wait()
        defer { check.cancel() }
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        func waits() -> [Bool] {
            hud.states.compactMap { state -> Bool? in
                if case .waitingForCheck(_, let stalled) = state { return stalled }
                return nil
            }
        }
        for _ in 0..<1000 where !waits().contains(true) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isBusy)
        #expect(waits() == [false, true])
        #expect(controller.lastResult == nil)
        #expect(await insertSpy.calls == 0)

        release.fire()
        await controller.dictationTask?.value
        #expect(controller.lastResult == "hello world")
        #expect(await insertSpy.calls == 1)
    }

    @Test func cancellingADictationWaitingOnAStuckReplyCheckDiscardsIt() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let started = Signal()
        let release = Signal()
        defer { release.fire() }
        let (controller, insertSpy) = stuckCheck(supportDir, started: started, release: release)

        let check = Task { await controller.listenToSpokenReply(wav: supportDir.appendingPathComponent("reply.wav")) }
        await started.wait()
        defer { check.cancel() }
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.isBusy)
        controller.cancel()
        #expect(!controller.isBusy)
        release.fire()
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.lastResult == nil)
        #expect(await insertSpy.calls == 0)
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
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil, permits: { _ in true },
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
        try? await Task.sleep(for: .milliseconds(200))
        selfTestRelease.fire()

        await controller.dictationTask?.value
        _ = await selfTestTask.value

        #expect(controller.lastResult == "hello world")
        #expect(await insertSpy.calls == 1)
    }

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
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil, permits: { _ in true },
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
