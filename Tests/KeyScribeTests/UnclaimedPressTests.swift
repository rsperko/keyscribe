import AppKit
import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

// A press whose key belongs only to modes that cannot run here, with the Direct floor bound elsewhere,
// must not dictate at all — it used to silently start Plain Dictation and insert raw text where a
// scoped mode's rewrite was expected.
@MainActor
struct UnclaimedPressTests {
    private final class StubEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "hello" }
        func evict() async {}
    }

    // Capture starts before the mode is resolved, so an unclaimed press may open the mic briefly. What it
    // must never do is cue, show a HUD, or insert. `setCaptureLostHandler` is called synchronously at the
    // top of beginCapture, so it records the entry itself.
    private final class StubAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var _begins = 0
        private var _starts = 0
        var captureBegins: Int { lock.withLock { _begins } }
        var starts: Int { lock.withLock { _starts } }
        // Fires on the capture teardown every cancel path reaches — `cancel()` mid-recording, or
        // `finishCanceledBringUp` when the verdict lands while the mic is still coming up. The deferred
        // abort is several hops of two racing Tasks, so the test waits for the real event.
        let stopped = Signal("capture stop")
        init(url: URL) { self.url = url }
        func setCaptureLostHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock { _begins += 1 }
        }
        func start(sampleRate: Int) async throws -> URL {
            lock.withLock { _starts += 1 }
            return url
        }
        func stop() -> URL? { stopped.fire(); return url }
    }

    private final class HUDRecorder: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
        // The mode the HUD announced when recording began — the name the user reads, and the only
        // published view of the resolved mode.
        var recordingModeName: String? {
            states.compactMap { if case .recording(let mode, _, _) = $0 { return mode } else { return nil } }
                .last ?? nil
        }
    }

    private struct StubLLM: LLMClient {
        func complete(system: String, user: String, connection: Connection) async throws -> String { user }
    }
    private final class InsertCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func record() { lock.withLock { _count += 1 } }
    }

    private final class CueCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _played = 0
        var played: Int { lock.withLock { _played } }
        func record() { lock.withLock { _played += 1 } }
    }

    private func harness(
        modes: [Mode], bundleId: String, cues: CueCounter? = nil
    ) -> (controller: DictationController, hud: HUDRecorder, audio: StubAudio, inserts: InsertCounter,
          dir: URL) {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-unclaimed-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        for mode in modes { try? ModeStore.write(mode, to: modesDir) }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: cues != nil)
        let effects = cues.map { counter in
            DuringDictationEffects(
                reapplyDelays: [], duckFollowInterval: 100,
                loadStartCueSound: { NSSound(data: DuringDictationEffectsTests.silentWAV(seconds: 0.02)) },
                playSound: { _, _ in counter.record() })
        }
        let provider = try! SpeechEngineProvider(engines: [StubEngine()], activeId: "fixed")
        let hud = HUDRecorder()
        let audio = StubAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let inserts = InsertCounter()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud, permits: { _ in true },
            audio: audio,
            effects: effects,
            insert: { _, _, _, _, _ in inserts.record(); return true },
            submitKey: { _ in },
            captureSelection: { _ in nil },
            clipboard: { nil },
            snapshot: { TargetSnapshot(bundleId: bundleId) },
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: StubLLM())
        return (controller, hud, audio, inserts, supportDir)
    }

    private func urlScoped(_ id: String, key: String, bundle: String?, url: String) -> Mode {
        var m = Mode(id: id, name: id.capitalized)
        m.triggerKeys = [.init(key: key)]
        m.constraints = [Mode.Constraint(bundleId: bundle, urlPattern: url)]
        return m
    }

    private func scoped(_ id: String, key: String, bundle: String) -> Mode {
        var m = Mode(id: id, name: id.capitalized)
        m.triggerKeys = [.init(key: key)]
        m.constraints = [Mode.Constraint(bundleId: bundle)]
        return m
    }

    private func direct(owning key: String?) -> Mode {
        var d = Mode.direct
        d.triggerKeys = key.map { [.init(key: $0)] } ?? []
        return d
    }

    @Test func aPressNoModeCanServeDoesNotDictateWhenDirectIsBoundElsewhere() async {
        let h = harness(
            modes: [scoped("vm", key: "fn", bundle: "com.vmware.fusion"),
                    direct(owning: "right_option")],
            bundleId: "com.apple.Notes")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        // Nothing claimed: the machine is idle again, the HUD never painted anything but the arming-time
        // clear, and whatever capture the press opened was torn down.
        #expect(!h.controller.isBusy)
        #expect(h.audio.starts == 0 || h.audio.stopped.hasFired)
        #expect(h.hud.states.allSatisfy { $0 == HUDState.hidden })
        #expect(h.inserts.count == 0)
    }

    @Test func anUnclaimedPressWhoseMicIsAlreadyComingUpStaysSilent() async {
        let cues = CueCounter()
        let h = harness(
            modes: [scoped("vm", key: "fn", bundle: "com.vmware.fusion"),
                    direct(owning: "right_option")],
            bundleId: "com.apple.Notes", cues: cues)
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        #expect(h.audio.captureBegins == 1)
        #expect(cues.played == 0)
        #expect(!h.controller.isBusy)
        #expect(h.hud.states.allSatisfy { $0 == HUDState.hidden })
    }

    @Test func theSameHarnessCuesAPressAModeCanServe() async {
        let cues = CueCounter()
        let h = harness(
            modes: [scoped("vm", key: "fn", bundle: "com.vmware.fusion"),
                    direct(owning: "right_option")],
            bundleId: "com.vmware.fusion", cues: cues)
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        #expect(cues.played == 1)
        h.controller.cancel()
    }

    @Test func theSamePressStillFallsBackWhenDirectOwnsTheKey() async {
        let h = harness(
            modes: [scoped("vm", key: "fn", bundle: "com.vmware.fusion"), direct(owning: "fn")],
            bundleId: "com.apple.Notes")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        #expect(h.hud.recordingModeName == Mode.direct.name)
    }

    @Test func theScopedModeStillRunsInsideItsApp() async {
        let h = harness(
            modes: [scoped("vm", key: "fn", bundle: "com.vmware.fusion"),
                    direct(owning: "right_option")],
            bundleId: "com.vmware.fusion")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        #expect(h.hud.recordingModeName == "Vm")
    }

    @Test func aMenuOneShotSurvivesAPressNoModeCouldServe() async {
        let h = harness(
            modes: [scoped("vm", key: "fn", bundle: "com.vmware.fusion"),
                    direct(owning: "right_option")],
            bundleId: "com.apple.Notes")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.setNextModeOverride(id: "vm")
        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        #expect(h.hud.recordingModeName == "Vm")
    }


    @Test func aURLScopedPressCancelsAfterTheMicIsAlreadyOpen() async {
        let h = harness(
            modes: [urlScoped("email", key: "fn", bundle: nil, url: #"mail\.google\.com"#),
                    direct(owning: "right_option")],
            bundleId: "com.apple.Notes")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.audio.stopped.wait()
        await h.controller.captureBringUpTask?.value

        #expect(h.audio.captureBegins == 1)
        #expect(!h.controller.isBusy)
        #expect(h.inserts.count == 0)
        #expect(h.hud.states.last == HUDState.hidden)
    }

    @Test func pairingASiteRuleWithItsBrowserRestoresTheSilentNoOp() async {
        let h = harness(
            modes: [urlScoped("email", key: "fn", bundle: "com.google.Chrome",
                              url: #"mail\.google\.com"#),
                    direct(owning: "right_option")],
            bundleId: "com.apple.Notes")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        #expect(!h.controller.isBusy)
        #expect(h.inserts.count == 0)
        #expect(h.hud.states.allSatisfy { $0 == HUDState.hidden })
    }

    @Test func theSiteRuleStillProbesInsideTheAppItNames() async {
        let h = harness(
            modes: [urlScoped("email", key: "fn", bundle: "com.apple.Notes",
                              url: #"mail\.google\.com"#),
                    direct(owning: "right_option")],
            bundleId: "com.apple.Notes")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.audio.stopped.wait()
        await h.controller.captureBringUpTask?.value

        #expect(h.audio.captureBegins == 1)
        #expect(!h.controller.isBusy)
        #expect(h.inserts.count == 0)
    }
}
