import Foundation
import Testing

@testable import KeyScribeApp
@testable import KeyScribeKit

// A route that dies mid-recording stops delivering buffers while the controller still believes it is
// recording, so release finalizes whatever prefix reached the WAV and inserts it as an ordinary success.
// The VAD gate cannot catch it — it counts speech chunks ANYWHERE in the file, so a take with a real
// speech prefix passes trivially. These pin the loss being reported instead.
@MainActor
struct CaptureLostTruncationTests {
    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var handler: (@Sendable () -> Void)?

        init(url: URL) { self.url = url }

        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
        func takeDrainedSamples() -> [Float]? { [Float](repeating: 0.1, count: 16000) }
        func setCaptureLostHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock { self.handler = handler }
        }
        func loseCapture() { lock.withLock { handler }?() }
        // The handler installed for the capture in flight at this moment — held so a test can fire it LATER,
        // after that dictation is over, the way a queued main-actor hop really arrives.
        func captureCurrentHandler() -> (@Sendable () -> Void)? { lock.withLock { handler } }
    }

    private struct StubPresence: SpeechPresenceDetecting {
        func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading {
            SpeechPresenceReading(presence: .speech, peak: 0.5, latencyMs: 1, modelUsed: true, speechStart: nil)
        }
    }

    private final class StubEngine: SpeechEngine, @unchecked Sendable {
        let id = "stub"
        let displayName = "Stub Model"
        let supportsRecognitionBias = false
        nonisolated var supportsSampleInput: Bool { true }
        func loadIfNeeded() async throws {}
        func evict() async {}
        func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
            "the prefix that was recorded"
        }
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            "the prefix that was recorded"
        }
    }

    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private final class InsertSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _texts: [String] = []
        var text: String? { lock.withLock { _texts.last } }
        var count: Int { lock.withLock { _texts.count } }
        func record(_ t: String) { lock.withLock { _texts.append(t) } }
    }

    // `loseDuring` runs at the point in the take where the route dies, which is what distinguishes the two
    // race orderings: before the user releases, or after (while transcription is already running).
    private func run(
        loseBeforeRelease: Bool
    ) async -> (record: DictationRecord?, states: [HUDState], inserted: String?, lastResult: String?) {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-lost-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var m = Mode(id: "plain", name: "plain")
        m.commands = .init(liveEdits: false, privacy: false)
        try? ModeStore.write(m, to: modesDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "stub", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let hud = HUDSpy()
        let inserted = InsertSpy()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let provider = try! SpeechEngineProvider(engines: [StubEngine()], activeId: "stub")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud, audio: audio, presenceDetector: StubPresence(),
            insert: { _, _, _, text, _ in inserted.record(text); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })
        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        if loseBeforeRelease { audio.loseCapture() }
        controller.handleCommit()
        if !loseBeforeRelease { audio.loseCapture() }
        await controller.dictationTask?.value
        return (controller.lastRecord, hud.states, inserted.text, controller.lastResult)
    }

    private func terminalMessage(_ states: [HUDState]) -> String? {
        if case .error(let message, _) = states.last { return message }
        return nil
    }

    @Test func aTakeLostBeforeReleaseInsertsNothingAndReportsTheLoss() async {
        let (record, states, inserted, _) = await run(loseBeforeRelease: true)

        #expect(inserted == nil)
        #expect(record?.outcome == .failed)
        #expect(terminalMessage(states)?.contains("microphone stopped") == true)
    }

    // The release can win the race: by the time the loss lands the machine has already left .recording, so
    // a state-gated flag would drop the signal and auto-insert a truncated take.
    @Test func aTakeLostAfterReleaseStillInsertsNothing() async {
        let (record, states, inserted, _) = await run(loseBeforeRelease: false)

        #expect(inserted == nil)
        #expect(record?.outcome == .failed)
        #expect(terminalMessage(states)?.contains("microphone stopped") == true)
    }

    // Refusing to insert must not also destroy the words that WERE captured.
    @Test func theCapturedPrefixStaysRecoverable() async {
        let (_, _, _, lastResult) = await run(loseBeforeRelease: true)

        #expect(lastResult == "the prefix that was recorded")
    }

    // The top-of-function check runs BEFORE `snapshotAsync`. A loss landing inside that suspension would
    // otherwise be observed only after the text had already been put into the user's document, so the last
    // gate has to sit after the final suspension point.
    @Test func aLossArrivingDuringTheInsertionSnapshotStillInsertsNothing() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-lost-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var m = Mode(id: "plain", name: "plain")
        m.commands = .init(liveEdits: false, privacy: false)
        try? ModeStore.write(m, to: modesDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "stub", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let hud = HUDSpy()
        let inserted = InsertSpy()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let provider = try! SpeechEngineProvider(engines: [StubEngine()], activeId: "stub")
        // Fires the loss from INSIDE the insertion snapshot, i.e. after the gate at the top of
        // finishInsertion has already passed.
        let loseDuringSnapshot = LateBoundLoss()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud, audio: audio, presenceDetector: StubPresence(),
            insert: { _, _, _, text, _ in inserted.record(text); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            snapshotAsync: {
                loseDuringSnapshot.tickAndFireOnInsertionSnapshot()
                for _ in 0..<10 { await Task.yield() }
                return TargetSnapshot(bundleId: "test.bundle")
            },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        // Armed only now, so it cannot fire before the take reaches insertion.
        loseDuringSnapshot.run = { audio.loseCapture() }
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(inserted.count == 0)
    }

    // A Return is the one action here that cannot be undone — it sends the message or submits the form. The
    // focus check before it is another suspension, so the loss has to be re-read after it, not just at the
    // top of finishInsertion.
    @Test func aLossArrivingDuringTheSubmitFocusCheckFiresNoReturn() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-lost-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var m = Mode(id: "plain", name: "plain")
        m.commands = .init(liveEdits: false, privacy: false)
        m.submit = .return
        try? ModeStore.write(m, to: modesDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "stub", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let hud = HUDSpy()
        let inserted = InsertSpy()
        let submits = InsertSpy()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let provider = try! SpeechEngineProvider(engines: [StubEngine()], activeId: "stub")
        let loseDuringFocusCheck = LateBoundLoss()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud, audio: audio, presenceDetector: StubPresence(),
            insert: { _, _, _, text, _ in inserted.record(text); return true },
            submitKey: { _ in submits.record("return") },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            snapshotAsync: {
                // Calls in order: commit secure probe, insertion snapshot, then the submit focus check.
                loseDuringFocusCheck.fireOn(call: 3)
                for _ in 0..<10 { await Task.yield() }
                return TargetSnapshot(bundleId: "test.bundle")
            },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        loseDuringFocusCheck.run = { audio.loseCapture() }
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(submits.count == 0)
    }

    // The strict version of the guarantee: fire the loss and do NOT yield, so the queued @MainActor hop
    // that sets the state flag has provably not run. Only a signal recorded SYNCHRONOUSLY at report time can
    // be seen here — serial executors give mutual exclusion, not FIFO, so the hop is not guaranteed to land
    // before actuation continues.
    @Test func aLossNotYetDeliveredToTheMainActorStillBlocksInsertion() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-lost-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var m = Mode(id: "plain", name: "plain")
        m.commands = .init(liveEdits: false, privacy: false)
        try? ModeStore.write(m, to: modesDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "stub", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let hud = HUDSpy()
        let inserted = InsertSpy()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let provider = try! SpeechEngineProvider(engines: [StubEngine()], activeId: "stub")
        let loseDuringSnapshot = LateBoundLoss()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud, audio: audio, presenceDetector: StubPresence(),
            insert: { _, _, _, text, _ in inserted.record(text); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            snapshotAsync: {
                // No yields: the loss is recorded and we return straight into the insertion path.
                loseDuringSnapshot.fireOn(call: 2)
                return TargetSnapshot(bundleId: "test.bundle")
            },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        loseDuringSnapshot.run = { audio.loseCapture() }
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(inserted.count == 0)
    }

    // The loss flag must belong to ONE dictation. An earlier version kept a single shared flag keyed by
    // ObjectIdentifier of the owning identity — but ObjectIdentifier is unique only for an object's
    // lifetime, and measured, 49 of 50 sequentially allocated identities reused the same address. A single
    // lost capture would then have matched nearly every later dictation and refused to insert until
    // relaunch. This drives several healthy dictations after a lost one.
    @Test func aLostCaptureDoesNotPoisonLaterDictations() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-lost-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var m = Mode(id: "plain", name: "plain")
        m.commands = .init(liveEdits: false, privacy: false)
        try? ModeStore.write(m, to: modesDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "stub", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let hud = HUDSpy()
        let inserted = InsertSpy()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let provider = try! SpeechEngineProvider(engines: [StubEngine()], activeId: "stub")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud, audio: audio, presenceDetector: StubPresence(),
            insert: { _, _, _, text, _ in inserted.record(text); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        // One dictation that genuinely loses its capture.
        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        audio.loseCapture()
        controller.handleCommit()
        await controller.dictationTask?.value
        #expect(inserted.count == 0)

        // Then several healthy ones. Each allocates a fresh identity, very likely at the same address.
        for _ in 0..<5 {
            controller.setNextModeOverride(id: "plain")
            controller.handleStart()
            await controller.captureBringUpTask?.value
            controller.handleCommit()
            await controller.dictationTask?.value
        }
        #expect(inserted.count == 5)
    }

    private final class LateBoundLoss: @unchecked Sendable {
        private let lock = NSLock()
        private var _run: (@Sendable () -> Void)?
        var run: (@Sendable () -> Void)? {
            get { lock.withLock { _run } }
            set { lock.withLock { _run = newValue } }
        }
        private var _calls = 0
        // snapshotAsync runs twice per take: the commit-time secure-field probe, then the insertion
        // snapshot. Only the second one is inside finishInsertion, i.e. past the top-of-function gate.
        func tickAndFireOnInsertionSnapshot() { fireOn(call: 2) }

        func fireOn(call target: Int) {
            let n = lock.withLock { _calls += 1; return _calls }
            if n == target { run?() }
        }
    }

    // The delivery hop is asynchronous, so a loss belonging to dictation N can land after N ended and N+1
    // began. It must not truncate N+1 — that would throw away a recording nothing was wrong with.
    @Test func aLossQueuedFromAnEarlierDictationDoesNotTruncateTheNextOne() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-lost-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var m = Mode(id: "plain", name: "plain")
        m.commands = .init(liveEdits: false, privacy: false)
        try? ModeStore.write(m, to: modesDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "stub", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let hud = HUDSpy()
        let inserted = InsertSpy()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let provider = try! SpeechEngineProvider(engines: [StubEngine()], activeId: "stub")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud, audio: audio, presenceDetector: StubPresence(),
            insert: { _, _, _, text, _ in inserted.record(text); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        // Dictation N: runs to completion normally, but its handler is held back.
        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        let staleHandler = audio.captureCurrentHandler()
        controller.handleCommit()
        await controller.dictationTask?.value

        // Dictation N+1 begins, and only now does N's loss arrive.
        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        staleHandler?()
        // Drain the queued main-actor hop before committing — otherwise the stale delivery lands after this
        // dictation is already over and the test proves nothing.
        for _ in 0..<10 { await Task.yield() }
        controller.handleCommit()
        await controller.dictationTask?.value

        // Both dictations inserted: N normally, and N+1 despite the stale loss arriving mid-flight. One
        // insertion here would mean the successor was wrongly truncated.
        #expect(inserted.count == 2)
    }
}
