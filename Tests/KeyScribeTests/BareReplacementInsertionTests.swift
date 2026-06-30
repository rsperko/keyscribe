import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// A whole-utterance replacement is inserted verbatim and BARE, even in a mode whose `trailing` and
// `trim_trailing_punctuation` would otherwise decorate the output: when one rule owns the entire
// utterance, the mode's trailing space / period-trim are suppressed for that insert only. Anything
// else in the same mode keeps its normal decoration. Wired through the REAL DictationController with
// only the OS edges mocked (mirrors TrailingAndSubmitTests).
@MainActor
struct BareReplacementInsertionTests {
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
    }

    private func run(transcript: String, rules: [ReplacementsSet.Rule], trailing: Mode.Trailing = .space) async -> String? {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-bare-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var mode = Mode(id: "m", name: "M")
        mode.trailing = trailing
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
            insert: { _, _, _, text in captured.insertedText = text },
            submitKey: { _ in },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { true })

        controller.setNextModeOverride(id: mode.id)
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        return captured.insertedText
    }

    private let slashReplace = [ReplacementsSet.Rule(heard: "slash replace", replace: "/replace", regex: false)]
    private let slashWord = [ReplacementsSet.Rule(heard: #"slash (\w+)"#, replace: "/$1", regex: true)]

    // The whole utterance is the replacement → bare, no trailing space, despite trailing = .space.
    @Test func wholeUtteranceLiteralIsBare() async {
        #expect(await run(transcript: "slash replace", rules: slashReplace) == "/replace")
    }

    // A stray STT period must not defeat the clamp.
    @Test func wholeUtteranceToleratesTrailingPeriod() async {
        #expect(await run(transcript: "slash replace.", rules: slashReplace) == "/replace")
    }

    // Leading residue → not the whole utterance → normal path keeps the trailing space.
    @Test func leadingResidueKeepsTrailing() async {
        #expect(await run(transcript: "send slash replace", rules: slashReplace) == "send /replace ")
    }

    // Trailing word residue → normal path keeps the trailing space.
    @Test func trailingResidueKeepsTrailing() async {
        #expect(await run(transcript: "slash replace now", rules: slashReplace) == "/replace now ")
    }

    // Regex whole-utterance clamps to the substituted value, bare.
    @Test func wholeUtteranceRegexIsBare() async {
        #expect(await run(transcript: "slash dog", rules: slashWord) == "/dog")
    }

    // The real-world bug: STT capitalizes the first word and appends a period ("Slash dog."). The
    // regex is now case-insensitive by default, so it still matches and clamps to bare "/dog" —
    // instead of missing and falling through to "Slash Dog. ".
    @Test func capitalizedSTTStillClampsBare() async {
        #expect(await run(transcript: "Slash dog.", rules: slashWord) == "/dog")
    }
}
