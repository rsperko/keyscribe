import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

// The reason a rewrite fell back is persisted to history JSONL and logged publicly. Provider error bodies
// and token-command stderr are attacker- or user-controlled — a proxy can echo the request back and a
// credential broker can print the token before failing — so neither may reach that boundary (KS-07 / LC-4).
private let secret = "sk-live-DEADBEEF-should-never-be-persisted"
private let promptEcho = "the user said my password is hunter2"

@MainActor
struct RewriteErrorPrivacyTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "hello world" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private struct ThrowingLLM: LLMClient {
        let error: Error
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            throw error
        }
    }

    private struct Result {
        let historyReason: String?
        let recordReason: String?
    }

    private func run(error: Error) async -> Result {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-errpriv-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var mode = Mode(id: "cloud", name: "Cloud")
        mode.aiRewrite = Mode.AIRewrite(connection: "c", prompt: "Clean this up.")
        try? ModeStore.write(mode, to: modesDir)
        try? ConnectionStore.write(
            ConnectionSet(connections: [Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")]),
            to: supportDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        settings.history = .init(enabled: true, retentionDays: 7)

        let history = HistoryStore(supportDir: supportDir)
        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: nil, permits: { _ in true },
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: ThrowingLLM(error: error))

        controller.setNextModeOverride(id: mode.id)
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        var entry: HistoryEntry?
        for _ in 0..<50 {
            if let first = history.entries().first { entry = first; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return Result(historyReason: entry?.fallbackReason, recordReason: controller.lastRecord?.fallbackReason)
    }

    @Test func aProviderErrorBodyNeverReachesHistoryOrTheRecord() async {
        let body = #"{"error":{"message":"upstream rejected: \#(promptEcho) key=\#(secret)"}}"#
        let result = await run(error: ProviderTransportError.http(400, body: body))

        #expect(result.historyReason == "The model service returned an error (400).")
        #expect(!(result.historyReason ?? "").contains(secret))
        #expect(!(result.historyReason ?? "").contains(promptEcho))
        #expect(!(result.recordReason ?? "").contains(secret))
        #expect(!(result.recordReason ?? "").contains(promptEcho))
    }

    @Test func tokenCommandStderrNeverReachesHistoryOrTheRecord() async {
        let result = await run(
            error: TokenCommandError.failed(1, message: "auth broker error, token was \(secret)"))

        #expect(result.historyReason == "The token command failed (exit 1).")
        #expect(!(result.historyReason ?? "").contains(secret))
        #expect(!(result.recordReason ?? "").contains(secret))
    }

    @Test func anUnknownErrorIsReportedGenericallyRatherThanByLocalizedDescription() async {
        struct Leaky: LocalizedError {
            var errorDescription: String? { "boom: \(secret)" }
        }
        let result = await run(error: Leaky())

        #expect(result.historyReason == RewriteService.genericFailureReason)
        #expect(!(result.historyReason ?? "").contains(secret))
    }

    @Test func veryLargeStderrIsBoundedInTheErrorExcerpt() throws {
        let huge = String(repeating: "x", count: 50_000)
        do {
            _ = try TokenCommandRunner.outcome(
                terminationStatus: 1, timedOut: false, stdout: Data(), stderr: Data(huge.utf8))
            Issue.record("expected outcome to throw")
        } catch TokenCommandError.failed(_, let message) {
            #expect((message?.count ?? 0) <= TokenCommandRunner.stderrExcerptLimit)
        }
    }
}

// The excerpt limit above bounds only the eventual error STRING. Memory is a separate boundary: the pipes are
// drained with readDataToEndOfFile-style reads, so a chatty command's whole stream would be resident before
// any excerpt is taken. These drive the real Process/Pipe path, which the excerpt test bypasses entirely.
struct TokenCommandDrainBoundTests {
    @Test func drainKeepsReadingPastTheLimitAndReportsTruncation() async throws {
        let pipe = Pipe()
        let payload = Data(String(repeating: "x", count: 512 * 1024).utf8)
        let writer = Task.detached {
            pipe.fileHandleForWriting.write(payload)
            try? pipe.fileHandleForWriting.close()
        }
        let result = TokenCommandRunner.drain(pipe.fileHandleForReading, limit: 1024)
        await writer.value

        #expect(result.data.count == 1024)
        #expect(result.truncated)
    }

    @Test func drainUnderTheLimitKeepsEverythingAndIsNotTruncated() async throws {
        let pipe = Pipe()
        let writer = Task.detached {
            pipe.fileHandleForWriting.write(Data("small".utf8))
            try? pipe.fileHandleForWriting.close()
        }
        let result = TokenCommandRunner.drain(pipe.fileHandleForReading, limit: 1024)
        await writer.value

        #expect(String(data: result.data, encoding: .utf8) == "small")
        #expect(!result.truncated)
    }

    @Test func aCommandFloodingStderrStillReturnsItsTokenWithoutBufferingItAll() async throws {
        let output = try await TokenCommandRunner.run(
            "yes flood-line-of-noise | head -c 4000000 1>&2; echo the-token", timeout: 30)
        #expect(try TokenCommandOutput.parse(from: output).token == "the-token")
    }

    @Test func aCommandFloodingStdoutFailsRatherThanTruncatingTheToken() async {
        await #expect(throws: TokenCommandError.self) {
            do {
                _ = try await TokenCommandRunner.run(
                    "yes token-noise | head -c \(TokenCommandRunner.stdoutCaptureLimit + 100_000)", timeout: 30)
            } catch let error as TokenCommandError {
                guard case .outputTooLarge = error else {
                    Issue.record("expected .outputTooLarge, got \(error)")
                    throw error
                }
                throw error
            }
        }
    }
}
