import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// `trailing` is literal text appended to the transcript INSIDE the atomic insert; `submit` is a
// synthesized keystroke AFTER a verified insert, OUTSIDE the undo atom — and only when the text
// actually landed in the target (never on a clipboard fallback). These wire both through the REAL
// DictationController with only the OS edges mocked.
@MainActor
struct TrailingAndSubmitTests {
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
        func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private final class Captured: @unchecked Sendable {
        var insertedText: String?
        var submits: [Mode.Submit] = []
    }

    private func run(
        transcript: String, trailing: Mode.Trailing, submit: Mode.Submit,
        liveEdits: Bool = false, accessibilityGranted: Bool = true
    ) async -> Captured {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-trailing-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var mode = Mode(id: "m", name: "M")
        mode.trailing = trailing
        mode.submit = submit
        mode.commands.liveEdits = liveEdits
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
            insert: { _, _, _, text in captured.insertedText = text },
            submitKey: { submit in captured.submits.append(submit) },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { accessibilityGranted })

        controller.setNextModeOverride(id: mode.id)
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        return captured
    }

    @Test func trailingSpaceIsAppendedInsideTheInsert() async {
        let out = await run(transcript: "hello", trailing: .space, submit: .none)
        #expect(out.insertedText == "hello ")
        #expect(out.submits.isEmpty)
    }

    @Test func trailingNewlineIsAppendedInsideTheInsert() async {
        let out = await run(transcript: "hello", trailing: .newline, submit: .none)
        #expect(out.insertedText == "hello\n")
    }

    @Test func noTrailingLeavesTextUntouched() async {
        let out = await run(transcript: "hello", trailing: .none, submit: .none)
        #expect(out.insertedText == "hello")
    }

    // A command-only utterance ends in a control char; the trailing SPACE separator is suppressed so
    // the insert is a clean "\n" (next dictation at column 0), not "\n ".
    @Test func trailingSpaceSuppressedAfterNewlineCommand() async {
        let out = await run(transcript: "insert new line", trailing: .space, submit: .none, liveEdits: true)
        #expect(out.insertedText == "\n")
    }

    // A trailing SPACE still follows word content that ends in a newline command mid-utterance.
    @Test func trailingSpaceSuppressedAfterTrailingNewlineCommand() async {
        let out = await run(transcript: "hello insert new line", trailing: .space, submit: .none, liveEdits: true)
        #expect(out.insertedText == "hello\n")
    }

    // A trailing NEWLINE is an explicit choice — appended even onto a spoken newline (blank line).
    @Test func trailingNewlineStillAppendsAfterNewlineCommand() async {
        let out = await run(transcript: "insert new line", trailing: .newline, submit: .none, liveEdits: true)
        #expect(out.insertedText == "\n\n")
    }

    @Test func submitFiresAfterAVerifiedInsert() async {
        let out = await run(transcript: "hello", trailing: .none, submit: .cmdReturn)
        #expect(out.insertedText == "hello")
        #expect(out.submits == [.cmdReturn])
    }

    // Clipboard fallback means the text never reached the target — a synthesized Return would hit
    // whatever app is focused, so submit MUST NOT fire.
    @Test func submitDoesNotFireOnClipboardFallback() async {
        let out = await run(transcript: "hello", trailing: .space, submit: .return, accessibilityGranted: false)
        #expect(out.submits.isEmpty)
    }

    // A trailing suffix must not turn an empty (no-speech) transcript into a "real" insert.
    @Test func trailingDoesNotResurrectEmptyTranscript() async {
        let out = await run(transcript: "   ", trailing: .space, submit: .return)
        #expect(out.insertedText == nil)
        #expect(out.submits.isEmpty)
    }
}
