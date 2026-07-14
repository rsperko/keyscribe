import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Proves DictationRecord is fed real data through the real DictationController, not stubbed: (1)
// lastRecord populates even with history disabled — it's the ground truth regardless of that setting;
// (2) boundary fingerprints differ across redaction when tokens were issued.
@MainActor
struct DictationRecordWiringTests {
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

    private final class ThrowingEngine: SpeechEngine, @unchecked Sendable {
        let id = "throwing"
        let displayName = "Throwing"
        let supportsRecognitionBias = false
        struct Boom: Error {}
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { throw Boom() }
        func evict() async {}
    }

    // Echoes the <content> block verbatim so issued tokens survive the validation gate.
    private struct EchoLLM: LLMClient {
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            guard let start = user.range(of: "<content>\n"),
                  let end = user.range(of: "\n</content>") else { return user }
            return String(user[start.upperBound..<end.lowerBound])
        }
    }

    private func run(
        transcript: String, mode: Mode, connection: Connection? = nil,
        llm: any LLMClient = EchoLLM(), historyEnabled: Bool
    ) async -> DictationRecord? {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-record-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        try? ModeStore.write(mode, to: modesDir)
        if let connection {
            try? ConnectionStore.write(ConnectionSet(connections: [connection]), to: supportDir)
        }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        settings.history = .init(enabled: historyEnabled, retentionDays: 7)

        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: historyEnabled ? HistoryStore(supportDir: supportDir) : nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: llm)

        controller.setNextModeOverride(id: mode.id)
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        return controller.lastRecord
    }

    private func mode(id: String, privacy: Bool = false, connectionId: String? = nil) -> Mode {
        var m = Mode(id: id, name: id)
        m.commands = .init(liveEdits: false, privacy: privacy)
        if let connectionId { m.aiRewrite = .init(connection: connectionId, prompt: "Rewrite it.", context: .init()) }
        return m
    }

    // Must populate even with persistent history off — guards against gating it on history.enabled.
    @Test func lastRecordPopulatedWithHistoryDisabled() async {
        let record = await run(transcript: "hello world", mode: mode(id: "plain"), historyEnabled: false)
        #expect(record != nil)
        #expect(record?.outcome == .inserted)
        #expect(record?.modeName == "plain")
        #expect(record?.targetBundleId == "test.bundle")
        #expect(record?.stageMillis[.transcribe] != nil)
        #expect(record?.fingerprints[.raw] == TextFingerprint.of("hello world"))
        #expect(record?.fingerprints[.final] == TextFingerprint.of("hello world"))
        #expect(record?.cloudInvolved == false)
    }

    // Redaction tokenizes the email before the cloud rewrite, so text SENT to the LLM must differ from
    // the FINAL restored text; the token→original map itself must never enter the record.
    @Test func redactionBoundaryFingerprintsDifferAndOnlyCountIsKept() async {
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let record = await run(
            transcript: "email alice@example.com", mode: mode(id: "secure", privacy: true, connectionId: "c"),
            connection: conn, historyEnabled: false)

        #expect(record?.cloudInvolved == true)
        #expect(record?.redaction == true)
        #expect((record?.issuedTokenCount ?? 0) >= 1)
        #expect(record?.connection == "C")
        let sent = record?.fingerprints[.sentToLLM]
        let final = record?.fingerprints[.final]
        #expect(sent != nil)
        #expect(final != nil)
        #expect(sent != final)
        #expect(final == TextFingerprint.of("email alice@example.com"))
        #expect(!(record?.humanSummary().contains("alice@example.com") ?? true))
    }

    @Test func noSpeechTranscriptRecordsNoSpeechOutcome() async {
        let record = await run(transcript: "   ", mode: mode(id: "plain"), historyEnabled: false)
        #expect(record?.outcome == .noSpeech)
    }

    // Whisper renders a silent clip as the literal string "[BLANK_AUDIO]"; must route to noSpeech
    // end-to-end through the real controller instead of pasting the marker.
    @Test func wholeUtteranceAnnotationRoutesToNoSpeech() async {
        let record = await run(transcript: "[BLANK_AUDIO]", mode: mode(id: "plain"), historyEnabled: false)
        #expect(record?.outcome == .noSpeech)
    }

    // modeId must be read while the session is alive and carried into the terminal tail — it survives
    // releaseCapturedPlan nilling the session only if captured before that teardown runs.
    @Test func completionReportsTheModeIdThatProducedTheText() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-record-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        try? ModeStore.write(mode(id: "polish-x"), to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: "hello world")], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        var fired = false
        var completion: DictationCompletion?
        controller.onDictationCompleted = { fired = true; completion = $0 }
        controller.setNextModeOverride(id: "polish-x")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(fired)
        #expect(completion?.modeId == "polish-x")
        #expect(completion?.outcome == .inserted)
    }

    @Test func aFailedTranscribeRecordsAFailedOutcomeWithError() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-record-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        try? ModeStore.write(mode(id: "plain"), to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "throwing", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let provider = try! SpeechEngineProvider(engines: [ThrowingEngine()], activeId: "throwing")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.setNextModeOverride(id: "plain")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(controller.lastRecord?.outcome == .failed)
        #expect(controller.lastRecord?.error != nil)
    }
}
