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

private final class FakeAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    init(url: URL) { self.url = url }
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL { url }
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
            insert: { _, _, _ in await insertSpy.record() },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: micStatus,
            accessibilityGranted: accessibilityGranted)

        return Harness(
            controller: controller, history: history, insertSpy: insertSpy,
            started: started, release: release, supportDir: supportDir, hud: hud)
    }

    @Test func cancellingDuringTranscriptionInsertsNothingAndWritesNoHistory() async {
        let h = makeHarness()
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        h.controller.handleStart()
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
            insert: { _, _, _ in await insertSpy.record() },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
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
            insert: { _, _, _ in await insertSpy.record() },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
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
        h.controller.handleCommit()
        await h.started.wait()
        let task = h.controller.dictationTask
        h.release.fire()
        await task?.value

        #expect(await h.insertSpy.calls == 1)
        #expect(h.controller.lastResult == "hello world")
        #expect(h.history.entries().count == 1)
    }

    @Test func cancellingDuringRecordingDeletesTheCaptureFile() {
        let h = makeHarness()
        defer { try? FileManager.default.removeItem(at: h.supportDir) }
        let captureURL = h.supportDir.appendingPathComponent("capture.wav")
        FileManager.default.createFile(atPath: captureURL.path, contents: Data("pcm".utf8))

        h.controller.handleStart()      // recording; the capture file is live on disk
        h.controller.cancel()           // cancel before commit — nothing else will clean it up

        #expect(!FileManager.default.fileExists(atPath: captureURL.path))
    }

    @Test func oneShotModeOverridesTheNextRecordingOnly() {
        let h = makeHarness()
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        h.controller.setNextModeOverride(id: "work-on-selection")
        h.controller.handleStart()

        #expect(h.hud.states.last == .recording(mode: "Work on Selection", level: 0))
        #expect(h.controller.nextModeOverrideName == nil)
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

    @Test func selectionModeWithoutAccessibilityNamesTheRealCauseNotMissingSelection() async {
        let h = makeHarness(accessibilityGranted: { false })
        defer { try? FileManager.default.removeItem(at: h.supportDir) }

        h.controller.setNextModeOverride(id: "work-on-selection")
        h.controller.handleStart()
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
            connection: "Gemini", redacted: false, contextCategories: ["app", "visible text"],
            offerLocalTranscript: false)
        #expect(state.secondaryText == "App shared · Visible text shared")
    }
}
