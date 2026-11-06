import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct EngineKeeperTests {
    private final class Engine: SpeechEngine, @unchecked Sendable {
        let id: String
        let displayName = "Engine"
        let supportsRecognitionBias = false
        var loads = 0
        var evictions = 0
        let evicted = Signal()
        init(id: String = "e") { self.id = id }
        func loadIfNeeded() async throws { loads += 1 }
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "" }
        func evict() async { evictions += 1; evicted.fire() }
    }

    private final class Host: EngineKeeperHost {
        var isBusy = false
        var isCapturingAudio = false
        var engineSettings = Settings.defaults
        var warmupPlan = ResolvedConfig(
            modes: [], dictionary: DictionarySet(), replacements: ReplacementsSet(), connections: ConnectionSet(), fragments: [:])
        var activeProviderEngine: any SpeechEngine
        var idleWork: [() -> Void] = []
        var releasedCapture = 0
        init(engine: any SpeechEngine) { activeProviderEngine = engine }
        func whenIdle(_ work: @escaping () -> Void) { isBusy ? idleWork.append(work) : work() }
        func releaseWarmCapture() { releasedCapture += 1 }
    }

    private func keeper(_ host: Host) -> EngineKeeper {
        let keeper = EngineKeeper(warmupClip: nil)
        keeper.host = host
        return keeper
    }

    @Test func warmingTheSameEngineTwiceSharesOneLoad() async throws {
        let engine = Engine()
        let keeper = keeper(Host(engine: engine))
        let first = keeper.warm(engine)
        let second = keeper.warm(engine)
        try await first.value
        try await second.value
        #expect(engine.loads == 1)
        keeper.invalidateWarm(engine.id)
        try await keeper.warm(engine).value
        #expect(engine.loads == 2)
    }

    @Test func anEngineInUseIsEvictedOnlyOnceTheTakeEnds() async {
        let engine = Engine()
        let host = Host(engine: engine)
        host.isBusy = true
        let keeper = keeper(host)
        keeper.protect(engine)
        keeper.evictSwitchedAway(engine)
        #expect(engine.evictions == 0)
        #expect(host.idleWork.count == 1)
        host.idleWork.removeFirst()()
        await engine.evicted.wait()
        #expect(engine.evictions == 1)
    }

    @Test func theFrugalTierEvictsRightAfterATakeAndReleasesTheMicrophone() async {
        let engine = Engine()
        let host = Host(engine: engine)
        host.engineSettings.stt.eviction = .frugal
        let keeper = keeper(host)
        keeper.applyEvictionAfterDictation(engine: engine)
        await engine.evicted.wait()
        #expect(engine.evictions == 1)
        #expect(host.releasedCapture == 1)
    }

    @Test func theFastestTierKeepsTheModelLoaded() async throws {
        let engine = Engine()
        let host = Host(engine: engine)
        host.engineSettings.stt.eviction = .fastest
        keeper(host).applyEvictionAfterDictation(engine: engine)
        try await Task.sleep(for: .milliseconds(30))
        #expect(engine.evictions == 0)
        #expect(host.releasedCapture == 0)
    }
}
