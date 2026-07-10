import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// A `<CR>` on a whole-utterance regex replacement presses a real Return after the verified insert,
// overriding the mode's standing submit for that insert only, and inheriting every existing submit
// safety gate (never on clipboard fallback, failed paste, secure field, or moved focus). Wired through
// the REAL DictationController with only the OS edges mocked (mirrors TrailingAndSubmitTests).
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
    }

    private let crResume = [ReplacementsSet.Rule(heard: "slash resume", replace: "/resume<CR>", regex: true)]

    private func run(
        transcript: String, rules: [ReplacementsSet.Rule], modeSubmit: Mode.Submit = .none,
        insertSucceeds: Bool = true, accessibilityGranted: Bool = true,
        secureField: Bool = false, focusMovesAfterInsert: Bool = false
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
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let captured = Captured()
        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
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
        controller.handleCommit()
        await controller.dictationTask?.value
        return captured
    }

    // 11. Owned non-empty <CR> replacement → one Return after a verified insert.
    @Test func crReplacementFiresReturnOnce() async {
        let out = await run(transcript: "slash resume", rules: crResume)
        #expect(out.insertedText == "/resume")
        #expect(out.submits == [.return])
    }

    // 12. The <CR> Return overrides the mode's standing submit (.cmdReturn → .return), still once.
    @Test func crOverridesModeSubmit() async {
        let out = await run(transcript: "slash resume", rules: crResume, modeSubmit: .cmdReturn)
        #expect(out.insertedText == "/resume")
        #expect(out.submits == [.return])
    }

    // A bare replacement WITHOUT <CR> does not suppress the mode's submit — override applies only with <CR>.
    @Test func bareWithoutCRKeepsModeSubmit() async {
        let plain = [ReplacementsSet.Rule(heard: "slash replace", replace: "/replace", regex: false)]
        let out = await run(transcript: "slash replace", rules: plain, modeSubmit: .cmdReturn)
        #expect(out.insertedText == "/replace")
        #expect(out.submits == [.cmdReturn])
    }

    // 13a. Clipboard fallback (Accessibility off): the text never reached the target → no Return.
    @Test func crReturnSkippedOnClipboardFallback() async {
        let out = await run(transcript: "slash resume", rules: crResume, accessibilityGranted: false)
        #expect(out.insertedText == "/resume")
        #expect(out.submits.isEmpty)
    }

    // 13b. A silently-failed paste → no Return against a paste that did not happen.
    @Test func crReturnSkippedOnFailedPaste() async {
        let out = await run(transcript: "slash resume", rules: crResume, insertSucceeds: false)
        #expect(out.submits.isEmpty)
    }

    // 13c. Secure field diverts to concealed clipboard → no Return.
    @Test func crReturnSkippedOnSecureField() async {
        let out = await run(transcript: "slash resume", rules: crResume, secureField: true)
        #expect(out.submits.isEmpty)
    }

    // 13d. Focus moved between the paste and the Return check → skip (existing focus-race gate).
    @Test func crReturnSkippedWhenFocusMoved() async {
        let out = await run(transcript: "slash resume", rules: crResume, focusMovesAfterInsert: true)
        #expect(out.insertedText == "/resume")
        #expect(out.submits.isEmpty)
    }

    // 14. A <CR>-only replacement resolves to empty text → .noSpeech: no insertion, no Return.
    @Test func crOnlyOutputIsNoSpeechNoSubmit() async {
        let rules = [ReplacementsSet.Rule(heard: "slash resume", replace: "<CR>", regex: true)]
        let out = await run(transcript: "slash resume", rules: rules)
        #expect(out.insertedText == nil)
        #expect(out.submits.isEmpty)
    }
}
