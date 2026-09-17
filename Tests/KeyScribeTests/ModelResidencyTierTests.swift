import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

private final class ResidencySpyEngine: SpeechEngine, @unchecked Sendable {
    let id: String
    let displayName = "Residency Spy"
    let supportsRecognitionBias = false
    let loaded = Signal("loaded")
    let evicted = Signal("evicted")
    let transcribeStarted = Signal("transcribe started")
    private let loadRelease: Signal?
    private let transcribeRelease: Signal?
    private let lock = NSLock()
    private var _loads = 0
    private var _evictions = 0
    private var _transcribed: [URL] = []
    private var _isLoaded = false
    var isLoaded: Bool { lock.withLock { _isLoaded } }
    var loads: Int { lock.withLock { _loads } }
    var evictions: Int { lock.withLock { _evictions } }
    var transcribed: [URL] { lock.withLock { _transcribed } }

    init(id: String = "residency-spy", loadRelease: Signal? = nil, transcribeRelease: Signal? = nil) {
        self.id = id
        self.loadRelease = loadRelease
        self.transcribeRelease = transcribeRelease
    }

    func loadIfNeeded() async throws {
        lock.withLock { _loads += 1 }
        if let loadRelease { await loadRelease.wait() }
        lock.withLock { _isLoaded = true }
        loaded.fire()
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        lock.withLock { _transcribed.append(wavURL) }
        transcribeStarted.fire()
        if let transcribeRelease { await transcribeRelease.wait() }
        return "hello world"
    }

    func evict() async {
        lock.withLock { _evictions += 1; _isLoaded = false }
        evicted.fire()
    }
}

private final class FakeAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    init(url: URL) { self.url = url }
    func start(sampleRate: Int) async throws -> URL { url }
    func stop() -> URL? { url }
}

@MainActor
struct ModelResidencyTierTests {
    private struct Harness {
        let controller: DictationController
        let engine: ResidencySpyEngine
        let provider: SpeechEngineProvider
        let captureURL: URL
        let supportDir: URL
    }

    private func makeHarness(
        _ eviction: Eviction, engine: ResidencySpyEngine = ResidencySpyEngine(), warmupClip: URL? = nil,
        others: [ResidencySpyEngine] = [], serialized: Bool = false, idleSeconds: Int = 0
    ) -> Harness {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        ModeStore.seedStarterFilesForTesting(in: supportDir.appendingPathComponent("modes", isDirectory: true))
        let engines: [any SpeechEngine] = ([engine] + others).map { serialized ? SerializedEngine($0) as any SpeechEngine : $0 }
        let provider = try! SpeechEngineProvider(engines: engines, activeId: engine.id)
        var settings = Settings.defaults
        settings.stt = .init(engine: engine.id, eviction: eviction, evictionIdleSeconds: idleSeconds)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let captureURL = supportDir.appendingPathComponent("capture.wav")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil, permits: { _ in true },
            audio: FakeAudio(url: captureURL),
            insert: { _, _, _, _, _ in return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true },
            warmupClip: warmupClip)
        return Harness(controller: controller, engine: engine, provider: provider, captureURL: captureURL, supportDir: supportDir)
    }

    private func fires(_ signal: Signal, within seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if signal.hasFired { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return signal.hasFired
    }

    private func expectResidency(_ eviction: Eviction, _ engine: ResidencySpyEngine) async {
        switch eviction {
        case .fastest:
            try? await Task.sleep(for: .milliseconds(300))
            #expect(engine.evictions == 0)
        case .balanced, .frugal:
            #expect(await fires(engine.evicted, within: 2))
        }
    }

    @Test(arguments: [Eviction.fastest, .balanced, .frugal])
    func cancellingWhileRecordingAppliesTheTier(_ eviction: Eviction) async {
        let h = makeHarness(eviction)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.cancel()
        await expectResidency(eviction, h.engine)
    }

    @Test(arguments: [Eviction.fastest, .balanced, .frugal])
    func cancellingWhileArmingAppliesTheTier(_ eviction: Eviction) async {
        let h = makeHarness(eviction)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.handleStart()
        let bringUp = h.controller.captureBringUpTask
        h.controller.handleCommit()
        await bringUp?.value
        await expectResidency(eviction, h.engine)
    }

    @Test(arguments: [Eviction.fastest, .balanced, .frugal])
    func cancellingWhileTranscribingAppliesTheTier(_ eviction: Eviction) async {
        let release = Signal("transcribe release")
        let h = makeHarness(eviction, engine: ResidencySpyEngine(transcribeRelease: release))
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        await h.engine.transcribeStarted.wait()
        h.controller.cancel()
        await expectResidency(eviction, h.engine)
        release.fire()
    }

    @Test func frugalLaunchPreloadLeavesTheModelUnloaded() async {
        let h = makeHarness(.frugal)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.preloadActiveEngineIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.engine.loads == 0)
    }

    @Test func balancedLaunchPreloadEvictsAfterTheIdleWindow() async {
        let h = makeHarness(.balanced)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.preloadActiveEngineIfNeeded()
        #expect(await fires(h.engine.loaded, within: 2))
        #expect(await fires(h.engine.evicted, within: 2))
    }

    @Test func fastestLaunchPreloadKeepsTheModelLoaded() async {
        let h = makeHarness(.fastest)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.preloadActiveEngineIfNeeded()
        #expect(await fires(h.engine.loaded, within: 2))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.engine.evictions == 0)
    }

    @Test func idleWarmRunsTheWarmupClip() async {
        let clip = URL(fileURLWithPath: "/warmup-clip.wav")
        let h = makeHarness(.fastest, warmupClip: clip)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.preloadActiveEngineIfNeeded()
        await h.engine.transcribeStarted.wait()
        #expect(h.engine.transcribed == [clip])
    }

    @Test func aCommitDuringAColdLoadSkipsTheWarmupClip() async {
        let clip = URL(fileURLWithPath: "/warmup-clip.wav")
        let loadRelease = Signal("load release")
        let h = makeHarness(.fastest, engine: ResidencySpyEngine(loadRelease: loadRelease), warmupClip: clip)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        loadRelease.fire()
        await h.controller.dictationTask?.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.engine.transcribed == [h.captureURL])
    }

    @Test func aFrugalCancelDuringAColdLoadNeverLetsTheWarmupClipReloadTheModel() async {
        let clip = URL(fileURLWithPath: "/warmup-clip.wav")
        let loadRelease = Signal("load release")
        let h = makeHarness(.frugal, engine: ResidencySpyEngine(loadRelease: loadRelease),
                            warmupClip: clip, serialized: true)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.cancel()
        loadRelease.fire()
        #expect(await fires(h.engine.evicted, within: 2))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.engine.transcribed.isEmpty)
        #expect(!h.engine.isLoaded)
    }

    @Test func aSupersededPreloadDoesNotReplaceTheNewEnginesIdleEviction() async {
        let releaseA = Signal("load A")
        let engineA = ResidencySpyEngine(id: "engine-a", loadRelease: releaseA)
        let engineB = ResidencySpyEngine(id: "engine-b")
        let h = makeHarness(.balanced, engine: engineA, others: [engineB], serialized: true, idleSeconds: 1)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.preloadActiveEngineIfNeeded()
        let previous = h.provider.active
        try! h.provider.setActive(engineB.id)
        h.controller.evictSwitchedAwayEngine(previous)
        h.controller.preloadActiveEngineIfNeeded()
        #expect(await fires(engineB.loaded, within: 2))
        try? await Task.sleep(for: .milliseconds(100))
        releaseA.fire()
        #expect(await fires(engineB.evicted, within: 3))
        #expect(!engineB.isLoaded)
        #expect(!engineA.isLoaded)
    }

    @Test func switchingToFrugalDuringAPreloadEvictsWhenTheLoadLands() async {
        let loadRelease = Signal("load release")
        let h = makeHarness(.balanced, engine: ResidencySpyEngine(loadRelease: loadRelease),
                            serialized: true, idleSeconds: 3600)
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        h.controller.preloadActiveEngineIfNeeded()
        var settings = h.controller.settings
        settings.stt.eviction = .frugal
        h.controller.updateSettings(settings)
        loadRelease.fire()
        #expect(await fires(h.engine.evicted, within: 2))
        #expect(!h.engine.isLoaded)
    }
}
