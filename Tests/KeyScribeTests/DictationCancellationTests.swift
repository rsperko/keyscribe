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

private final class FakeAudio: AudioCapturing, @unchecked Sendable {
    private let url: URL
    init(url: URL) { self.url = url }
    func start(levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL { url }
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

    @Test func rewriteHUDNamesTheActualSharedContext() {
        let state = HUDState.rewriting(
            connection: "Gemini", redacted: false, contextCategories: ["app", "visible text"],
            offerLocalTranscript: false)
        #expect(state.secondaryText == "App shared · Visible text shared")
    }
}
