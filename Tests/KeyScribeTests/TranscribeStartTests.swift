import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct TranscribeStartTests {
    private struct EngineFailed: Error {}

    private final class CountingEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias: Bool
        let fails: Bool
        private let lock = NSLock()
        private var calls = 0
        private var loadHeld: Bool
        private var heldLoads: [CheckedContinuation<Void, Never>] = []
        init(supportsRecognitionBias: Bool, fails: Bool, holdsLoad: Bool = false) {
            self.supportsRecognitionBias = supportsRecognitionBias
            self.fails = fails
            self.loadHeld = holdsLoad
        }
        var transcribed: Int { lock.withLock { calls } }
        func loadIfNeeded() async throws {
            await withCheckedContinuation { continuation in
                let wait = lock.withLock { () -> Bool in
                    if loadHeld { heldLoads.append(continuation) }
                    return loadHeld
                }
                if !wait { continuation.resume() }
            }
        }
        func releaseLoad() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                loadHeld = false
                defer { heldLoads = [] }
                return heldLoads
            }
            waiting.forEach { $0.resume() }
        }
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            lock.withLock { calls += 1 }
            if fails { throw EngineFailed() }
            return "hello there"
        }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    @MainActor private final class HeldAdoption {
        private(set) var isHeld = false
        private var first = true
        private var held: CheckedContinuation<Void, Never>?

        func snapshot() async -> TargetSnapshot {
            if first {
                first = false
                isHeld = true
                await withCheckedContinuation { held = $0 }
                isHeld = false
            }
            return TargetSnapshot(bundleId: "test.bundle", pid: 100)
        }

        func release() {
            held?.resume()
            held = nil
        }
    }

    private final class Inserted: @unchecked Sendable {
        var texts: [String] = []
    }

    private struct Outcome {
        var transcribedWhileHeld = 0
        var busyWhileHeld = false
        var inserted: [String] = []
        var busyAfter = true
        var historyFiles: [String] = []
    }

    private func run(
        biasCapable: Bool, biasDisabled: Bool = false, fails: Bool = false, modes: [Mode] = [],
        triggerKey: String? = nil
    ) async throws -> Outcome {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-transcribe-start-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        for mode in modes { try ModeStore.write(mode, to: modesDir) }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        if biasDisabled { settings.stt.recognitionBiasDisabledEngines = ["fixed"] }
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let adoption = HeldAdoption()
        let inserted = Inserted()
        let engine = CountingEngine(supportsRecognitionBias: biasCapable, fails: fails)
        let provider = try SpeechEngineProvider(engines: [engine], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil, permits: { _ in true },
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, text, _ in inserted.texts.append(text); return true },
            pressSnapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 100) },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 100) },
            snapshotAsync: { await adoption.snapshot() },
            micStatus: { .granted },
            accessibilityGranted: { true })

        controller.handleStart(triggerKey: triggerKey)
        await controller.captureBringUpTask?.value
        for _ in 0..<50 where !adoption.isHeld { await Task.yield() }
        try #require(adoption.isHeld)
        controller.handleCommit()
        for _ in 0..<50 where engine.transcribed == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        var outcome = Outcome()
        outcome.transcribedWhileHeld = engine.transcribed
        outcome.busyWhileHeld = controller.isBusy
        #expect(adoption.isHeld)
        adoption.release()
        await controller.dictationTask?.value
        outcome.inserted = inserted.texts.map { $0.trimmingCharacters(in: .whitespaces) }
        outcome.busyAfter = controller.isBusy
        let historyDir = supportDir.appendingPathComponent("history", isDirectory: true)
        outcome.historyFiles = (try? FileManager.default.contentsOfDirectory(atPath: historyDir.path)) ?? []
        return outcome
    }

    @Test func withoutRecognitionBiasTranscriptionStartsBeforeTheTargetIsConfirmed() async throws {
        let outcome = try await run(biasCapable: false)
        #expect(outcome.transcribedWhileHeld == 1)
        #expect(outcome.inserted == ["hello there"])
    }

    @Test func anEngineWhoseBiasIsTurnedOffAlsoStartsEarly() async throws {
        let outcome = try await run(biasCapable: true, biasDisabled: true)
        #expect(outcome.transcribedWhileHeld == 1)
        #expect(outcome.inserted == ["hello there"])
    }

    @Test func withRecognitionBiasTranscriptionWaitsForTheMode() async throws {
        let outcome = try await run(biasCapable: true)
        #expect(outcome.transcribedWhileHeld == 0)
        #expect(outcome.inserted == ["hello there"])
    }

    @Test func aFailedTranscriptionStillWaitsForTheModeBeforeItFinishes() async throws {
        let outcome = try await run(biasCapable: false, fails: true)
        #expect(outcome.transcribedWhileHeld == 1)
        #expect(outcome.busyWhileHeld)
        #expect(!outcome.busyAfter)
        #expect(outcome.inserted.isEmpty)
    }

    @Test func aPressThatTurnsOutUnclaimedAfterTranscriptionStartedInsertsNothing() async throws {
        var email = Mode(id: "email", name: "Email")
        email.triggerKeys = [.init(key: "fn")]
        email.constraints = [Mode.Constraint(bundleId: nil, urlPattern: #"mail\.google\.com"#)]
        var direct = Mode.direct
        direct.triggerKeys = [.init(key: "right_option")]
        let outcome = try await run(biasCapable: false, modes: [email, direct], triggerKey: "fn")
        #expect(outcome.transcribedWhileHeld == 1)
        #expect(outcome.inserted.isEmpty)
        #expect(!outcome.busyAfter)
        #expect(outcome.historyFiles.isEmpty)
    }

    private final class HUDRecorder: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private func modesResolvingLateTo(_ name: String) -> [Mode] {
        var email = Mode(id: "email", name: "Email")
        email.triggerKeys = [.init(key: "fn")]
        email.constraints = [Mode.Constraint(bundleId: nil, urlPattern: #"mail\.google\.com"#)]
        var notes = Mode(id: "notes", name: name)
        notes.triggerKeys = [.init(key: "fn")]
        var direct = Mode.direct
        direct.triggerKeys = [.init(key: "right_option")]
        return [email, notes, direct]
    }

    private func lateResolution(releaseDuringLoad: Bool) async throws -> [HUDState] {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-late-mode-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        for mode in modesResolvingLateTo("Meeting Notes") { try ModeStore.write(mode, to: modesDir) }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let adoption = HeldAdoption()
        let hud = HUDRecorder()
        let engine = CountingEngine(supportsRecognitionBias: false, fails: false, holdsLoad: releaseDuringLoad)
        let controller = DictationController(
            settings: settings, provider: try SpeechEngineProvider(engines: [engine], activeId: "fixed"),
            config: ConfigCache(supportDir: supportDir), history: HistoryStore(supportDir: supportDir), hud: hud,
            permits: { _ in true }, audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            pressSnapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 100) },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 100) },
            snapshotAsync: { await adoption.snapshot() },
            micStatus: { .granted },
            accessibilityGranted: { true })
        controller.loadingModelHUDDelayOverride = .milliseconds(20)

        controller.handleStart(triggerKey: "fn")
        await controller.captureBringUpTask?.value
        for _ in 0..<50 where !adoption.isHeld { await Task.yield() }
        try #require(adoption.isHeld)
        controller.handleCommit()
        if releaseDuringLoad {
            let loading = HUDState.loadingModel(mode: DictationController.fallbackModeName)
            for _ in 0..<500 where !hud.states.contains(loading) { try await Task.sleep(for: .milliseconds(10)) }
            try #require(hud.states.contains(loading))
        } else {
            for _ in 0..<500 where engine.transcribed == 0 { try await Task.sleep(for: .milliseconds(10)) }
            try #require(engine.transcribed == 1)
        }
        #expect(!hud.states.contains { "\($0)".contains("Meeting Notes") })
        adoption.release()
        if releaseDuringLoad {
            let renamed = HUDState.loadingModel(mode: "Meeting Notes")
            for _ in 0..<500 where !hud.states.contains(renamed) { try await Task.sleep(for: .milliseconds(10)) }
            #expect(engine.transcribed == 0)
            engine.releaseLoad()
        }
        await controller.dictationTask?.value
        return hud.states
    }

    @Test func aModeResolvedAfterTranscriptionRenamesTheTranscribingCard() async throws {
        let states = try await lateResolution(releaseDuringLoad: false)
        #expect(states.contains(.transcribing(mode: "Meeting Notes")))
    }

    @Test func aModeResolvedDuringASlowLoadRenamesTheLoadingCard() async throws {
        let states = try await lateResolution(releaseDuringLoad: true)
        #expect(states.contains(.loadingModel(mode: "Meeting Notes")))
    }
}
