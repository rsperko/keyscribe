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

    // Ground truth for "the press did not dictate". Two traps this avoids: the terminal drops the
    // session, so `captureBringUpTask` reads nil whether or not beginCapture ran; and the bring-up is a
    // Task, so counting mic opens alone races the assertion and passes vacuously. `setCaptureLostHandler`
    // is called synchronously at the top of beginCapture, so it records the entry itself.
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

    private func harness(
        modes: [Mode], bundleId: String
    ) -> (controller: DictationController, hud: HUDRecorder, audio: StubAudio, inserts: InsertCounter,
          dir: URL) {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-unclaimed-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        for mode in modes { try? ModeStore.write(mode, to: modesDir) }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let provider = try! SpeechEngineProvider(engines: [StubEngine()], activeId: "fixed")
        let hud = HUDRecorder()
        let audio = StubAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let inserts = InsertCounter()
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: hud,
            audio: audio,
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

    // The reported bug. Resolution is inline here (no URL-scoped mode anywhere in the config), so the
    // verdict lands before beginCapture and nothing is claimed: no cue, no mic, no HUD.
    @Test func aPressNoModeCanServeDoesNotDictateWhenDirectIsBoundElsewhere() async {
        let h = harness(
            modes: [scoped("vm", key: "fn", bundle: "com.vmware.fusion"),
                    direct(owning: "right_option")],
            bundleId: "com.apple.Notes")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        // Nothing claimed: no capture was ever brought up, the machine is idle again, and the HUD never
        // painted anything but the arming-time clear.
        #expect(h.audio.captureBegins == 0)
        #expect(h.audio.starts == 0)
        #expect(!h.controller.isBusy)
        #expect(h.hud.states.allSatisfy { $0 == HUDState.hidden })
        #expect(h.inserts.count == 0)
    }

    // The documented same-key recipe still works: Direct owns the key, so the press it cannot serve
    // still dictates plainly.
    @Test func theSamePressStillFallsBackWhenDirectOwnsTheKey() async {
        let h = harness(
            modes: [scoped("vm", key: "fn", bundle: "com.vmware.fusion"), direct(owning: "fn")],
            bundleId: "com.apple.Notes")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        #expect(h.hud.recordingModeName == Mode.direct.name)
    }

    // Inside the scoped mode's own app the press is served by that mode, unchanged.
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

    // A menu-picked one-shot is an explicit choice that bypasses the context gate, so it must outrank
    // the "nothing can serve this press" verdict rather than being cancelled by it.
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

    // MARK: the deferred path — a verdict that lands after the mic is already open

    // A url-scoped mode cannot be ruled out by the bundle, so resolution defers past `beginCapture` and the
    // no-mode verdict arrives with the mic live. That press cancels audibly rather than silently: the
    // documented trade for routing on something only knowable after dictation starts. `com.apple.Notes` is
    // not an https handler, so `ContextProbe.browserURLAsync` returns nil without any AppleScript.
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

    // The recipe that buys silence back: pair the site rule with the browser it can only match in. The
    // bundle now settles eligibility on its own, so the press resolves inline and never opens the mic —
    // the same terminal a bundle-only scoped mode gets. Before the probe gate was narrowed to the modes
    // the bundle cannot rule out, ONE url-scoped mode anywhere in the config forced this press onto the
    // deferred path above.
    @Test func pairingASiteRuleWithItsBrowserRestoresTheSilentNoOp() async {
        let h = harness(
            modes: [urlScoped("email", key: "fn", bundle: "com.google.Chrome",
                              url: #"mail\.google\.com"#),
                    direct(owning: "right_option")],
            bundleId: "com.apple.Notes")
        defer { try? FileManager.default.removeItem(at: h.dir) }

        h.controller.handleStart(triggerKey: "fn")
        await h.controller.captureBringUpTask?.value

        #expect(h.audio.captureBegins == 0)
        #expect(!h.controller.isBusy)
        #expect(h.inserts.count == 0)
        #expect(h.hud.states.allSatisfy { $0 == HUDState.hidden })
    }

    // The other half of that narrowing: inside the app the rule names, the URL still has to be probed, so
    // the press must NOT resolve inline. Same non-browser bundle as above keeps the probe hermetic — it is
    // the deferral decision under test, not the AppleScript.
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
