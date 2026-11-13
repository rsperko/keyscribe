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

    private final class Listener: SpeechEngine, @unchecked Sendable {
        let id = "listener"
        let displayName = "Listener"
        let supportsRecognitionBias = false
        let supportsSampleInput = true
        let loading = Signal("loading")
        let finishLoad = Signal("finish load")
        let started = Signal("started")
        let finish = Signal("finish")
        var holdsLoad = false
        var holds = false
        var heard: [URL] = []
        var evictions = 0
        let evicted = Signal("evicted")
        func loadIfNeeded() async throws {
            guard holdsLoad else { return }
            loading.fire()
            await finishLoad.wait()
        }
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            heard.append(wavURL)
            started.fire()
            if holds { await finish.wait() }
            return "the whole reply"
        }
        func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String { "" }
        func evict() async { evictions += 1; evicted.fire() }
    }

    private let wav = URL(fileURLWithPath: "/tmp/reply.wav")

    @Test func aCheckHearsTheWholeReplyInOneTranscription() async {
        let engine = Listener()
        #expect(await keeper(Host(engine: engine)).listen(engine, wav: wav, gate: SingleFlightDeadline()) == .heard("the whole reply", checker: "listener"))
        #expect(engine.heard == [wav])
    }

    @Test func aCheckDuringADictationIsBusyAndLeavesTheModelAlone() async {
        let engine = Listener()
        let host = Host(engine: engine)
        host.isBusy = true
        #expect(await keeper(host).listen(engine, wav: wav, gate: SingleFlightDeadline()) == .busy)
        #expect(engine.heard.isEmpty)
    }

    private func commitAfterAbandonedCheck(_ end: (Task<EngineKeeper.Listening, Never>) -> Void, expecting outcome: EngineKeeper.Listening) async throws {
        let engine = Listener()
        engine.holds = true
        let keeper = keeper(Host(engine: engine))
        keeper.checkTimeout = 0.05
        let gate = SingleFlightDeadline()
        let listening = Task { await keeper.listen(engine, wav: wav, gate: gate) }
        await engine.started.wait()
        end(listening)
        #expect(await listening.value == outcome)
        #expect(await gate.isBusy)
        var cleared = false
        let commit = Task { @MainActor in
            await keeper.awaitSelfTestClearance(on: gate)
            cleared = true
            return try await gate.run(seconds: 5) { "dictation" }
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(!cleared)
        engine.finish.fire()
        #expect(try await commit.value == "dictation")
    }

    @Test func aCheckPastItsDeadlineHoldsTheCommitUntilTheEngineReallyReturns() async throws {
        try await commitAfterAbandonedCheck({ _ in }, expecting: .unavailable)
    }

    @Test func aCancelledCheckTheEngineKeepsRunningHoldsTheCommitUntilItReturns() async throws {
        try await commitAfterAbandonedCheck({ $0.cancel() }, expecting: .cancelled)
    }

    @Test func aCommitWithNoCheckDoesNotWait() async {
        let keeper = keeper(Host(engine: Listener()))
        let gate = SingleFlightDeadline()
        #expect(await !keeper.checkHolds(gate))
        await keeper.awaitSelfTestClearance(on: gate)
    }

    @Test func aCheckRefusedByAWedgedDictationLeavesTheNextCommitToFailAtOnce() async {
        let engine = Listener()
        let keeper = keeper(Host(engine: engine))
        let gate = SingleFlightDeadline()
        let wedge = Signal("wedge")
        defer { wedge.fire() }
        let wedged = Task { try? await gate.run(seconds: 0.05) { await wedge.wait() } }
        _ = await wedged.value
        #expect(await gate.isBusy)
        #expect(await keeper.listen(engine, wav: wav, gate: gate) == .busy)
        #expect(await !keeper.checkHolds(gate))
        await keeper.awaitSelfTestClearance(on: gate)
    }

    @Test func aFinishedCheckLeavesNothingForACommitToWaitOn() async {
        let engine = Listener()
        let keeper = keeper(Host(engine: engine))
        let gate = SingleFlightDeadline()
        _ = await keeper.listen(engine, wav: wav, gate: gate)
        #expect(await !keeper.checkHolds(gate))
    }

    @Test func anAbandonedCheckStopsHoldingCommitsOnceItReallyEnds() async {
        let engine = Listener()
        engine.holds = true
        let keeper = keeper(Host(engine: engine))
        keeper.checkTimeout = 0.05
        let gate = SingleFlightDeadline()
        #expect(await keeper.listen(engine, wav: wav, gate: gate) == .unavailable)
        #expect(await keeper.checkHolds(gate))
        engine.finish.fire()
        for _ in 0..<500 where await keeper.checkHolds(gate) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await !keeper.checkHolds(gate))
    }

    @Test func aCommitOnAReplacedGateDoesNotWaitOnTheOldOnesCheck() async {
        let engine = Listener()
        engine.holds = true
        defer { engine.finish.fire() }
        let keeper = keeper(Host(engine: engine))
        keeper.checkTimeout = 0.05
        let old = SingleFlightDeadline()
        _ = await keeper.listen(engine, wav: wav, gate: old)
        let replaced = SingleFlightDeadline()
        #expect(await !keeper.checkHolds(replaced))
        await keeper.awaitSelfTestClearance(on: replaced)
    }

    @Test func aCheckLoadsTheModelOutsideTheTranscriptionGate() async {
        let engine = Listener()
        engine.holdsLoad = true
        let keeper = keeper(Host(engine: engine))
        let gate = SingleFlightDeadline()
        let listening = Task { await keeper.listen(engine, wav: wav, gate: gate) }
        await engine.loading.wait()
        #expect(!(await gate.isBusy))
        engine.finishLoad.fire()
        #expect(await listening.value == .heard("the whole reply", checker: "listener"))
    }

    @Test func aCheckLeavesTheModelToTheEvictionSetting() async {
        let engine = Listener()
        let host = Host(engine: engine)
        host.engineSettings.stt.eviction = .frugal
        _ = await keeper(host).listen(engine, wav: wav, gate: SingleFlightDeadline())
        await engine.evicted.wait()
        #expect(engine.evictions == 1)
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
