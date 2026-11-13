import Foundation
import KeyScribeKit

@MainActor
protocol EngineKeeperHost: AnyObject {
    var isBusy: Bool { get }
    var isCapturingAudio: Bool { get }
    var engineSettings: Settings { get }
    var warmupPlan: ResolvedConfig { get }
    var activeProviderEngine: any SpeechEngine { get }
    func whenIdle(_ work: @escaping () -> Void)
    func releaseWarmCapture()
}

@MainActor
final class EngineKeeper {
    nonisolated static let bundledWarmupClip = Bundle.main.url(forResource: "model-selftest", withExtension: "wav")
    private static let selfTestTimeoutSeconds: Double = 30
    private static let selfTestSettlePollMs = 20
    private static let selfTestClearancePolls = 150

    weak var host: EngineKeeperHost?
    var selfTestClipOverride: URL?
    private let warmupClip: URL?
    private var warmTask: Task<Void, Error>?
    private var warmEngineId: String?
    private var warmClipTask: Task<Void, Never>?
    private var protectedIds: Set<String> = []
    private var selfTestUsers = 0
    private var idleTask: Task<Void, Never>?
    private var idleEngine: (any SpeechEngine)?
    private var lastUsedAt: Double = 0

    init(warmupClip: URL?) {
        self.warmupClip = warmupClip
    }

    private var isBusy: Bool { host?.isBusy ?? false }

    func protect(_ engine: any SpeechEngine) {
        protectedIds.insert(engine.id)
    }

    func releaseProtection() {
        protectedIds.removeAll()
    }

    // Returns the load alone, which is all a commit awaits. The warm-up clip follows it but is skipped once
    // a commit is under way: it would only queue a full inference ahead of the user's own on the engine lock.
    @discardableResult
    func warm(_ engine: any SpeechEngine) -> Task<Void, Error> {
        if warmEngineId == engine.id, let task = warmTask { return task }
        let load = Task { try await engine.loadIfNeeded() }
        warmEngineId = engine.id
        warmTask = load
        warmClipTask?.cancel()
        warmClipTask = nil
        if let clip = warmupClip, engine.benefitsFromWarmupClip, let host {
            let biasTerms = Self.warmupBiasTerms(settings: host.engineSettings, engine: engine, plan: host.warmupPlan)
            // Cancelled with the warm it belongs to: a clip that outlives an eviction would reload the model.
            warmClipTask = Task { @MainActor [weak self] in
                guard (try? await load.value) != nil, !Task.isCancelled,
                      let host = self?.host, !host.isBusy || host.isCapturingAudio else { return }
                _ = try? await engine.transcribe(wavURL: clip, biasTerms: biasTerms)
            }
        }
        return load
    }

    static func warmupBiasTerms(settings: Settings, engine: any SpeechEngine, plan: ResolvedConfig) -> [String] {
        guard settings.stt.recognitionBiasEnabled(
            engineId: engine.id, supportsRecognitionBias: engine.supportsRecognitionBias) else { return [] }
        return plan.recognitionBiasTerms(for: nil)
    }

    func invalidateWarm(_ engineId: String) {
        guard warmEngineId == engineId else { return }
        warmTask = nil
        warmEngineId = nil
        warmClipTask?.cancel()
        warmClipTask = nil
    }

    func evictSwitchedAway(_ engine: any SpeechEngine) {
        guard !protectedIds.contains(engine.id) else {
            host?.whenIdle { [weak self] in
                guard let self else { return }
                self.invalidateWarm(engine.id)
                Task { await engine.evict() }
            }
            return
        }
        invalidateWarm(engine.id)
        Task { await engine.evict() }
    }

    func evictForSettings(_ engine: any SpeechEngine) async {
        guard !protectedIds.contains(engine.id) else {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                guard let host else { cont.resume(); return }
                host.whenIdle { [weak self] in
                    guard let self else { cont.resume(); return }
                    self.invalidateWarm(engine.id)
                    Task {
                        await engine.evict()
                        cont.resume()
                    }
                }
            }
            return
        }
        invalidateWarm(engine.id)
        await engine.evict()
    }

    func evictUnderMemoryPressure(_ engine: any SpeechEngine) {
        invalidateWarm(engine.id)
        Task { await engine.evict() }
    }

    func selfTest(_ engine: any SpeechEngine, gate: SingleFlightDeadline) async -> Bool? {
        let clip = selfTestClipOverride ?? ModelSelfTestRunner.clipURL
        selfTestUsers += 1
        let result = await ModelSelfTestRunner.verify(engine, clipURL: clip) { url, biasTerms in
            do {
                return try await gate.run(seconds: Self.selfTestTimeoutSeconds) {
                    try await engine.transcribe(wavURL: url, biasTerms: biasTerms)
                }
            } catch is SingleFlightDeadline.Busy {
                throw ModelSelfTestRunner.Skipped()
            }
        }
        if result != nil {
            for _ in 0..<Self.selfTestClearancePolls where await gate.isBusy {
                try? await Task.sleep(for: .milliseconds(Self.selfTestSettlePollMs))
            }
        }
        selfTestUsers -= 1
        return result
    }

    enum Listening: Equatable { case heard(String, checker: String), busy, cancelled, unavailable }

    var checkTimeout = EngineKeeper.selfTestTimeoutSeconds
    private var checkGate: SingleFlightDeadline?

    func listen(_ engine: any SpeechEngine, wav: URL, gate: SingleFlightDeadline) async -> Listening {
        guard !isBusy else { return .busy }
        do { try await warm(engine).value } catch { return .unavailable }
        guard !isBusy else { return .busy }
        let earlier = checkGate
        checkGate = gate
        defer { if !isBusy { applyEvictionAfterDictation(engine: engine) } }
        do {
            let heard = try await gate.run(seconds: checkTimeout) { try await engine.transcribe(wavURL: wav, biasTerms: []) }
            if checkGate === gate { checkGate = nil }
            return .heard(heard, checker: engine.id)
        } catch is SingleFlightDeadline.Busy {
            checkGate = earlier
            return .busy
        } catch {
            releaseCheckGateWhenSettled(gate)
            return Task.isCancelled ? .cancelled : .unavailable
        }
    }

    private func releaseCheckGateWhenSettled(_ gate: SingleFlightDeadline) {
        Task { @MainActor [weak self] in
            while await gate.isBusy { try? await Task.sleep(for: .milliseconds(Self.selfTestSettlePollMs)) }
            if self?.checkGate === gate { self?.checkGate = nil }
        }
    }

    func checkHolds(_ gate: SingleFlightDeadline) async -> Bool {
        guard checkGate === gate else { return false }
        return await gate.isBusy
    }

    // A check's transcription can outlive its deadline or a cancellation the engine ignores, and the gate stays
    // closed until it really returns. A commit waits for that with no limit of its own: the engine is serialized,
    // so nothing could transcribe sooner, and the recording is kept until the user cancels.
    func awaitSelfTestClearance(on gate: SingleFlightDeadline) async {
        for _ in 0..<Self.selfTestClearancePolls where selfTestUsers > 0 {
            try? await Task.sleep(for: .milliseconds(Self.selfTestSettlePollMs))
        }
        while !Task.isCancelled, checkGate === gate, await gate.isBusy {
            try? await Task.sleep(for: .milliseconds(Self.selfTestSettlePollMs))
        }
    }

    func preload(_ engine: any SpeechEngine) {
        guard let host, EvictionPolicy.shouldPreloadModel(mode: host.engineSettings.stt.eviction) else { return }
        let load = warm(engine)
        // The tier and the active engine are read after the load: either can change while it runs, and a
        // superseded preload must not replace the current engine's idle eviction.
        Task { @MainActor [weak self] in
            guard (try? await load.value) != nil, let self, let host = self.host, !host.isBusy,
                  self.warmTask == load, host.activeProviderEngine.id == engine.id else { return }
            self.applyEvictionAfterDictation(engine: engine)
        }
    }

    // Evicts the engine the dictation actually used (the captured one), not whatever is active now —
    // a mid-dictation switch leaves provider.active pointing at a different, unloaded engine.
    func applyEvictionAfterDictation(engine: any SpeechEngine) {
        guard let host else { return }
        lastUsedAt = ProcessInfo.processInfo.systemUptime
        let settings = host.engineSettings
        let idle = settings.stt.evictionIdleSeconds.map(Double.init)
        switch EvictionPolicy.afterDictation(mode: settings.stt.eviction, idleSeconds: idle) {
        case .keepLoaded: break
        case .evictNow:
            invalidateWarm(engine.id)
            Task { await engine.evict() }
            // Frugal (the only tier that evicts immediately) opens the mic only while dictating, so dispose
            // the warm capture unit the commit path left stopped-but-realized — including when the user
            // switched to Frugal mid-dictation, where reconcileCaptureWarmth deferred to this terminal.
            host.releaseWarmCapture()
        case .scheduleIdleCheck(let after): scheduleIdleEviction(after: after, engine: engine)
        }
    }

    func cancelIdleEviction() {
        idleTask?.cancel()
    }

    func rescheduleIdleEviction() {
        guard !isBusy, let engine = idleEngine else { return }
        scheduleIdleEviction(after: 0, engine: engine)
    }

    private func scheduleIdleEviction(after: Double, engine active: any SpeechEngine) {
        guard let host else { return }
        idleTask?.cancel()
        idleEngine = active
        let mode = host.engineSettings.stt.eviction
        let idle = host.engineSettings.stt.evictionIdleSeconds.map(Double.init)
        let usedAt = lastUsedAt
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard let self, !Task.isCancelled, !self.isBusy else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch EvictionPolicy.onIdleCheck(mode: mode, lastUsedAt: usedAt, now: now, idleSeconds: idle) {
            case .evictNow:
                self.invalidateWarm(active.id)
                await active.evict()
                // Only Fastest holds the mic warm, and it never reaches evictNow — so any idle eviction
                // (Balanced past its window, or a tier switched to Frugal) also disposes the warm unit.
                self.host?.releaseWarmCapture()
                self.idleEngine = nil
            case .scheduleIdleCheck(let again): self.scheduleIdleEviction(after: again, engine: active)
            case .keepLoaded: self.idleEngine = nil
            }
        }
    }
}
