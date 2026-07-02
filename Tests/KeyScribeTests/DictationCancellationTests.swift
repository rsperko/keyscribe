import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// One-shot coordination: one side waits, the other fires; safe across actor hops.
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

// STT engine whose transcribe() blocks on a gate, so a test can cancel mid-transcription.
private final class GatedEngine: SpeechEngine, @unchecked Sendable {
    let id = "gated"
    let displayName = "Gated"
    let supportsRecognitionBias = true
    private let started: Signal
    private let release: Signal
    private let text: String

    init(started: Signal, release: Signal, text: String) {
        self.started = started
        self.release = release
        self.text = text
    }

    func loadIfNeeded() async throws {}
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        started.fire()
        await release.wait()
        return text
    }
    func evict() async {}
}

// Like GatedEngine but throws after the gate — simulates an engine that observes cancellation by
// throwing (CancellationError), the path that must not run finishError against the next dictation.
private final class ThrowAfterReleaseEngine: SpeechEngine, @unchecked Sendable {
    let id = "throwing"
    let displayName = "Throwing"
    let supportsRecognitionBias = true
    struct Boom: Error {}
    private let started: Signal
    private let release: Signal
    init(started: Signal, release: Signal) { self.started = started; self.release = release }
    func loadIfNeeded() async throws {}
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        started.fire()
        await release.wait()
        throw Boom()
    }
    func evict() async {}
}

// Throws on transcribe and fires a signal when evicted — proves an error terminal still releases the
// model on Frugal/Balanced instead of pinning it resident (W14 §2.1).
private final class EvictRecordingEngine: SpeechEngine, @unchecked Sendable {
    let id = "evicting"
    let displayName = "Evicting"
    let supportsRecognitionBias = true
    struct Boom: Error {}
    private let started: Signal
    private let release: Signal
    let evicted = Signal()
    init(started: Signal, release: Signal) { self.started = started; self.release = release }
    func loadIfNeeded() async throws {}
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        started.fire()
        await release.wait()
        throw Boom()
    }
    func evict() async { evicted.fire() }
}

// Returns immediately with a fixed text — stands in for a second, different engine.
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

private final class LoadCountingEngine: SpeechEngine, @unchecked Sendable {
    let id = "missing"
    let displayName = "Missing"
    let supportsRecognitionBias = true
    private let lock = NSLock()
    private var _loads = 0
    var loads: Int { lock.lock(); defer { lock.unlock() }; return _loads }
    func loadIfNeeded() async throws { lock.withLock { _loads += 1 } }
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "unexpected" }
    func evict() async {}
}

private final class FakeAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var _starts = 0
    var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }
    init(url: URL) { self.url = url }
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL {
        lock.withLock { _starts += 1 }
        return url
    }
    func stop() -> URL? { url }
}

// Records whether the commit path drained the tail (finishDraining) or tore down immediately (stop).
private final class DrainTrackingAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var _drained = false
    private var _immediateStops = 0
    var drained: Bool { lock.lock(); defer { lock.unlock() }; return _drained }
    var immediateStops: Int { lock.lock(); defer { lock.unlock() }; return _immediateStops }
    init(url: URL) { self.url = url }
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL { url }
    func stop() -> URL? { lock.lock(); _immediateStops += 1; lock.unlock(); return url }
    func finishDraining() async -> URL? { markDrained(); return url }
    private func markDrained() { lock.lock(); _drained = true; lock.unlock() }
}

// start() that resolves only after a delay — stands in for a bring-up that lands late (a resident engine
// re-realizing a stale binding on the hot path). AudioCapture's own grace window adopts it internally;
// the controller must also impose no competing deadline and adopt whatever start() eventually returns.
private final class SlowStartAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    private let delay: Duration
    init(url: URL, delay: Duration) { self.url = url; self.delay = delay }
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL {
        try? await Task.sleep(for: delay)
        return url
    }
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
struct DictationCancellationTests {
    private struct Harness {
        let controller: DictationController
        let history: HistoryStore
        let insertSpy: InsertSpy
        let started: Signal
        let release: Signal
        let supportDir: URL
        let hud: HUDSpy
    }

    private func makeHarness(
        micStatus: @escaping @MainActor () -> PermissionStatus = { .granted },
        accessibilityGranted: @escaping @MainActor () -> Bool = { true }
    ) -> Harness {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let started = Signal()
        let release = Signal()
        let insertSpy = InsertSpy()
        let engine = GatedEngine(started: started, release: release, text: "hello world")
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "gated")

        var settings = Settings.defaults
        settings.stt = .init(engine: "gated", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let history = HistoryStore(supportDir: supportDir)
        let hud = HUDSpy()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: hud,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: micStatus,
            accessibilityGranted: accessibilityGranted)

        return Harness(
            controller: controller, history: history, insertSpy: insertSpy,
            started: started, release: release, supportDir: supportDir, hud: hud)
    }

    private func enableSeedMode(_ id: String, in supportDir: URL) throws {
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        var mode = try #require(ModeStore.loadAll(in: modesDir).first { $0.id == id })
        mode.enabled = true
        try ModeStore.write(mode, to: modesDir)
    }

    @Test func unavailableActiveModelDoesNotLoadOrStartCapture() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let engine = LoadCountingEngine()
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "missing")
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        var settings = Settings.defaults
        settings.stt = .init(engine: "missing", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let hud = HUDSpy()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud, audio: audio,
            insert: { _, _, _, _ in return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true },
            activeEngineUsable: { _ in false })

        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(engine.loads == 0)
        #expect(audio.starts == 0)
        #expect(hud.states.last == .error(message: "The selected speech model is not installed", action: nil))
    }

    @Test func commitDrainsTheTailInsteadOfStoppingImmediately() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let started = Signal(), release = Signal()
        let engine = GatedEngine(started: started, release: release, text: "hello world")
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "gated")
        let insertSpy = InsertSpy()
        let audio = DrainTrackingAudio(url: supportDir.appendingPathComponent("capture.wav"))
        var settings = Settings.defaults
        settings.stt = .init(engine: "gated", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: HUDSpy(), audio: audio,
            insert: { _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await started.wait()
        release.fire()
        await controller.dictationTask?.value

        #expect(audio.drained)
        #expect(audio.immediateStops == 0)
        #expect(await insertSpy.calls == 1)
    }

    // Fix 2, controller side: a bring-up that lands late must be ADOPTED — the dictation reaches live
    // recording and inserts — not pre-empted by any controller-side timeout. Guards against a future
    // controller watchdog that would fail a slow-but-successful start.
    @Test func aSlowButSuccessfulBringUpIsAdoptedAndRecords() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let started = Signal(), release = Signal()
        let engine = GatedEngine(started: started, release: release, text: "hello world")
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "gated")
        let insertSpy = InsertSpy()
        let hud = HUDSpy()
        let history = HistoryStore(supportDir: supportDir)
        let audio = SlowStartAudio(url: supportDir.appendingPathComponent("capture.wav"), delay: .milliseconds(300))
        var settings = Settings.defaults
        settings.stt = .init(engine: "gated", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: hud, audio: audio,
            insert: { _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
        await controller.captureBringUpTask?.value   // waits out the late bring-up
        controller.handleCommit()
        await started.wait()
        release.fire()
        await controller.dictationTask?.value

        #expect(await insertSpy.calls == 1)
        #expect(controller.lastResult == "hello world")
        #expect(hud.states.contains { if case .recording = $0 { true } else { false } })
        #expect(!hud.states.contains { if case .error = $0 { true } else { false } })
    }

    @Test func cancellingDuringTranscriptionInsertsNothingAndWritesNoHistory() async {
        let h = makeHarness()
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        await h.started.wait()                 // engine is suspended mid-transcribe
        let task = h.controller.dictationTask  // capture before cancel() clears it
        h.controller.cancel()
        h.release.fire()                        // engine returns; the guard must bail
        await task?.value

        #expect(await h.insertSpy.calls == 0)
        #expect(h.history.entries().isEmpty)
        #expect(h.controller.lastResult == nil)
    }

    @Test func cancellingThenAnEngineThatThrowsDoesNotStompTheHUD() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let started = Signal(), release = Signal()
        let engine = ThrowAfterReleaseEngine(started: started, release: release)
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "throwing")
        let insertSpy = InsertSpy()
        let hud = HUDSpy()
        let history = HistoryStore(supportDir: supportDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "throwing", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: hud,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await started.wait()
        let task = controller.dictationTask
        controller.cancel()        // renders .hidden; the late throw must not render .error
        release.fire()             // engine throws after cancellation
        await task?.value

        #expect(await insertSpy.calls == 0)
        #expect(history.entries().isEmpty)
        #expect(controller.lastResult == nil)
        #expect(hud.states.last == .hidden)
    }

    // W14 §2.1: a dictation that fails in transcribe must still release the model on Frugal — otherwise
    // the model stays resident until quit because no other terminal re-arms eviction.
    @Test func aFailedTranscribeStillEvictsOnFrugal() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let started = Signal(), release = Signal()
        let engine = EvictRecordingEngine(started: started, release: release)
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "evicting")
        var settings = Settings.defaults
        settings.stt = .init(engine: "evicting", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: HUDSpy(),
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _ in return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await started.wait()
        release.fire()            // engine throws → finishError terminal
        await controller.dictationTask?.value

        let didEvict = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await engine.evicted.wait(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(didEvict)
    }

    @Test func aMidDictationEngineSwitchStillUsesTheCapturedEngine() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let started = Signal(), release = Signal()
        let engineA = GatedEngine(started: started, release: release, text: "from engine A")
        let engineB = InstantEngine(id: "engine-b", text: "from engine B")
        let provider = try! SpeechEngineProvider(engines: [engineA, engineB], activeId: "gated")
        let insertSpy = InsertSpy()
        var settings = Settings.defaults
        settings.stt = .init(engine: "gated", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: HUDSpy(),
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await started.wait()
        let task = controller.dictationTask
        try? provider.setActive("engine-b")   // user switches engine mid-transcription
        release.fire()
        await task?.value

        #expect(controller.lastResult == "from engine A")
    }

    @Test func completingNormallyInsertsAndRecordsHistory() async {
        let h = makeHarness()
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        await h.started.wait()
        let task = h.controller.dictationTask
        h.release.fire()
        await task?.value

        #expect(await h.insertSpy.calls == 1)
        #expect(h.controller.lastResult == "hello world")
        #expect(h.history.entries().count == 1)
    }

    @Test func cancellingDuringRecordingDeletesTheCaptureFile() async {
        let h = makeHarness()
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        let captureURL = h.supportDir.appendingPathComponent("capture.wav")
        FileManager.default.createFile(atPath: captureURL.path, contents: Data("pcm".utf8))

        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.cancel()

        #expect(!FileManager.default.fileExists(atPath: captureURL.path))
    }

    @Test func oneShotModeOverridesTheNextRecordingOnly() async throws {
        let h = makeHarness()
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        try enableSeedMode("edit-selection", in: h.supportDir)

        h.controller.setNextModeOverride(id: "edit-selection")
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value   // the .recording HUD lands once the mic is live

        #expect(h.hud.states.last == .recording(mode: "Edit Selection", level: 0))
        #expect(h.controller.nextModeOverrideName == nil)
    }

    @Test func keyPressInAWrongAppFallsThroughToDirect() async throws {
        let h = makeHarness()
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        // A mode bound to right_option but constrained to Slack; the harness frontmost app is
        // "test.bundle", so the press is out of context and must fall through to the Direct floor.
        var slack = Mode(id: "slacky", name: "Slacky")
        slack.triggerKeys = [Mode.TriggerKey(key: "right_option")]
        slack.constraints = [Mode.Constraint(bundleId: "com.tinyspeck.slackmacgap")]
        try ModeStore.write(slack, to: h.supportDir.appendingPathComponent("modes", isDirectory: true))

        h.controller.handleStart(triggerKey: "right_option")
        await h.controller.captureBringUpTask?.value
        #expect(h.hud.states.last == .recording(mode: "Plain Dictation", level: 0))

        h.controller.handleCommit()
        await h.started.wait()
        let task = h.controller.dictationTask
        h.release.fire()
        await task?.value

        #expect(h.controller.lastResult == "hello world")   // it dictated via the Direct floor
        // The Direct floor records per the global History setting now (it's the everyday floor, not a
        // silent fallback), so the dictation lands in history under its display name.
        #expect(h.history.entries().map(\.modeName) == ["Plain Dictation"])
    }

    @Test func deniedMicrophoneSurfacesAnErrorWithSettingsActionInsteadOfRecordingSilence() {
        let h = makeHarness(micStatus: { .denied })
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        h.controller.handleStart()

        #expect(h.hud.states.last == .error(message: "Microphone access is off", action: .openMicrophoneSettings))
        #expect(h.controller.dictationTask == nil)
    }

    @Test func withoutAccessibilityDictationIsCopiedTruthfullyNotPhantomInserted() async {
        let h = makeHarness(accessibilityGranted: { false })
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        await h.started.wait()
        let task = h.controller.dictationTask
        h.release.fire()
        await task?.value

        #expect(h.controller.lastResult == "hello world")
        #expect(h.history.entries().first?.outcome == .copied)
        let completeOutcomes = h.hud.states.compactMap { state -> DictationOutcome? in
            if case .complete(let outcome, _) = state { return outcome }
            return nil
        }
        #expect(completeOutcomes.contains(.copied(.accessibilityDenied)))
    }

    @Test func selectionModeWithoutAccessibilityNamesTheRealCauseNotMissingSelection() async throws {
        let h = makeHarness(accessibilityGranted: { false })
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        try enableSeedMode("edit-selection", in: h.supportDir)

        h.controller.setNextModeOverride(id: "edit-selection")
        h.controller.handleStart()
        await h.controller.captureBringUpTask?.value
        h.controller.handleCommit()
        await h.started.wait()
        let task = h.controller.dictationTask
        h.release.fire()
        await task?.value

        #expect(await h.insertSpy.calls == 0)
        #expect(h.hud.states.last == .error(
            message: "Accessibility is off — KeyScribe can't read the selected text.",
            action: .openAccessibilitySettings))
    }

    @Test func rewriteHUDNamesTheActualSharedContext() {
        let state = HUDState.rewriting(
            connection: "Gemini", mode: "Email", redacted: false, contextCategories: ["app", "preceding text"],
            offerLocalTranscript: false)
        #expect(state.secondaryText == "Rewriting with Gemini")
        #expect(state.dataBoundaryBadges == ["Cloud rewrite", "App shared", "Preceding text shared"])
    }
}

// Bring-up that never succeeds — stands in for a wedged/failed device whose watchdog fired.
private final class ThrowingStartAudio: AudioCapturing, @unchecked Sendable {
    struct Boom: Error {}
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL { throw Boom() }
    func stop() -> URL? { nil }
}

// Bring-up failing with formatUnavailable (no usable input stream).
private final class NoInputDeviceAudio: AudioCapturing, @unchecked Sendable {
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL {
        throw AudioCaptureError.formatUnavailable
    }
    func stop() -> URL? { nil }
}

private final class PreferredInputFailedAudio: AudioCapturing, @unchecked Sendable {
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL {
        throw AudioCaptureError.preferredInputFailed
    }
    func stop() -> URL? { nil }
}

// Bring-up that blocks until released — models a commit arriving while the mic is still coming up.
private final class GatedStartAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    private let gate: Signal
    private let lock = NSLock()
    private var _stopCalls = 0
    var stopCalls: Int { lock.withLock { _stopCalls } }
    init(url: URL, gate: Signal) { self.url = url; self.gate = gate }
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL {
        await gate.wait()
        return url
    }
    func stop() -> URL? {
        lock.withLock { _stopCalls += 1 }
        return url
    }
}

private final class CountingGatedStartAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    private let gate: Signal
    private let started = Signal()
    private let lock = NSLock()
    private var _startCalls = 0
    private var _stopCalls = 0
    var startCalls: Int { lock.withLock { _startCalls } }
    var stopCalls: Int { lock.withLock { _stopCalls } }

    init(url: URL, gate: Signal) {
        self.url = url
        self.gate = gate
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL {
        lock.withLock { _startCalls += 1 }
        started.fire()
        await gate.wait()
        return url
    }

    func stop() -> URL? {
        lock.withLock { _stopCalls += 1 }
        return url
    }
}

@MainActor
struct DictationCaptureStartTests {
    private func makeController(
        audio: AudioCapturing, hud: HUDPresenting, insertSpy: InsertSpy, supportDir: URL,
        configureSettings: (inout Settings) -> Void = { _ in }
    ) -> DictationController {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        ModeStore.seedStartersIfEmpty(in: supportDir.appendingPathComponent("modes", isDirectory: true))
        let provider = try! SpeechEngineProvider(
            engines: [InstantEngine(id: "instant", text: "hello world")], activeId: "instant")
        var settings = Settings.defaults
        settings.stt = .init(engine: "instant", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        configureSettings(&settings)
        return DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud, audio: audio,
            insert: { _, _, _, _ in await insertSpy.record(); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
    }

    @Test func bringUpFailureSurfacesAsMicErrorAndStaysResponsive() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let hud = HUDSpy()
        let controller = makeController(
            audio: ThrowingStartAudio(), hud: hud, insertSpy: InsertSpy(), supportDir: supportDir)

        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(controller.isBusy == false)
        #expect(hud.states.last == .error(
            message: "Could not start the microphone", action: .openMicrophoneSettings))
    }

    @Test func noUsableInputSurfacesADistinctErrorWithoutAMicSettingsAction() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let hud = HUDSpy()
        let controller = makeController(
            audio: NoInputDeviceAudio(), hud: hud, insertSpy: InsertSpy(), supportDir: supportDir)

        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(controller.isBusy == false)
        #expect(hud.states.last == .error(message: "No microphone is available", action: nil))
    }

    @Test func preferredInputFailureNamesTheSelectedMicrophone() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let hud = HUDSpy()
        let controller = makeController(
            audio: PreferredInputFailedAudio(), hud: hud, insertSpy: InsertSpy(), supportDir: supportDir
        ) { settings in
            settings.audio = .init(inputDeviceUID: "BuiltInMic", inputDeviceName: "MacBook Pro Microphone")
        }

        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(controller.isBusy == false)
        #expect(hud.states.last == .error(
            message: "Could not start MacBook Pro Microphone", action: .openMicrophoneSettings))
    }

    @Test func commitDuringBringUpCancelsThePendingCapture() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let gate = Signal()
        let insertSpy = InsertSpy()
        let audio = GatedStartAudio(url: supportDir.appendingPathComponent("capture.wav"), gate: gate)
        let controller = makeController(
            audio: audio, hud: HUDSpy(), insertSpy: insertSpy, supportDir: supportDir)

        controller.handleStart()
        let bringUpTask = controller.captureBringUpTask
        controller.handleCommit()
        #expect(controller.isBusy)
        gate.fire()
        await bringUpTask?.value
        await controller.dictationTask?.value

        #expect(await insertSpy.calls == 0)
        #expect(controller.lastResult == nil)
        #expect(audio.stopCalls == 1)
        #expect(controller.isBusy == false)
    }

    @Test func startShowsCancellableArmingBeforeCaptureIsLive() {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let hud = HUDSpy()
        let audio = GatedStartAudio(url: supportDir.appendingPathComponent("capture.wav"), gate: Signal())
        let controller = makeController(
            audio: audio, hud: hud, insertSpy: InsertSpy(), supportDir: supportDir)

        controller.handleStart()

        // No key, nothing matches → the Direct floor (shown as "Plain Dictation").
        #expect(hud.states.last == .arming(mode: "Plain Dictation"))
        #expect(controller.isCancellable)
    }

    @Test func startDuringCanceledBringUpIsIgnoredUntilCleanupFinishes() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let gate = Signal()
        let audio = CountingGatedStartAudio(url: supportDir.appendingPathComponent("capture.wav"), gate: gate)
        let controller = makeController(
            audio: audio, hud: HUDSpy(), insertSpy: InsertSpy(), supportDir: supportDir)

        controller.handleStart()
        await audio.waitUntilStarted()
        let bringUpTask = controller.captureBringUpTask
        controller.handleCommit()
        controller.handleStart()
        #expect(audio.startCalls == 1)
        gate.fire()
        await bringUpTask?.value
        controller.handleStart()
        await controller.captureBringUpTask?.value

        #expect(audio.startCalls == 2)
        #expect(audio.stopCalls == 1)
    }
}
