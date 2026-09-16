import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

// A `<CR>` on a whole-utterance regex replacement presses a real Return after the verified insert,
// overriding the mode's standing submit for that insert only, and inheriting every existing submit
// safety gate (never on clipboard fallback, failed paste, secure field, or moved focus). Wired through
// the real DictationController with only the OS edges mocked.
@MainActor
struct ReturnSuffixInsertionTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        private let text: String
        init(text: String) { self.text = text }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { text }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private final class Captured: @unchecked Sendable {
        var insertedText: String?
        var submits: [Mode.Submit] = []
        var focusMoved = false
        var hudStates: [HUDState] = []
    }

    private final class HUDSpy: HUDPresenting {
        var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private let crResume = [ReplacementsSet.Rule(heard: "slash resume", replace: "/resume<CR>", regex: true)]

    private func run(
        transcript: String, rules: [ReplacementsSet.Rule], modeSubmit: Mode.Submit = .none,
        insertSucceeds: Bool = true, accessibilityGranted: Bool = true,
        secureField: Bool = false, focusMovesAfterInsert: Bool = false,
        moveFocusBeforeCommit: Bool = false
    ) async -> Captured {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-cr-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var mode = Mode(id: "m", name: "M")
        mode.submit = modeSubmit
        mode.replacements = Mode.ModeReplacements(includeGlobal: false, rules: rules)
        try? ModeStore.write(mode, to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)

        let captured = Captured()
        let hud = HUDSpy()
        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: hud, permits: { _ in true },
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, text, _ in
                captured.insertedText = text
                if focusMovesAfterInsert { captured.focusMoved = true }
                return insertSucceeds
            },
            submitKey: { submit in captured.submits.append(submit) },
            // Flipping the bundle only after the insert isolates the submit-time focus race: the capture
            // and pre-insert decision both see the original target, the post-insert Return check sees a move.
            snapshot: {
                TargetSnapshot(bundleId: captured.focusMoved ? "other.bundle" : "test.bundle",
                               isSecureField: secureField)
            },
            micStatus: { .granted },
            accessibilityGranted: { accessibilityGranted })

        controller.setNextModeOverride(id: mode.id)
        controller.handleStart()
        await controller.captureBringUpTask?.value
        if moveFocusBeforeCommit { captured.focusMoved = true }
        controller.handleCommit()
        await controller.dictationTask?.value
        captured.hudStates = hud.states
        return captured
    }

    private func terminalState(_ captured: Captured) -> HUDState? {
        captured.hudStates.last { state in
            switch state {
            case .complete, .error, .localFallback: return true
            default: return false
            }
        }
    }

    @Test func crReplacementFiresReturnOnce() async {
        let out = await run(transcript: "slash resume", rules: crResume)
        #expect(out.insertedText == "/resume")
        #expect(out.submits == [.return])
    }

    @Test func crOverridesModeSubmit() async {
        let out = await run(transcript: "slash resume", rules: crResume, modeSubmit: .cmdReturn)
        #expect(out.insertedText == "/resume")
        #expect(out.submits == [.return])
    }

    @Test func bareWithoutCRKeepsModeSubmit() async {
        let plain = [ReplacementsSet.Rule(heard: "slash replace", replace: "/replace", regex: false)]
        let out = await run(transcript: "slash replace", rules: plain, modeSubmit: .cmdReturn)
        #expect(out.insertedText == "/replace")
        #expect(out.submits == [.cmdReturn])
    }

    @Test func crReturnSkippedOnClipboardFallback() async {
        let out = await run(transcript: "slash resume", rules: crResume, accessibilityGranted: false)
        #expect(out.insertedText == "/resume")
        #expect(out.submits.isEmpty)
    }

    @Test func crReturnSkippedOnFailedPaste() async {
        let out = await run(transcript: "slash resume", rules: crResume, insertSucceeds: false)
        #expect(out.submits.isEmpty)
    }

    @Test func crReturnSkippedOnSecureField() async {
        let out = await run(transcript: "slash resume", rules: crResume, secureField: true)
        #expect(out.submits.isEmpty)
    }

    @Test func crReturnSkippedWhenFocusMoved() async {
        let out = await run(transcript: "slash resume", rules: crResume, focusMovesAfterInsert: true)
        #expect(out.insertedText == "/resume")
        #expect(out.submits.isEmpty)
    }

    @Test func crOnlyOutputPressesReturnWithoutInserting() async {
        let rules = [ReplacementsSet.Rule(heard: "slash resume", replace: "<CR>", regex: true)]
        let out = await run(transcript: "slash resume", rules: rules)
        #expect(out.insertedText == nil)
        #expect(out.submits == [.return])
        #expect(terminalState(out) == .complete(outcome: .inserted, mode: "M"))
    }

    @Test func crOnlyReturnSkippedWithoutAccessibility() async {
        let rules = [ReplacementsSet.Rule(heard: "slash resume", replace: "<CR>", regex: true)]
        let out = await run(transcript: "slash resume", rules: rules, accessibilityGranted: false)
        #expect(out.insertedText == nil)
        #expect(out.submits.isEmpty)
        guard case .error(let message, let action)? = terminalState(out) else {
            Issue.record("expected an error state, got \(String(describing: terminalState(out)))"); return
        }
        #expect(message.contains("Accessibility is off"))
        #expect(action == .openAccessibilitySettings)
    }

    @Test func crOnlyReturnSkippedOnSecureField() async {
        let rules = [ReplacementsSet.Rule(heard: "slash resume", replace: "<CR>", regex: true)]
        let out = await run(transcript: "slash resume", rules: rules, secureField: true)
        #expect(out.insertedText == nil)
        #expect(out.submits.isEmpty)
        guard case .error(let message, let action)? = terminalState(out) else {
            Issue.record("expected an error state, got \(String(describing: terminalState(out)))"); return
        }
        #expect(message.contains("password field"))
        #expect(action == nil)
    }

    @Test func crOnlyReturnRefusedWhenTargetChanged() async {
        let rules = [ReplacementsSet.Rule(heard: "slash resume", replace: "<CR>", regex: true)]
        let out = await run(transcript: "slash resume", rules: rules, moveFocusBeforeCommit: true)
        #expect(out.submits.isEmpty)
        guard case .error(let message, _)? = terminalState(out) else {
            Issue.record("expected an error state, got \(String(describing: terminalState(out)))"); return
        }
        #expect(message.contains("target window changed"))
    }

    @Test func genuineSilenceStillReadsNoSpeech() async {
        let out = await run(transcript: "", rules: crResume)
        #expect(out.insertedText == nil)
        #expect(out.submits.isEmpty)
        #expect(terminalState(out) == .complete(outcome: .noSpeech, mode: "M"))
    }
}
