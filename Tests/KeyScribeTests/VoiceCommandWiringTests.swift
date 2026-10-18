import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandWiringTests {
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
        private let lock = NSLock()
        private var handler: (@Sendable () -> Void)?
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
        func setCaptureLostHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock { self.handler = handler }
        }
        func loseCapture() { lock.withLock { handler }?() }
    }

    private enum Loss { case none, beforeRelease, whileResolving }

    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private final class RunnerSpy: VoiceCommandRunning {
        var outcome: VoiceCommandOutcome = .done(summary: "Ghostty")
        var whileResolving: () -> Void = {}
        private(set) var calls: [(transcript: String, places: [VoiceCommandPlace], origin: VoiceCommandOrigin?)] = []
        func run(
            transcript: String, places: [VoiceCommandPlace], origin: VoiceCommandOrigin?,
            stillWanted: @MainActor () -> Bool
        ) async -> VoiceCommandOutcome {
            calls.append((transcript, places, origin))
            whileResolving()
            return stillWanted() ? outcome : .abandoned
        }
    }

    private final class Captured: @unchecked Sendable {
        var insertedText: String?
    }

    private struct Run {
        let runner: RunnerSpy
        let hud: HUDSpy
        let inserted: String?
        let historyCount: Int
        let record: DictationRecord?
    }

    private func run(
        transcript: String, outcome: VoiceCommandOutcome = .done(summary: "Ghostty"),
        places: [VoiceCommandPlace] = [], otherModes: [Mode] = [], useVoiceCommands: Bool = true,
        flagOn: Bool = true, loss: Loss = .none
    ) async throws -> Run {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vcwire-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var commands = Mode.voiceCommands
        commands.triggerKeys = [.init(key: "right_option")]
        try ModeStore.write(commands, to: modesDir)
        for mode in otherModes { try ModeStore.write(mode, to: modesDir) }
        try VoiceCommandStore.write(VoiceCommandConfig(places: places), to: supportDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        settings.history = .init(enabled: true, retentionDays: 7)
        settings.features.setEnabled(flagOn, for: .voiceCommands)

        let config = ConfigCache(supportDir: supportDir)
        config.voiceCommandsEnabled = true
        let history = HistoryStore(supportDir: supportDir)
        let hud = HUDSpy()
        let runner = RunnerSpy()
        runner.outcome = outcome
        let captured = Captured()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        if loss == .whileResolving { runner.whileResolving = { audio.loseCapture() } }
        let provider = try SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: config,
            history: history, hud: hud, permits: { _ in true },
            audio: audio,
            insert: { _, _, _, text, _ in captured.insertedText = text; return true },
            submitKey: { _ in },
            snapshot: { TargetSnapshot(bundleId: "com.apple.TextEdit") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            voiceCommands: runner)

        controller.handleStart(triggerKey: useVoiceCommands ? "right_option" : nil)
        await controller.captureBringUpTask?.value
        if loss == .beforeRelease { audio.loseCapture() }
        controller.handleCommit()
        await controller.dictationTask?.value
        return Run(runner: runner, hud: hud, inserted: captured.insertedText, historyCount: history.entries().count,
                   record: controller.lastRecord)
    }

    @Test func aVoiceCommandRunsAndNothingIsInserted() async throws {
        let place = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"))
        let result = try await run(transcript: "Switch to Ghostty.", places: [place])
        #expect(result.runner.calls.map(\.transcript) == ["Switch to Ghostty."])
        #expect(result.runner.calls.first?.places == [place])
        #expect(result.runner.calls.first?.origin == VoiceCommandOrigin(bundleId: "com.apple.TextEdit"))
        #expect(result.inserted == nil)
        #expect(result.historyCount == 0)
        #expect(result.hud.states.last == .commandDone(summary: "Ghostty"))
    }

    @Test func aFailedCommandShowsItsMessageAndInsertsNothing() async throws {
        let result = try await run(transcript: "switch to banana", outcome: .failed(message: "No app or place called “banana”."))
        #expect(result.inserted == nil)
        #expect(result.hud.states.last == .error(message: "No app or place called “banana”.", action: nil))
    }

    @Test func aSpokenSuffixNeverReroutesACommand() async throws {
        var email = Mode(id: "email", name: "Email")
        email.triggerPhrases = ["as an email"]
        let result = try await run(transcript: "switch to chrome as an email", otherModes: [email])
        #expect(result.runner.calls.map(\.transcript) == ["switch to chrome as an email"])
        #expect(result.inserted == nil)
    }

    @Test func anEmptyTranscriptRunsNoCommand() async throws {
        let result = try await run(transcript: "   ")
        #expect(result.runner.calls.isEmpty)
        #expect(result.inserted == nil)
    }

    @Test func aCommandModeDoesNothingWhileTheFlagIsOff() async throws {
        let result = try await run(transcript: "switch to chrome", flagOn: false)
        #expect(result.runner.calls.isEmpty)
        #expect(result.inserted == nil)
        #expect(result.hud.states.last == .error(message: "Voice commands are turned off.", action: nil))
    }

    @Test func aTakeWhoseMicrophoneDiedRunsNoCommand() async throws {
        let result = try await run(transcript: "switch to gmail", loss: .beforeRelease)
        #expect(result.runner.calls.isEmpty)
        #expect(result.inserted == nil)
        #expect(result.historyCount == 0)
        #expect(result.record?.outcome == .failed)
        #expect(result.hud.states.last == .error(message: "The microphone stopped, so the command did not run.", action: nil))
    }

    @Test func aMicrophoneLostWhileTheCommandResolvesStopsIt() async throws {
        let result = try await run(transcript: "switch to gmail", loss: .whileResolving)
        #expect(result.runner.calls.count == 1)
        #expect(result.inserted == nil)
        #expect(result.historyCount == 0)
        #expect(result.hud.states.last == .error(message: "The microphone stopped, so the command did not run.", action: nil))
    }

    @Test func ordinaryDictationNeverReachesTheRunner() async throws {
        let result = try await run(transcript: "switch to chrome", useVoiceCommands: false)
        #expect(result.runner.calls.isEmpty)
        #expect(result.inserted?.hasPrefix("switch to chrome") == true)
    }
}
