import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Proves the per-dictation DictationRecord is actually FED real data through the REAL
// DictationController — the discipline item 1 showed can rot silently (a green unit test on a starved
// seam). Two guarantees: (1) lastRecord is populated even with history DISABLED (the record is the
// reliable ground truth regardless of the history setting), and (2) the boundary fingerprints differ
// across the redaction boundary when tokens were issued (the instrumentation is wired, not stubbed).
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
        func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) async throws -> URL { url }
        func stop() -> URL? { url }
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
        settings.defaultModeId = mode.id
        settings.history = .init(enabled: historyEnabled, retentionDays: 7)

        let provider = try! SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: historyEnabled ? HistoryStore(supportDir: supportDir) : nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _ in },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: llm)

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

    // The record is the reliable ground truth REGARDLESS of the history setting — it must populate even
    // when persistent history is off (the regression the doc calls out: gating it on history.enabled).
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

    // Redaction tokenizes the email before the cloud rewrite, so the text SENT to the LLM differs from
    // the FINAL restored text — the fingerprints prove the boundary instrumentation is wired, and the
    // token→original map never enters the record (only the count).
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
        // The final restored text is the original, un-redacted transcript; the sent text is not.
        #expect(final == TextFingerprint.of("email alice@example.com"))
        // humanSummary never leaks the redacted span.
        #expect(!(record?.humanSummary().contains("alice@example.com") ?? true))
    }

    // A whitespace-only transcript yields noSpeech — assert that terminal path records too.
    @Test func noSpeechTranscriptRecordsNoSpeechOutcome() async {
        let record = await run(transcript: "   ", mode: mode(id: "plain"), historyEnabled: false)
        #expect(record?.outcome == .noSpeech)
    }
}
